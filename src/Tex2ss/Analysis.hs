{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Tex2ss.Analysis
  ( AnalysisExport (..)
  , analysisSnapshotName
  , matchingAnalyzerBundles
  , runPostAnalyzer
  , selectDescendantExports
  ) where

import Control.Exception (try)
import Control.Monad.Except (throwError)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value
  , encode
  , object
  , withObject
  , withText
  , (.:)
  , (.=)
  )
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (isPrefixOf, sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HsLua as Lua
import Text.Pandoc (Pandoc, PandocError, runIO)
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Lua (Global (PANDOC_DOCUMENT, PANDOC_SCRIPT_FILE), runLua, setGlobals)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Types
  ( AnalyzerSpec (..)
  , Bundle (..)
  , BundleMetadata (metadataPostAnalyzer)
  , Slot (..)
  , renderSlot
  )

data AnalysisExport = AnalysisExport
  { analysisProducer :: FilePath
  , analysisNamespace :: Text
  , analysisSchemaVersion :: Int
  , analysisDocument :: Slot
  , analysisValue :: Value
  }
  deriving stock (Eq, Show)

instance ToJSON AnalysisExport where
  toJSON value =
    object
      [ "producer" .= analysisProducer value
      , "namespace" .= analysisNamespace value
      , "schema_version" .= analysisSchemaVersion value
      , "document" .= renderSlot (analysisDocument value)
      , "value" .= analysisValue value
      ]

instance FromJSON AnalysisExport where
  parseJSON = withObject "AnalysisExportV1" $ \value ->
    AnalysisExport
      <$> value .: "producer"
      <*> value .: "namespace"
      <*> value .: "schema_version"
      <*> (value .: "document" >>= parseSlot)
      <*> value .: "value"
   where
    parseSlot = withText "analysis document slot" $ \case
      "." -> pure (Slot [])
      value
        | Text.null value || any Text.null (Text.splitOn "/" value) ->
            fail "analysis document slot is invalid"
        | otherwise -> pure . Slot $ Text.splitOn "/" value

data AnalyzerContext = AnalyzerContext
  { contextSlot :: Slot
  , contextNamespace :: Text
  , contextSchemaVersion :: Int
  }

instance ToJSON AnalyzerContext where
  toJSON context =
    object
      [ "document" .= object ["slot" .= renderSlot (contextSlot context)]
      , "export" .=
          object
            [ "namespace" .= contextNamespace context
            , "schema_version" .= contextSchemaVersion context
            ]
      ]

analysisSnapshotName :: String
analysisSnapshotName = "tex2ss-analysis-v1"

runPostAnalyzer
  :: FilePath
  -> AnalyzerSpec
  -> Bundle
  -> Pandoc
  -> IO (Either [Diagnostic] AnalysisExport)
runPostAnalyzer scriptPath spec bundle document = do
  let context =
        AnalyzerContext
          { contextSlot = bundleSlot bundle
          , contextNamespace = analyzerNamespace spec
          , contextSchemaVersion = analyzerSchemaVersion spec
          }
  operation <- try @PandocError . runIO $ do
    exported <- runLua $ do
      setGlobals [PANDOC_SCRIPT_FILE scriptPath, PANDOC_DOCUMENT document]
      Lua.dofileTrace (Just scriptPath) >>= \case
        Lua.OK -> pure ()
        _ -> Lua.throwErrorAsException
      Lua.getglobal "post_analyzer" >>= \case
        Lua.TypeFunction -> do
          _ <- Lua.getglobal "PANDOC_DOCUMENT"
          Lua.pushViaJSON context
          Lua.callTrace 2 1
          Lua.forcePeek $ Lua.peekViaJSON Lua.top `Lua.lastly` Lua.pop 1
        Lua.TypeNil -> do
          Lua.pop 1
          Lua.failLua "analyzer must define post_analyzer(document, context)"
        _ -> do
          Lua.pop 1
          Lua.failLua "post_analyzer must be a function"
    either throwError pure exported
  pure $
    case operation of
      Left problem -> Left [analyzerDiagnostic bundle scriptPath problem]
      Right result ->
        case result of
          Left problem -> Left [analyzerDiagnostic bundle scriptPath problem]
          Right value -> validateExportSize scriptPath export
            where
              export =
                AnalysisExport
                  { analysisProducer = analyzerScript spec
                  , analysisNamespace = analyzerNamespace spec
                  , analysisSchemaVersion = analyzerSchemaVersion spec
                  , analysisDocument = bundleSlot bundle
                  , analysisValue = value
                  }

matchingAnalyzerBundles :: Bundle -> [Text] -> [Bundle] -> [Bundle]
matchingAnalyzerBundles ancestor namespaces =
  sortOn (renderSlot . bundleSlot)
    . filter matches
 where
  matches candidate =
    isStrictDescendant (bundleSlot ancestor) (bundleSlot candidate)
      && maybe False ((`elem` namespaces) . analyzerNamespace) (metadataPostAnalyzer $ bundleMetadata candidate)

selectDescendantExports :: Bundle -> [Text] -> [AnalysisExport] -> [AnalysisExport]
selectDescendantExports ancestor namespaces =
  sortOn exportKey
    . filter
      ( \export ->
          analysisNamespace export `elem` namespaces
            && isStrictDescendant (bundleSlot ancestor) (analysisDocument export)
      )
 where
  exportKey value =
    ( renderSlot $ analysisDocument value
    , analysisNamespace value
    , analysisProducer value
    )

isStrictDescendant :: Slot -> Slot -> Bool
isStrictDescendant (Slot ancestor) (Slot candidate) =
  ancestor /= candidate && ancestor `isPrefixOf` candidate

validateExportSize :: FilePath -> AnalysisExport -> Either [Diagnostic] AnalysisExport
validateExportSize scriptPath export
  | LazyByteString.length (encode export) <= fromIntegral maximumExportBytes = Right export
  | otherwise =
      Left
        [ diagnosticAt
            Error
            "analyzer.export-too-large"
            scriptPath
            "post_analyzer export exceeds the 1 MiB encoded limit"
        ]

maximumExportBytes :: Int
maximumExportBytes = 1024 * 1024

analyzerDiagnostic :: Bundle -> FilePath -> PandocError -> Diagnostic
analyzerDiagnostic bundle scriptPath problem =
  diagnosticAt
    Error
    "analyzer.failed"
    scriptPath
    ( "while analyzing "
        <> Text.pack (bundleIndexPath bundle)
        <> ": "
        <> renderError problem
    )
