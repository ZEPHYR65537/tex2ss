{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Pdf
  ( LatexEnvironment (..)
  , LatexInvocation (..)
  , LatexRunResult (..)
  , buildPdf
  , buildPdfWith
  , diagnoseLatexEnvironment
  , inspectLatexEnvironment
  , inspectLatexEnvironmentWith
  , latexmkEngineArgument
  , latexmkRecipeOptions
  , probeLatexEnvironmentWith
  ) where

import Control.Exception (IOException, finally, try)
import Control.Monad (foldM, when)
import Crypto.Hash (Digest, SHA256, hash, hashlazy)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , eitherDecodeFileStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (find, findIndex, sortOn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Ord (Down (Down))
import System.Directory
  ( copyFile
  , createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , removeDirectory
  , removePathForcibly
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath
  ( searchPathSeparator
  , takeDirectory
  , (</>)
  )
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (cwd, env)
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
  )
import Tex2ss.Build (BuildPlan (..), prepareBuildPlan)
import Tex2ss.Analysis (AnalysisExport, selectDescendantExports)
import Tex2ss.Config (loadSiteConfig)
import Tex2ss.Diagnostics
  ( Diagnostic (diagnosticHint)
  , Severity (Error)
  , diagnostic
  , diagnosticAt
  )
import Tex2ss.Manifest
  ( Manifest (Manifest)
  , commitPdfSnapshot
  , createManifest
  , pdfWorkDirectory
  )
import Tex2ss.Pandoc
  ( PreparedBundle (preparedPandocFragments)
  , analyzePreparedBundle
  , prepareBundleSourceWith
  , renderBundleLaTeX
  )
import Tex2ss.Paths (mkProjectPaths)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (metadataAnalysisInputs, metadataPdfName)
  , PdfEngine (..)
  , ProjectPaths (..)
  , SiteConfig (configPdfEngine)
  , Slot (..)
  , pdfOutputPath
  , renderPdfEngine
  )

data LatexEnvironment = LatexEnvironment
  { latexmkExecutable :: FilePath
  , latexmkVersion :: Text
  , latexEngine :: PdfEngine
  , latexEngineExecutable :: FilePath
  , latexEngineVersion :: Text
  }
  deriving stock (Eq, Show)

data LatexInvocation = LatexInvocation
  { invocationWorkingDirectory :: FilePath
  , invocationOutputDirectory :: FilePath
  , invocationSourcePath :: FilePath
  , invocationExpectedPdf :: FilePath
  , invocationLatexInputDirectories :: [FilePath]
  }
  deriving stock (Eq, Show)

data LatexRunResult = LatexRunResult
  { latexRunExitCode :: ExitCode
  , latexRunStdout :: Text
  , latexRunStderr :: Text
  }
  deriving stock (Eq, Show)

data PdfCacheEntry = PdfCacheEntry
  { cacheInputFingerprint :: Text
  , cacheOutputSha256 :: Text
  }
  deriving stock (Eq, Show)

newtype PdfState = PdfState
  { pdfStateOutputs :: Map FilePath PdfCacheEntry
  }
  deriving stock (Eq, Show)

instance ToJSON PdfCacheEntry where
  toJSON entry =
    object
      [ "input" .= cacheInputFingerprint entry
      , "output_sha256" .= cacheOutputSha256 entry
      ]

instance FromJSON PdfCacheEntry where
  parseJSON = withObject "PDF cache entry" $ \value ->
    PdfCacheEntry <$> value .: "input" <*> value .: "output_sha256"

instance ToJSON PdfState where
  toJSON state =
    object
      [ "schema_version" .= (1 :: Int)
      , "outputs" .= pdfStateOutputs state
      ]

instance FromJSON PdfState where
  parseJSON = withObject "PDF state" $ \value -> do
    version <- value .: "schema_version"
    if version /= (1 :: Int)
      then fail "PDF state schema_version must be 1"
      else PdfState <$> value .: "outputs"

type LatexRunner = LatexEnvironment -> LatexInvocation -> IO LatexRunResult

buildPdf :: FilePath -> Bool -> IO (Either [Diagnostic] Bool)
buildPdf root includeDrafts = do
  let paths = mkProjectPaths root
  configResult <- loadSiteConfig (projectConfig paths)
  case configResult of
    Left problems -> pure (Left problems)
    Right config -> do
      environment <- inspectLatexEnvironment (configPdfEngine config)
      case environment of
        Left problems -> pure (Left problems)
        Right available -> buildPdfWith available runLatexmk root includeDrafts

buildPdfWith :: LatexEnvironment -> LatexRunner -> FilePath -> Bool -> IO (Either [Diagnostic] Bool)
buildPdfWith environment runner root includeDrafts = do
  let paths = mkProjectPaths root
      lockDirectory = projectState paths </> "build.lock"
  createDirectoryIfMissing True (projectState paths)
  acquired <- try @IOException (createDirectory lockDirectory)
  case acquired of
    Left _ ->
      pure . Left $
        [ (diagnosticAt Error "build.locked" lockDirectory "another tex2ss build owns this project")
            { diagnosticHint = Just "If no build is running, remove the stale .tex2ss/build.lock directory."
            }
        ]
    Right () ->
      ( do
          operation <- try @IOException (buildPdfUnlocked environment runner root includeDrafts)
          pure $
            case operation of
              Left exception ->
                Left [diagnosticAt Error "pdf.io" (projectPdfs paths) (Text.pack $ show exception)]
              Right result -> result
      )
        `finally` removeDirectory lockDirectory

buildPdfUnlocked :: LatexEnvironment -> LatexRunner -> FilePath -> Bool -> IO (Either [Diagnostic] Bool)
buildPdfUnlocked environment runner root includeDrafts = do
  planResult <- prepareBuildPlan root includeDrafts
  case planResult of
    Left problems -> pure (Left problems)
    Right plan -> do
      if configPdfEngine (planConfig plan) /= latexEngine environment
        then
          pure . Left $
            [ diagnosticAt
                Error
                "pdf.engine-mismatch"
                (projectConfig $ planPaths plan)
                ( "configured PDF engine is "
                    <> renderPdfEngine (configPdfEngine $ planConfig plan)
                    <> ", but the build environment selected "
                    <> renderPdfEngine (latexEngine environment)
                )
            ]
        else do
          let paths = planPaths plan
              candidate = pdfWorkDirectory paths
              temporary = pdfTemporaryDirectory paths
          resetDirectory candidate
          resetDirectory temporary
          oldState <- loadPdfState (pdfStatePath paths)
          let orderedBundles =
                sortOn
                  (Down . length . slotSegments . bundleSlot)
                  (planBundles plan)
          compiled <-
            foldM
              (compileBundle environment runner plan oldState)
              (Right (Map.empty, []))
              orderedBundles
          case compiled of
            Left problems -> pure (Left problems)
            Right (newEntries, _) -> do
              writePdfState (pdfStatePath paths) (PdfState newEntries)
              committed <- commitPdfSnapshot paths
              case committed of
                Left problems -> pure (Left problems)
                Right changed -> pure (Right changed)

compileBundle
  :: LatexEnvironment
  -> LatexRunner
  -> BuildPlan
  -> PdfState
  -> Either [Diagnostic] (Map FilePath PdfCacheEntry, [AnalysisExport])
  -> Bundle
  -> IO (Either [Diagnostic] (Map FilePath PdfCacheEntry, [AnalysisExport]))
compileBundle _ _ _ _ result@(Left _) _ = pure result
compileBundle environment runner plan oldState (Right (entries, exports)) bundle = do
  let paths = planPaths plan
      relativeOutput =
        pdfOutputPath
          (bundleSlot bundle)
          (metadataPdfName $ bundleMetadata bundle)
      publishedOutput = projectPdfs paths </> relativeOutput
      candidateOutput = pdfWorkDirectory paths </> relativeOutput
      descendantExports =
        selectDescendantExports
          bundle
          (metadataAnalysisInputs $ bundleMetadata bundle)
          exports
  prepared <- prepareBundleSourceWith paths (planSiteIndex plan) descendantExports bundle
  case prepared of
    Left problems -> pure (Left problems)
    Right preparedBundle -> do
      analyzed <- analyzePreparedBundle paths (planConfig plan) bundle preparedBundle
      case analyzed of
        Left problems -> pure (Left problems)
        Right exported -> do
          lowered <- renderBundleLaTeX (bundleIndexPath bundle) preparedBundle
          case lowered of
            Left problems -> pure (Left problems)
            Right source -> do
              fingerprint <-
                pdfInputFingerprint
                  environment
                  paths
                  bundle
                  source
                  (preparedPandocFragments preparedBundle)
              reusable <- cachedOutputIsReusable oldState relativeOutput fingerprint publishedOutput
              if reusable
                then do
                  createDirectoryIfMissing True (takeDirectory candidateOutput)
                  copyFile publishedOutput candidateOutput
                  outputDigest <- fileSha256 candidateOutput
                  pure . Right $
                    ( Map.insert relativeOutput (PdfCacheEntry fingerprint outputDigest) entries
                    , maybe exports (: exports) exported
                    )
                else do
                  rendered <- compilePdfBundle environment runner paths bundle source candidateOutput
                  case rendered of
                    Left problems -> pure (Left problems)
                    Right () -> do
                      outputDigest <- fileSha256 candidateOutput
                      pure . Right $
                        ( Map.insert relativeOutput (PdfCacheEntry fingerprint outputDigest) entries
                        , maybe exports (: exports) exported
                        )

compilePdfBundle
  :: LatexEnvironment
  -> LatexRunner
  -> ProjectPaths
  -> Bundle
  -> Text
  -> FilePath
  -> IO (Either [Diagnostic] ())
compilePdfBundle environment runner paths bundle source candidateOutput = do
  let workDirectory = bundlePdfWorkDirectory paths (bundleSlot bundle)
      outputDirectory = workDirectory </> "out"
      stagedSource = workDirectory </> "document.tex"
      expectedPdf = outputDirectory </> "document.pdf"
      invocation =
        LatexInvocation
          { invocationWorkingDirectory = bundleDirectory bundle
          , invocationOutputDirectory = outputDirectory
          , invocationSourcePath = stagedSource
          , invocationExpectedPdf = expectedPdf
          , invocationLatexInputDirectories =
              [ bundleDirectory bundle
              , bundleDirectory bundle </> "extension" </> "latex"
              , projectRoot paths </> "latex"
              ]
          }
  createDirectoryIfMissing True outputDirectory
  ByteString.writeFile stagedSource (TextEncoding.encodeUtf8 source)
  result <- runner environment invocation
  exists <- doesFileExist expectedPdf
  logExcerpt <- latexLogExcerpt (outputDirectory </> "document.log")
  case latexRunExitCode result of
    ExitSuccess
      | exists -> do
          createDirectoryIfMissing True (takeDirectory candidateOutput)
          copyFile expectedPdf candidateOutput
          pure (Right ())
      | otherwise ->
          pure . Left $
            [ (diagnosticAt Error "pdf.output-missing" (bundleIndexPath bundle) "latexmk succeeded but produced no PDF")
                { diagnosticHint = Just ("Expected output: " <> Text.pack expectedPdf)
                }
            ]
    ExitFailure code ->
      pure . Left $
        [ ( diagnosticAt
              Error
              "pdf.latexmk-failed"
              (bundleIndexPath bundle)
              ("latexmk exited with code " <> Text.pack (show code) <> logExcerpt <> processSummary result)
          )
            { diagnosticHint = Just ("TeX work directory: " <> Text.pack workDirectory)
            }
        ]

inspectLatexEnvironment :: PdfEngine -> IO (Either [Diagnostic] LatexEnvironment)
inspectLatexEnvironment engine = inspectLatexEnvironmentWith engine findExecutable readProcessWithExitCode

inspectLatexEnvironmentWith
  :: PdfEngine
  -> (String -> IO (Maybe FilePath))
  -> (FilePath -> [String] -> String -> IO (ExitCode, String, String))
  -> IO (Either [Diagnostic] LatexEnvironment)
inspectLatexEnvironmentWith selectedEngine finder commandRunner = do
  latexmk <- finder "latexmk"
  let engineName = Text.unpack (renderPdfEngine selectedEngine)
      engineCode = renderPdfEngine selectedEngine
  engine <- finder engineName
  let missing =
        [ missingTool "latex.latexmk-missing" "latexmk" | latexmk == Nothing ]
          <> [missingTool ("latex." <> engineCode <> "-missing") engineCode | engine == Nothing]
  case (missing, latexmk, engine) of
    ([], Just latexmkPath, Just enginePath) -> do
      latexmkResult <- probeVersion commandRunner "latex.latexmk-unusable" "Latexmk" latexmkPath ["--version"]
      engineResult <-
        probeVersion
          commandRunner
          ("latex." <> engineCode <> "-unusable")
          (engineVersionMarker selectedEngine)
          enginePath
          ["--version"]
      pure $
        case (latexmkResult, engineResult) of
          (Right latexmkText, Right engineText) ->
            Right
              LatexEnvironment
                { latexmkExecutable = latexmkPath
                , latexmkVersion = latexmkText
                , latexEngine = selectedEngine
                , latexEngineExecutable = enginePath
                , latexEngineVersion = engineText
                }
          _ -> Left ([problem | Left problem <- [latexmkResult]] <> [problem | Left problem <- [engineResult]])
    _ -> pure (Left missing)

diagnoseLatexEnvironment :: PdfEngine -> IO (Either [Diagnostic] LatexEnvironment)
diagnoseLatexEnvironment engine = do
  inspected <- inspectLatexEnvironment engine
  case inspected of
    Left problems -> pure (Left problems)
    Right environment -> probeLatexEnvironmentWith runLatexmk environment

probeLatexEnvironmentWith :: LatexRunner -> LatexEnvironment -> IO (Either [Diagnostic] LatexEnvironment)
probeLatexEnvironmentWith runner environment =
  withSystemTempDirectory "tex2ss-latex-doctor" $ \root -> do
    let outputDirectory = root </> "out"
        sourcePath = root </> "probe.tex"
        expectedPdf = outputDirectory </> "probe.pdf"
        invocation =
          LatexInvocation
            { invocationWorkingDirectory = root
            , invocationOutputDirectory = outputDirectory
            , invocationSourcePath = sourcePath
            , invocationExpectedPdf = expectedPdf
            , invocationLatexInputDirectories = [root]
            }
    createDirectoryIfMissing True outputDirectory
    ByteString.writeFile sourcePath "\\documentclass{article}\n\\begin{document}\ntex2ss doctor\n\\end{document}\n"
    result <- runner environment invocation
    exists <- doesFileExist expectedPdf
    pure $
      case latexRunExitCode result of
        ExitSuccess
          | exists -> Right environment
          | otherwise ->
              Left [diagnostic Error "latex.probe-output-missing" "latexmk probe succeeded but produced no PDF"]
        ExitFailure code ->
          Left
            [ ( diagnostic
                  Error
                  "latex.probe-failed"
                  ("latexmk could not compile a minimal document (exit " <> Text.pack (show code) <> ")" <> processSummary result)
              )
                { diagnosticHint =
                    Just
                      ( "Check the TeX distribution, latexmk Perl runtime, and "
                          <> renderPdfEngine (latexEngine environment)
                          <> " package installation."
                      )
                }
            ]

runLatexmk :: LatexRunner
runLatexmk environment invocation = do
  inherited <- getEnvironment
  let arguments =
        latexmkRecipeOptions (latexEngine environment)
          <> [ "-outdir=" <> invocationOutputDirectory invocation
             , invocationSourcePath invocation
             ]
      process =
        (proc (latexmkExecutable environment) arguments)
          { cwd = Just (invocationWorkingDirectory invocation)
          , env = Just (withTexInputs (invocationLatexInputDirectories invocation) inherited)
          }
  operation <- try @IOException (readCreateProcessWithExitCode process "")
  pure $
    case operation of
      Left exception -> LatexRunResult (ExitFailure 127) "" (Text.pack $ show exception)
      Right (exitCode, stdoutText, stderrText) ->
        LatexRunResult exitCode (Text.pack stdoutText) (Text.pack stderrText)

latexmkEngineArgument :: PdfEngine -> String
latexmkEngineArgument PdfLaTeX = "-pdf"
latexmkEngineArgument XeLaTeX = "-xelatex"
latexmkEngineArgument LuaLaTeX = "-lualatex"

latexmkRecipeOptions :: PdfEngine -> [String]
latexmkRecipeOptions engine =
  [ "-norc"
  , latexmkEngineArgument engine
  , "-interaction=nonstopmode"
  , "-halt-on-error"
  , "-file-line-error"
  , "-recorder"
  ]

engineVersionMarker :: PdfEngine -> Text
engineVersionMarker PdfLaTeX = "pdfTeX"
engineVersionMarker XeLaTeX = "XeTeX"
engineVersionMarker LuaLaTeX = "Lua"

probeVersion
  :: (FilePath -> [String] -> String -> IO (ExitCode, String, String))
  -> Text
  -> Text
  -> FilePath
  -> [String]
  -> IO (Either Diagnostic Text)
probeVersion runner code marker executable arguments = do
  operation <- try @IOException (runner executable arguments "")
  pure $
    case operation of
      Left exception -> Left $ diagnosticAt Error code executable (Text.pack $ show exception)
      Right (ExitFailure exitCode, stdoutText, stderrText) ->
        Left $
          diagnosticAt
            Error
            code
            executable
            ( "version probe exited with code "
                <> Text.pack (show exitCode)
                <> summarizeText (Text.pack stdoutText <> "\n" <> Text.pack stderrText)
            )
      Right (ExitSuccess, stdoutText, stderrText) ->
        Right (versionOutputLine marker $ Text.pack stdoutText <> "\n" <> Text.pack stderrText)

missingTool :: Text -> Text -> Diagnostic
missingTool code name =
  (diagnostic Error code (name <> " was not found on PATH"))
    { diagnosticHint = Just "Install TeX Live or MiKTeX and ensure its bin directory is on PATH."
    }

versionOutputLine :: Text -> Text -> Text
versionOutputLine marker output =
  case filter (Text.isInfixOf marker) lines' of
    matching : _ -> matching
    [] -> case lines' of
      first : _ -> first
      [] -> "version unavailable"
 where
  lines' = filter (not . Text.null) (map Text.strip $ Text.lines output)

processSummary :: LatexRunResult -> Text
processSummary result = summarizeText (latexRunStdout result <> "\n" <> latexRunStderr result)

summarizeText :: Text -> Text
summarizeText value =
  case takeLast 18 (filter (not . Text.null) $ map Text.strip $ Text.lines value) of
    [] -> ""
    lines' -> "\n" <> Text.intercalate "\n" lines'

latexLogExcerpt :: FilePath -> IO Text
latexLogExcerpt path = do
  exists <- doesFileExist path
  if not exists
    then pure ""
    else do
      bytes <- ByteString.readFile path
      let lines' = Text.lines (TextEncoding.decodeUtf8With lenientDecode bytes)
      pure $
        case findIndex interesting lines' of
          Nothing -> ""
          Just index ->
            "\nTeX log excerpt:\n"
              <> Text.intercalate "\n" (take 6 $ drop (max 0 $ index - 1) lines')
 where
  interesting line =
    any
      (`Text.isInfixOf` line)
      [ "Undefined control sequence"
      , "LaTeX Error"
      , "Emergency stop"
      , "Fatal error occurred"
      ]

takeLast :: Int -> [value] -> [value]
takeLast count values = drop (max 0 $ length values - count) values

withTexInputs :: [FilePath] -> [(String, String)] -> [(String, String)]
withTexInputs directories inherited =
  ("TEXINPUTS", joined) : filter ((/= "TEXINPUTS") . Text.toUpper . Text.pack . fst) inherited
 where
  previous = snd <$> find ((== "TEXINPUTS") . Text.toUpper . Text.pack . fst) inherited
  pieces = directories <> maybe [] (: []) previous <> [""]
  joined = Text.unpack $ Text.intercalate (Text.singleton searchPathSeparator) (map Text.pack pieces)

pdfInputFingerprint :: ToJSON generated => LatexEnvironment -> ProjectPaths -> Bundle -> Text -> generated -> IO Text
pdfInputFingerprint environment paths bundle source generatedAst = do
  sharedLatex <- manifestIfPresent (projectRoot paths </> "latex")
  bundleMedia <- manifestIfPresent (bundleDirectory bundle </> "media")
  bundleLatex <- manifestIfPresent (bundleDirectory bundle </> "extension" </> "latex")
  let payload =
        encode $
          object
            [ "recipe" .= ("latexmk-pdf-v3-engine-selection" :: Text)
            , "latexmk" .= latexmkVersion environment
            , "engine" .= renderPdfEngine (latexEngine environment)
            , "engine_version" .= latexEngineVersion environment
            , "latexmk_options" .= map Text.pack (latexmkRecipeOptions $ latexEngine environment)
            , "source" .= source
            , "generated_ast" .= generatedAst
            , "shared_latex" .= sharedLatex
            , "bundle_media" .= bundleMedia
            , "bundle_latex" .= bundleLatex
            ]
      digest = hashlazy payload :: Digest SHA256
  pure (Text.pack $ show digest)

manifestIfPresent :: FilePath -> IO Manifest
manifestIfPresent root = do
  exists <- doesDirectoryExist root
  if exists then createManifest root else pure (Manifest 1 [])

cachedOutputIsReusable :: PdfState -> FilePath -> Text -> FilePath -> IO Bool
cachedOutputIsReusable state relativeOutput fingerprint publishedOutput = do
  exists <- doesFileExist publishedOutput
  if not exists
    then pure False
    else
      case Map.lookup relativeOutput (pdfStateOutputs state) of
        Just entry
          | cacheInputFingerprint entry == fingerprint ->
              (== cacheOutputSha256 entry) <$> fileSha256 publishedOutput
        _ -> pure False

fileSha256 :: FilePath -> IO Text
fileSha256 path = do
  bytes <- ByteString.readFile path
  pure . Text.pack . show $ (hash bytes :: Digest SHA256)

loadPdfState :: FilePath -> IO PdfState
loadPdfState path = do
  exists <- doesFileExist path
  if not exists
    then pure (PdfState Map.empty)
    else do
      decoded <- eitherDecodeFileStrict' path
      pure $ either (const $ PdfState Map.empty) id decoded

writePdfState :: FilePath -> PdfState -> IO ()
writePdfState path state = do
  createDirectoryIfMissing True (takeDirectory path)
  LazyByteString.writeFile path (encode state)

pdfStatePath :: ProjectPaths -> FilePath
pdfStatePath paths = projectState paths </> "pdf-state.json"

pdfTemporaryDirectory :: ProjectPaths -> FilePath
pdfTemporaryDirectory paths = projectState paths </> "tmp" </> "pdf"

bundlePdfWorkDirectory :: ProjectPaths -> Slot -> FilePath
bundlePdfWorkDirectory paths (Slot []) = pdfTemporaryDirectory paths </> "_root"
bundlePdfWorkDirectory paths (Slot segments) =
  foldl (</>) (pdfTemporaryDirectory paths) (map Text.unpack segments)

resetDirectory :: FilePath -> IO ()
resetDirectory path = do
  fileExists <- doesFileExist path
  directoryExists <- doesDirectoryExist path
  when (fileExists || directoryExists) (removePathForcibly path)
  createDirectoryIfMissing True path
