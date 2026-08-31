{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Include
  ( ExpandedSource (..)
  , expandBundleSource
  ) where

import Control.Exception (IOException, try)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath
  ( isAbsolute
  , makeRelative
  , normalise
  , splitDirectories
  , takeDirectory
  , takeExtension
  , (</>)
  )
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)

data ExpandedSource = ExpandedSource
  { expandedText :: Text
  , expandedDependencies :: [FilePath]
  }
  deriving stock (Eq, Show)

expandBundleSource :: FilePath -> FilePath -> IO (Either [Diagnostic] ExpandedSource)
expandBundleSource bundleRoot indexPath = do
  operation <- try @IOException (expandBundleSourceUnchecked bundleRoot indexPath)
  pure $
    case operation of
      Left exception -> Left [diagnosticAt Error "include.io" indexPath (Text.pack $ show exception)]
      Right result -> result

expandBundleSourceUnchecked :: FilePath -> FilePath -> IO (Either [Diagnostic] ExpandedSource)
expandBundleSourceUnchecked bundleRoot indexPath = do
  canonicalBundle <- canonicalizePath bundleRoot
  canonicalSources <- canonicalizePath (bundleRoot </> "sources")
  result <- expandFile canonicalBundle canonicalSources [] indexPath
  pure $ fmap (\(body, dependencies) -> ExpandedSource body $ nub dependencies) result

expandFile :: FilePath -> FilePath -> [FilePath] -> FilePath -> IO (Either [Diagnostic] (Text, [FilePath]))
expandFile bundleRoot sourcesRoot stack path = do
  canonical <- canonicalizePath path
  if canonical `elem` stack
    then
      pure . Left $
        [ diagnosticAt
            Error
            "include.cycle"
            canonical
            ("include cycle: " <> Text.pack (unwords $ reverse (canonical : stack)))
        ]
    else do
      readResult <- try @IOException (TextIO.readFile canonical)
      case readResult of
        Left exception ->
          pure $ Left [diagnosticAt Error "include.read" canonical (Text.pack $ show exception)]
        Right body -> expandText bundleRoot sourcesRoot (canonical : stack) canonical body

expandText :: FilePath -> FilePath -> [FilePath] -> FilePath -> Text -> IO (Either [Diagnostic] (Text, [FilePath]))
expandText bundleRoot sourcesRoot stack current = go "" []
 where
  go output dependencies remaining =
    case nextInclude remaining of
      NoInclude suffix -> pure $ Right (output <> suffix, current : dependencies)
      Malformed prefix message ->
        pure $ Left [diagnosticAt Error "include.dynamic-unsupported" current (prefix <> message)]
      Literal prefix requested rest -> do
        resolved <- resolveInclude bundleRoot sourcesRoot current requested
        case resolved of
          Left problem -> pure (Left [problem])
          Right includePath -> do
            expanded <- expandFile bundleRoot sourcesRoot stack includePath
            case expanded of
              Left problems -> pure (Left problems)
              Right (includedBody, includedDependencies) ->
                go
                  (output <> prefix <> includedBody)
                  (includedDependencies <> dependencies)
                  rest

data IncludeToken
  = NoInclude Text
  | Malformed Text Text
  | Literal Text FilePath Text

nextInclude :: Text -> IncludeToken
nextInclude = scan ""
 where
  scan prefix remaining =
    case Text.uncons remaining of
      Nothing -> NoInclude prefix
      Just ('%', rest) ->
        let (comment, afterComment) = Text.break (== '\n') rest
         in case Text.uncons afterComment of
              Nothing -> NoInclude (prefix <> "%" <> comment)
              Just (_, afterNewline) -> scan (prefix <> "%" <> comment <> "\n") afterNewline
      Just ('\\', rest)
        | Just afterCommand <- stripCommand "input" rest -> parseArgument prefix afterCommand
        | Just afterCommand <- stripCommand "include" rest -> parseArgument prefix afterCommand
        | otherwise -> scan (prefix <> "\\") rest
      Just (character, rest) -> scan (Text.snoc prefix character) rest

  stripCommand command value = do
    suffix <- Text.stripPrefix command value
    case Text.uncons suffix of
      Just (character, _) | isCommandLetter character -> Nothing
      _ -> Just suffix

  parseArgument prefix afterCommand =
    let stripped = Text.dropWhile (`elem` [' ', '\t', '\r', '\n']) afterCommand
     in case Text.uncons stripped of
          Just ('{', afterBrace) ->
            let (argument, closing) = Text.break (== '}') afterBrace
             in case Text.uncons closing of
                  Nothing -> Malformed prefix "include command has no closing '}'"
                  Just (_, rest) ->
                    let requested = Text.strip argument
                     in if Text.null requested || Text.any (`elem` ['{', '}', '\\']) requested
                          then Malformed prefix "include path must be a non-empty literal path"
                          else Literal prefix (Text.unpack requested) rest
          _ -> Malformed prefix "include command must use a literal braced path"

  isCommandLetter character =
    ('a' <= character && character <= 'z') || ('A' <= character && character <= 'Z')

resolveInclude :: FilePath -> FilePath -> FilePath -> FilePath -> IO (Either Diagnostic FilePath)
resolveInclude bundleRoot sourcesRoot current requested
  | isAbsolute requested = invalid "absolute include paths are not allowed"
  | any (== "..") (splitDirectories $ normalise requested) = invalid "include paths must not contain '..'"
  | otherwise = do
      let withExtension = if null (takeExtension requested) then requested <> ".tex" else requested
          candidate = takeDirectory current </> withExtension
      exists <- doesFileExist candidate
      if not exists
        then pure $ Left (diagnosticAt Error "include.missing" candidate "included file does not exist")
        else do
          canonical <- canonicalizePath candidate
          pure $
            if inside sourcesRoot canonical && inside bundleRoot canonical
              then Right canonical
              else Left (diagnosticAt Error "include.outside-sources" canonical "included files must remain beneath this bundle's sources directory")
 where
  invalid message = pure $ Left (diagnosticAt Error "include.path-invalid" current message)

inside :: FilePath -> FilePath -> Bool
inside root candidate =
  let relative = makeRelative root candidate
   in relative == "."
        || (not (isAbsolute relative) && not (".." `elem` splitDirectories relative))
