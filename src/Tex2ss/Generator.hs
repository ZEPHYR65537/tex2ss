{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Generator
  ( GeneratorResult (..)
  , assembleGeneratedSource
  , runPreGenerator
  ) where

import Control.Exception (try)
import Control.Monad (unless, when)
import Control.Monad.Except (throwError)
import Data.Aeson
  ( FromJSON (parseJSON)
  , Object
  , ToJSON (toJSON)
  , object
  , withObject
  , withText
  , (.:)
  , (.=)
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Aeson.Types as Aeson
import Data.Foldable (traverse_)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HsLua as Lua
import Text.Pandoc (PandocError, runIO)
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Lua (Global (PANDOC_SCRIPT_FILE), runLua, setGlobals)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Types
  ( Bundle (bundleIndexPath, bundleSlot)
  , PageRef
  , SiteIndex (sitePages)
  , renderSlot
  )

newtype GeneratorResult = GeneratorResult
  { generatedFragments :: Map Text Text
  }
  deriving stock (Eq, Show)

data DeferredFragment = DeferredFragment Text

instance FromJSON DeferredFragment where
  parseJSON = withObject "generated fragment" $ \value -> do
    rejectUnknown "generated fragment" (Set.fromList ["type", "value"]) value
    kind <- value .: "type" >>= withText "fragment type" pure
    when (kind /= "deferred_latex") $
      fail "fragment type must be deferred_latex in this experiment"
    DeferredFragment <$> value .: "value"

instance FromJSON GeneratorResult where
  parseJSON = withObject "generator result" $ \value -> do
    rejectUnknown "generator result" (Set.singleton "fragments") value
    fragments <- value .: "fragments"
    traverse_ validateFragmentName (Map.keys fragments)
    pure . GeneratorResult $ fmap (\(DeferredFragment body) -> body) fragments

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
          Lua.forcePeek $ Lua.peekViaJSON Lua.top `Lua.lastly` Lua.pop 1
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
          Right generated -> Right generated

assembleGeneratedSource :: FilePath -> GeneratorResult -> Text -> Either [Diagnostic] Text
assembleGeneratedSource sourcePath result source =
  fmap (Text.intercalate "\n") . traverse replaceLine $ Text.splitOn "\n" source
 where
  fragments = generatedFragments result
  replaceLine line =
    case parsePlaceholder line of
      NoPlaceholder -> Right line
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
          Just body -> Right body

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

validateFragmentName :: Text -> Aeson.Parser ()
validateFragmentName name =
  unless (validFragmentName name) $
    fail "fragment names must match [a-z0-9][a-z0-9_-]*"

validFragmentName :: Text -> Bool
validFragmentName name =
  case Text.uncons name of
    Nothing -> False
    Just (first, rest) -> validFirst first && Text.all validRest rest
 where
  validFirst character =
    ('a' <= character && character <= 'z') || ('0' <= character && character <= '9')
  validRest character = validFirst character || character == '_' || character == '-'

rejectUnknown :: String -> Set.Set Text -> Object -> Aeson.Parser ()
rejectUnknown label allowed value =
  let present = Set.fromList (map Key.toText $ KeyMap.keys value)
      unknown = Set.toAscList (present `Set.difference` allowed)
   in unless (null unknown) $
        fail $ label <> " contains unknown fields: " <> Text.unpack (Text.intercalate ", " unknown)

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
