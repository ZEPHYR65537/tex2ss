{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Tex2ss.Generator
  ( AssembledSource (..)
  , GeneratedContent (..)
  , GeneratorResult (..)
  , assembleGeneratedSource
  , pandocFragmentMarker
  , runPreGenerator
  ) where

import Control.Exception (try)
import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Data.Aeson (ToJSON (toJSON), object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import Data.Char (ord)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HsLua as Lua
import Numeric (showHex)
import Text.Pandoc (PandocError, runIO)
import Text.Pandoc.Definition (Block (RawBlock), Format (..), Inline (RawInline))
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Lua (Global (PANDOC_SCRIPT_FILE), runLua, setGlobals)
import Text.Pandoc.Walk (query)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Types
  ( Bundle (bundleIndexPath, bundleSlot)
  , PageRef
  , SiteIndex (sitePages)
  , renderSlot
  )

data GeneratedContent
  = DeferredLaTeXBlock Text
  | PandocBlocks [Block]
  deriving stock (Eq, Show)

newtype GeneratorResult = GeneratorResult
  { generatedFragments :: Map Text GeneratedContent
  }
  deriving stock (Eq, Show)

data AssembledSource = AssembledSource
  { assembledText :: Text
  , assembledPandocFragments :: Map Text [Block]
  }
  deriving stock (Eq, Show)

data GeneratorContext = GeneratorContext
  { contextCurrentSlot :: Text
  , contextPages :: [PageRef]
  }

instance ToJSON GeneratorContext where
  toJSON context =
    object
      [ "document" .= object ["slot" .= contextCurrentSlot context]
      , "site_index" .= object ["pages" .= contextPages context]
      ]

runPreGenerator :: FilePath -> SiteIndex -> Bundle -> IO (Either [Diagnostic] GeneratorResult)
runPreGenerator scriptPath siteIndex bundle = do
  let context =
        GeneratorContext
          { contextCurrentSlot = renderSlot (bundleSlot bundle)
          , contextPages = Map.elems (sitePages siteIndex)
          }
  operation <- try @PandocError . runIO $ do
    generated <- runLua $ do
      setGlobals [PANDOC_SCRIPT_FILE scriptPath]
      Lua.dofileTrace (Just scriptPath) >>= \case
        Lua.OK -> pure ()
        _ -> Lua.throwErrorAsException
      Lua.getglobal "pre_generator" >>= \case
        Lua.TypeFunction -> do
          Lua.pushViaJSON context
          Lua.callTrace 1 1
          Lua.forcePeek $ peekGeneratorResult Lua.top `Lua.lastly` Lua.pop 1
        Lua.TypeNil -> do
          Lua.pop 1
          Lua.failLua "generator must define pre_generator(context)"
        _ -> do
          Lua.pop 1
          Lua.failLua "pre_generator must be a function"
    either throwError pure generated
  pure $
    case operation of
      Left problem -> Left [generatorDiagnostic bundle scriptPath problem]
      Right result ->
        case result of
          Left problem -> Left [generatorDiagnostic bundle scriptPath problem]
          Right generated -> validateGeneratorResult scriptPath generated

peekGeneratorResult :: Lua.LuaError error => Lua.Peeker error GeneratorResult
peekGeneratorResult index = do
  rejectUnknownFields "generator result" (Set.singleton "fragments") index
  GeneratorResult
    <$> Lua.peekFieldRaw
      (Lua.peekMap Lua.peekText peekGeneratedContent)
      "fragments"
      index

peekGeneratedContent :: Lua.LuaError error => Lua.Peeker error GeneratedContent
peekGeneratedContent index = do
  kind <- Lua.peekFieldRaw Lua.peekText "type" index
  case kind of
    "deferred_latex" -> do
      rejectUnknownFields "deferred_latex fragment" (Set.fromList ["type", "value"]) index
      DeferredLaTeXBlock <$> Lua.peekFieldRaw Lua.peekText "value" index
    "pandoc_blocks" -> do
      rejectUnknownFields "pandoc_blocks fragment" (Set.fromList ["type", "blocks"]) index
      PandocBlocks
        <$> Lua.peekFieldRaw
          (Lua.peekList (Lua.safepeek @Block))
          "blocks"
          index
    _ ->
      Lua.failPeek . ByteString.pack $
        "fragment type must be deferred_latex or pandoc_blocks"

rejectUnknownFields
  :: Lua.LuaError error
  => String
  -> Set.Set Text
  -> Lua.Peeker error ()
rejectUnknownFields label allowed index = do
  present <-
    Map.keysSet
      <$> Lua.peekMap Lua.peekText (const $ pure ()) index
  let unknown = Set.toAscList (present `Set.difference` allowed)
  unless (null unknown) . Lua.failPeek . ByteString.pack $
    label <> " contains unknown fields: " <> Text.unpack (Text.intercalate ", " unknown)

validateGeneratorResult :: FilePath -> GeneratorResult -> Either [Diagnostic] GeneratorResult
validateGeneratorResult scriptPath result@(GeneratorResult fragments) =
  case nameProblems <> rawProblems of
    [] -> Right result
    problems -> Left problems
 where
  nameProblems =
    [ diagnosticAt
        Error
        "generator.fragment-name-invalid"
        scriptPath
        ("fragment name must match [a-z0-9][a-z0-9_-]*: " <> name)
    | name <- Map.keys fragments
    , not (validFragmentName name)
    ]
  rawProblems =
    [ diagnosticAt
        Error
        "generator.pandoc-blocks-raw"
        scriptPath
        ( "pandoc_blocks fragment "
            <> name
            <> " contains target-specific raw content: "
            <> kind
            <> "["
            <> format
            <> "] "
            <> Text.take 100 (Text.unwords $ Text.words body)
        )
    | (name, PandocBlocks blocks) <- Map.toAscList fragments
    , (kind, format, body) <- generatedRawNodes blocks
    ]

generatedRawNodes :: [Block] -> [(Text, Text, Text)]
generatedRawNodes blocks = query blockRaw blocks <> query inlineRaw blocks
 where
  blockRaw = \case
    RawBlock (Format format) body -> [("block", format, body)]
    _ -> []
  inlineRaw = \case
    RawInline (Format format) body -> [("inline", format, body)]
    _ -> []

assembleGeneratedSource :: FilePath -> GeneratorResult -> Text -> Either [Diagnostic] AssembledSource
assembleGeneratedSource sourcePath result source = do
  replaced <- traverse replaceLine $ Text.splitOn "\n" source
  pure
    AssembledSource
      { assembledText = Text.intercalate "\n" (map fst replaced)
      , assembledPandocFragments = Map.unions (map snd replaced)
      }
 where
  fragments = generatedFragments result
  replaceLine line =
    case parsePlaceholder line of
      NoPlaceholder -> Right (line, Map.empty)
      InvalidPlaceholder message ->
        Left [diagnosticAt Error "generator.placeholder-invalid" sourcePath message]
      Placeholder name ->
        case Map.lookup name fragments of
          Nothing ->
            Left
              [ diagnosticAt
                  Error
                  "generator.fragment-missing"
                  sourcePath
                  ("generator did not return fragment: " <> name)
              ]
          Just (DeferredLaTeXBlock body) -> Right (body, Map.empty)
          Just (PandocBlocks blocks) ->
            Right ("\n" <> pandocFragmentMarker name <> "\n", Map.singleton name blocks)

pandocFragmentMarker :: Text -> Text
pandocFragmentMarker name =
  "texssgeneratedpandocblocks" <> Text.concatMap encodeCharacter name
 where
  encodeCharacter = Text.pack . (<> "z") . (`showHex` "") . ord

data Placeholder
  = NoPlaceholder
  | InvalidPlaceholder Text
  | Placeholder Text

parsePlaceholder :: Text -> Placeholder
parsePlaceholder line
  | Text.isPrefixOf "%" stripped = NoPlaceholder
  | not ("\\tex2ssgenerated" `Text.isInfixOf` stripped) = NoPlaceholder
  | otherwise =
      case Text.stripPrefix "\\tex2ssgenerated{" stripped of
        Nothing -> invalid
        Just afterOpen ->
          let (name, closing) = Text.breakOn "}" afterOpen
           in case Text.stripPrefix "}" closing of
                Just remainder
                  | Text.null (Text.strip remainder)
                  , validFragmentName name -> Placeholder name
                _ -> invalid
 where
  stripped = Text.strip line
  invalid = InvalidPlaceholder "generated fragments must use a standalone \\tex2ssgenerated{name} line"

validFragmentName :: Text -> Bool
validFragmentName name =
  case Text.uncons name of
    Nothing -> False
    Just (first, rest) -> validFirst first && Text.all validRest rest
 where
  validFirst character =
    ('a' <= character && character <= 'z') || ('0' <= character && character <= '9')
  validRest character = validFirst character || character == '_' || character == '-'

generatorDiagnostic :: Bundle -> FilePath -> PandocError -> Diagnostic
generatorDiagnostic bundle scriptPath problem =
  diagnosticAt
    Error
    "generator.failed"
    scriptPath
    ( "while generating "
        <> Text.pack (bundleIndexPath bundle)
        <> ": "
        <> renderError problem
    )
