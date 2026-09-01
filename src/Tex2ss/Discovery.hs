{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Discovery
  ( discoverBundles
  ) where

import Control.Exception (IOException, try)
import Control.Monad (foldM)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.FilePath (isAbsolute, makeRelative, splitDirectories, (</>))
import Tex2ss.Config (loadBundleMetadata)
import Tex2ss.Diagnostics (Diagnostic (diagnosticPath), Severity (Error), diagnosticAt)
import Tex2ss.Paths (validateSlot)
import Tex2ss.Types
  ( Bundle (..)
  , ProjectPaths (projectContent)
  , Slot
  , slotRoute
  )

discoverBundles :: ProjectPaths -> IO (Either [Diagnostic] [Bundle])
discoverBundles paths = do
  result <- try @IOException (discoverBundlesUnchecked paths)
  pure $
    case result of
      Left exception ->
        Left [diagnosticAt Error "bundle.discovery-io" (projectContent paths) (Text.pack $ show exception)]
      Right value -> value

discoverBundlesUnchecked :: ProjectPaths -> IO (Either [Diagnostic] [Bundle])
discoverBundlesUnchecked paths = do
  let contentRoot = projectContent paths
  contentExists <- doesDirectoryExist contentRoot
  if not contentExists
    then pure $ Left [diagnosticAt Error "project.content-missing" contentRoot "content directory does not exist"]
    else do
      canonicalRoot <- canonicalizePath contentRoot
      (problems, bundles) <- walk canonicalRoot Set.empty canonicalRoot
      let allProblems = problems <> duplicateRouteDiagnostics bundles
      pure $ if null allProblems then Right bundles else Left allProblems

walk :: FilePath -> Set.Set FilePath -> FilePath -> IO ([Diagnostic], [Bundle])
walk root visited directory = do
  boundary <- canonicalizePath directory
  if not (inside root boundary)
    then pure ([diagnosticAt Error "bundle.path-escape" directory "directory escapes content root"], [])
    else if Set.member boundary visited
      then pure ([diagnosticAt Error "bundle.directory-cycle" directory "directory resolves to an already visited content location"], [])
    else do
      let indexPath = directory </> "index.tex"
          metaPath = directory </> "meta.json"
      hasIndex <- doesFileExist indexPath
      hasMeta <- doesFileExist metaPath
      case (hasIndex, hasMeta) of
        (True, False) ->
          pure ([diagnosticAt Error "bundle.meta-missing" directory "index.tex exists but meta.json is missing"], [])
        (False, True) ->
          pure ([diagnosticAt Error "bundle.index-missing" directory "meta.json exists but index.tex is missing"], [])
        pair -> do
          current <- if pair == (True, True) then loadCurrent root directory indexPath metaPath else pure ([], [])
          children <- listChildren directory
          let childDirectories =
                [ directory </> child
                | child <- children
                , not (pair == (True, True) && child `elem` reservedBundleTrees)
                ]
          nested <- traverseDirectoryChildren root (Set.insert boundary visited) childDirectories
          pure (fst current <> fst nested, snd current <> snd nested)

loadCurrent :: FilePath -> FilePath -> FilePath -> FilePath -> IO ([Diagnostic], [Bundle])
loadCurrent root directory indexPath metaPath =
  case slotFor root directory of
    Left problem -> pure ([problem], [])
    Right slot -> do
      metadata <- loadBundleMetadata metaPath
      pure $
        case metadata of
          Left problems -> (problems, [])
          Right value -> ([], [Bundle slot directory indexPath metaPath value])

slotFor :: FilePath -> FilePath -> Either Diagnostic Slot
slotFor root directory =
  let relative = makeRelative root directory
      raw =
        if relative == "."
          then "."
          else Text.intercalate "/" (map Text.pack $ splitDirectories relative)
   in case validateSlot raw of
        Left problem -> Left problem {diagnosticPath = Just directory}
        Right slot -> Right slot

listChildren :: FilePath -> IO [FilePath]
listChildren = fmap sort . listDirectory

traverseDirectoryChildren :: FilePath -> Set.Set FilePath -> [FilePath] -> IO ([Diagnostic], [Bundle])
traverseDirectoryChildren root visited =
  foldM step ([], [])
 where
  step accumulated child = do
    isDirectory <- doesDirectoryExist child
    if not isDirectory
      then pure accumulated
      else do
        found <- walk root visited child
        pure (fst accumulated <> fst found, snd accumulated <> snd found)

inside :: FilePath -> FilePath -> Bool
inside root candidate =
  let relative = makeRelative root candidate
   in relative == "."
        || ( not (null relative)
              && not (isAbsolute relative)
              && not (".." `elem` splitDirectories relative)
           )

reservedBundleTrees :: [FilePath]
reservedBundleTrees = ["sources", "media", "extension"]

duplicateRouteDiagnostics :: [Bundle] -> [Diagnostic]
duplicateRouteDiagnostics bundles =
  concatMap reportDuplicate . Map.toAscList $
    Map.fromListWith (<>) [(slotRoute $ bundleSlot bundle, [bundle]) | bundle <- bundles]
 where
  reportDuplicate :: (Text, [Bundle]) -> [Diagnostic]
  reportDuplicate (_, [_]) = []
  reportDuplicate (route, duplicates) =
    [ diagnosticAt Error "route.duplicate" (bundleDirectory bundle) ("duplicate route " <> route)
    | bundle <- duplicates
    ]
