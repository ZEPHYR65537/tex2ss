{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Paths
  ( findProjectRoot
  , isPortableName
  , mkProjectPaths
  , resolveExistingUnder
  , validateRelativePath
  , validateSlot
  ) where

import Control.Exception (IOException, try)
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , makeAbsolute
  )
import System.FilePath
  ( isAbsolute
  , makeRelative
  , normalise
  , splitDirectories
  , takeDirectory
  , (</>)
  )
import Tex2ss.Diagnostics
  ( Diagnostic
  , Severity (Error)
  , diagnostic
  , diagnosticAt
  )
import Tex2ss.Types (ProjectPaths (..), Slot (..))

mkProjectPaths :: FilePath -> ProjectPaths
mkProjectPaths root =
  ProjectPaths
    { projectRoot = root
    , projectConfig = root </> "config.json"
    , projectContent = root </> "content"
    , projectTemplates = root </> "site" </> "templates"
    , projectAssets = root </> "site" </> "assets"
    , projectPandoc = root </> "pandoc"
    , projectPlugins = root </> "plugins"
    , projectLatex = root </> "latex"
    , projectDeploy = root </> "deploy"
    , projectPublic = root </> "public"
    , projectPdfs = root </> "pdfs"
    , projectState = root </> ".tex2ss"
    }

findProjectRoot :: Maybe FilePath -> IO (Either [Diagnostic] FilePath)
findProjectRoot requested = do
  start <- maybe getCurrentDirectory makeAbsolute requested
  startIsFile <- doesFileExist start
  let initial = if startIsFile then takeDirectory start else start
  search initial
 where
  search directory = do
    hasConfig <- doesFileExist (directory </> "config.json")
    if hasConfig
      then Right <$> canonicalizePath directory
      else do
        let parent = takeDirectory directory
        if parent == directory
          then
            pure . Left $
              [ diagnosticAt
                  Error
                  "project.config-not-found"
                  directory
                  "could not find config.json in this directory or any parent"
              ]
          else search parent

validateSlot :: Text -> Either Diagnostic Slot
validateSlot raw
  | Text.null raw = Left $ diagnostic Error "slot.empty" "slot must not be empty"
  | raw == "." = Right (Slot [])
  | Text.isPrefixOf "/" raw || Text.isSuffixOf "/" raw = invalid
  | otherwise =
      let segments = Text.splitOn "/" raw
       in if all isPortableName segments
            then Right (Slot segments)
            else invalid
 where
  invalid =
    Left $
      diagnostic
        Error
        "slot.invalid"
        "slot segments must match [a-z0-9][a-z0-9_-]* and use '/' separators"

isPortableName :: Text -> Bool
isPortableName value =
  case Text.uncons value of
    Nothing -> False
    Just (first, rest) ->
      validFirst first
        && Text.all validRest rest
        && not (isWindowsDeviceName value)
 where
  validFirst character = isAsciiLower character || isDigit character
  validRest character = validFirst character || character == '_' || character == '-'

isWindowsDeviceName :: Text -> Bool
isWindowsDeviceName value =
  value `elem` ["con", "prn", "aux", "nul"]
    || deviceNumber "com"
    || deviceNumber "lpt"
 where
  deviceNumber prefix =
    case Text.stripPrefix prefix value of
      Just suffix -> suffix `elem` map (Text.pack . show) ([1 .. 9] :: [Int])
      Nothing -> False

validateRelativePath :: FilePath -> Either Diagnostic FilePath
validateRelativePath path
  | null path = Left $ diagnostic Error "path.empty" "path must not be empty"
  | isAbsolute path = Left $ diagnostic Error "path.absolute" "path must be relative to the project"
  | '\\' `elem` path = Left $ diagnostic Error "path.separator" "project paths must use portable '/' separators"
  | any (== "..") (splitDirectories (normalise path)) =
      Left $ diagnostic Error "path.parent-traversal" "path must not contain '..'"
  | otherwise = Right (normalise path)

resolveExistingUnder :: FilePath -> FilePath -> IO (Either Diagnostic FilePath)
resolveExistingUnder root relative =
  case validateRelativePath relative of
    Left problem -> pure (Left problem)
    Right clean -> do
      result <- try @IOException $ do
        canonicalRoot <- canonicalizePath root
        canonicalCandidate <- canonicalizePath (root </> clean)
        exists <- doesFileExist canonicalCandidate
        isDirectory <- doesDirectoryExist canonicalCandidate
        if not exists && not isDirectory
          then pure $ Left (diagnosticAt Error "path.missing" canonicalCandidate "path does not exist")
          else
            if isInside canonicalRoot canonicalCandidate
              then pure (Right canonicalCandidate)
              else pure $ Left (diagnosticAt Error "path.escape" canonicalCandidate "path escapes its allowed root")
      pure $
        case result of
          Left exception -> Left $ diagnosticAt Error "path.io" (root </> clean) (Text.pack $ show exception)
          Right value -> value

isInside :: FilePath -> FilePath -> Bool
isInside root candidate =
  let relative = makeRelative root candidate
      pieces = splitDirectories relative
   in not (isAbsolute relative) && not (any (== "..") pieces)
