{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Pandoc
  ( PreparedBundle (..)
  , RenderedBundle (..)
  , analyzePreparedBundle
  , prepareBundleSource
  , prepareBundleSourceWith
  , renderBundleHtml
  , renderBundleHtmlWith
  , renderBundleLaTeX
  , runFilteredDocument
  , runFilteredDocumentWithResources
  ) where

import Control.Exception (try)
import Control.Monad (foldM)
import Control.Monad.Except (throwError)
import Data.Default (def)
import Data.Either (partitionEithers)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import System.FilePath (takeDirectory, (</>))
import Text.Pandoc
  ( Extension (Ext_raw_tex)
  , Pandoc (Pandoc)
  , PandocError
  , enableExtension
  , getDefaultExtensions
  , nullMeta
  , readLaTeX
  , runIO
  , writeHtml5String
  , writeLaTeX
  )
import Text.Pandoc.Citeproc (processCitations)
import Text.Pandoc.Class (PandocIO, setResourcePath)
import Text.Pandoc.Definition
  ( Block (BulletList, Para, Plain, RawBlock)
  , Format (..)
  , Inline (RawInline, Str)
  , lookupMeta
  )
import Text.Pandoc.Error (PandocError (PandocAppError), renderError)
import Text.Pandoc.Filter (Environment (..))
import Text.Pandoc.Lua (applyFilter)
import Text.Pandoc.Options
  ( MathMethod (MathJax)
  , ReaderOptions (readerExtensions)
  , WrapOption (WrapNone)
  , WriterOptions (writerMathMethod, writerSectionDivs, writerWrapText)
  )
import Text.Pandoc.Walk (query, walk)
import Text.Pandoc.Writers.Shared (toTableOfContents)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Plugin
  ( AssembledSource (..)
  , PluginAnalysis
  , PluginPlan
  , assembleGeneratedSource
  , preparePluginPlan
  , runPluginAnalyzers
  , runPluginGenerators
  )
import Tex2ss.Include (ExpandedSource (expandedText), expandBundleSource)
import Tex2ss.Paths (resolveExistingUnder)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (metadataFilters)
  , ProjectPaths (projectLatex, projectPandoc)
  , SiteConfig (configFilters)
  , SiteIndex
  )

data PreparedBundle = PreparedBundle
  { preparedSource :: Text
  , preparedPandocFragments :: Map Text [Block]
  }
  deriving stock (Eq, Show)

data RenderedBundle = RenderedBundle
  { renderedHtml :: Text
  , renderedToc :: Text
  , renderedAnalyses :: [PluginAnalysis]
  }
  deriving stock (Eq, Show)

renderBundleHtml :: ProjectPaths -> SiteConfig -> SiteIndex -> Bundle -> IO (Either [Diagnostic] Text)
renderBundleHtml paths config siteIndex bundle = do
  plan <- preparePluginPlan paths siteIndex [bundle]
  case plan of
    Left problems -> pure (Left problems)
    Right pluginPlan ->
      fmap (fmap renderedHtml) $
        renderBundleHtmlWith paths config siteIndex pluginPlan [] bundle

renderBundleHtmlWith
  :: ProjectPaths
  -> SiteConfig
  -> SiteIndex
  -> PluginPlan
  -> [PluginAnalysis]
  -> Bundle
  -> IO (Either [Diagnostic] RenderedBundle)
renderBundleHtmlWith paths config siteIndex pluginPlan analyses bundle = do
  source <- prepareBundleSourceWith paths siteIndex pluginPlan analyses bundle
  globalFilters <- resolveFilters (projectPandoc paths) (configFilters config)
  localFilters <-
    resolveFilters
      (bundleDirectory bundle </> "extension")
      (metadataFilters $ bundleMetadata bundle)
  case (source, globalFilters, localFilters) of
    (Left problems, _, _) -> pure (Left problems)
    (_, Left problems, _) -> pure (Left problems)
    (_, _, Left problems) -> pure (Left problems)
    (Right prepared, Right global, Right local) ->
      runHtmlPipeline paths siteIndex pluginPlan bundle (global <> local) prepared

prepareBundleSource :: ProjectPaths -> SiteIndex -> Bundle -> IO (Either [Diagnostic] PreparedBundle)
prepareBundleSource paths siteIndex bundle = do
  plan <- preparePluginPlan paths siteIndex [bundle]
  case plan of
    Left problems -> pure (Left problems)
    Right pluginPlan -> prepareBundleSourceWith paths siteIndex pluginPlan [] bundle

prepareBundleSourceWith
  :: ProjectPaths
  -> SiteIndex
  -> PluginPlan
  -> [PluginAnalysis]
  -> Bundle
  -> IO (Either [Diagnostic] PreparedBundle)
prepareBundleSourceWith _ siteIndex pluginPlan analyses bundle = do
  source <- expandBundleSource (bundleDirectory bundle) (bundleIndexPath bundle)
  generated <- runPluginGenerators siteIndex pluginPlan analyses bundle
  pure $ do
    expanded <- source
    fragments <- generated
    assembled <- assembleGeneratedSource (bundleIndexPath bundle) fragments (expandedText expanded)
    pure
      PreparedBundle
        { preparedSource = assembledText assembled
        , preparedPandocFragments = assembledPandocFragments assembled
        }

analyzePreparedBundle
  :: ProjectPaths
  -> SiteConfig
  -> SiteIndex
  -> PluginPlan
  -> Bundle
  -> PreparedBundle
  -> IO (Either [Diagnostic] [PluginAnalysis])
analyzePreparedBundle paths config siteIndex pluginPlan bundle prepared = do
  globalFilters <- resolveFilters (projectPandoc paths) (configFilters config)
  localFilters <-
    resolveFilters
      (bundleDirectory bundle </> "extension")
      (metadataFilters $ bundleMetadata bundle)
  case (globalFilters, localFilters) of
    (Left problems, _) -> pure (Left problems)
    (_, Left problems) -> pure (Left problems)
    (Right global, Right local) -> do
      filtered <-
        runFilteredDocumentWithResources
          (pandocResourcePaths paths bundle)
          (bundleIndexPath bundle)
          (global <> local)
          prepared
      case filtered of
        Left problems -> pure (Left problems)
        Right document -> runPluginAnalyzers siteIndex pluginPlan bundle document

renderBundleLaTeX :: FilePath -> PreparedBundle -> IO (Either [Diagnostic] Text)
renderBundleLaTeX sourcePath prepared = do
  let writerOptions = def {writerWrapText = WrapNone}
  operation <- try @PandocError . runIO $ do
    lowered <-
      traverse
        (writeLaTeX writerOptions . Pandoc nullMeta)
        (preparedPandocFragments prepared)
    let withFragments = Map.foldlWithKey' replaceFragment (preparedSource prepared) lowered
    pure $ insertPandocSnippetPrelude (Map.elems lowered) withFragments
  pure $
    case operation of
      Left problem -> Left [pandocDiagnostic sourcePath problem]
      Right result ->
        case result of
          Left problem -> Left [pandocDiagnostic sourcePath problem]
          Right source -> Right source
 where
  replaceFragment source marker body = Text.replace marker body source

insertPandocSnippetPrelude :: [Text] -> Text -> Text
insertPandocSnippetPrelude snippets source
  | null helpers = source
  | Text.null afterDocumentStart = source
  | otherwise = beforeDocumentStart <> Text.unlines helpers <> afterDocumentStart
 where
  combined = Text.concat snippets
  helpers =
    ( if "\\tightlist" `Text.isInfixOf` combined
        then
          [ "\\providecommand{\\tightlist}{%"
          , "  \\setlength{\\itemsep}{0pt}\\setlength{\\parskip}{0pt}}"
          ]
        else []
    )
      <> ["\\providecommand{\\passthrough}[1]{#1}" | "\\passthrough" `Text.isInfixOf` combined]
      <> ["\\providecommand{\\pandocbounded}[1]{#1}" | "\\pandocbounded" `Text.isInfixOf` combined]
  (beforeDocumentStart, afterDocumentStart) = Text.breakOn "\\begin{document}" source

resolveFilters :: FilePath -> [FilePath] -> IO (Either [Diagnostic] [FilePath])
resolveFilters root filters = do
  resolved <- traverse (resolveExistingUnder root) filters
  let (problems, paths) = partitionEithers resolved
  pure $ if null problems then Right paths else Left problems

runHtmlPipeline :: ProjectPaths -> SiteIndex -> PluginPlan -> Bundle -> [FilePath] -> PreparedBundle -> IO (Either [Diagnostic] RenderedBundle)
runHtmlPipeline paths siteIndex pluginPlan bundle filters prepared = do
  filtered <-
    runFilteredDocumentWithResources
      (pandocResourcePaths paths bundle)
      (bundleIndexPath bundle)
      filters
      prepared
  case filtered of
    Left problems -> pure (Left problems)
    Right document -> do
      analyzed <- runPluginAnalyzers siteIndex pluginPlan bundle document
      case analyzed of
        Left problems -> pure (Left problems)
        Right analyses -> writeHtmlDocument (bundleIndexPath bundle) document analyses

runFilteredDocument :: FilePath -> [FilePath] -> PreparedBundle -> IO (Either [Diagnostic] Pandoc)
runFilteredDocument sourcePath =
  runFilteredDocumentWithResources [takeDirectory sourcePath] sourcePath

runFilteredDocumentWithResources
  :: [FilePath]
  -> FilePath
  -> [FilePath]
  -> PreparedBundle
  -> IO (Either [Diagnostic] Pandoc)
runFilteredDocumentWithResources resourcePaths sourcePath filters prepared = do
  let readerOptions =
        def
          { readerExtensions = enableExtension Ext_raw_tex (getDefaultExtensions "latex")
          }
      writerOptions =
        def
          { writerMathMethod = MathJax ""
          , writerSectionDivs = True
          , writerWrapText = WrapNone
          }
      environment = Environment readerOptions writerOptions
  operation <- try @PandocError . runIO $ do
    setResourcePath resourcePaths
    parsed <- readLaTeX readerOptions [(sourcePath, preparedSource prepared)]
    document <-
      either (throwError . PandocAppError) pure $
        splicePandocFragments (preparedPandocFragments prepared) parsed
    filtered <- foldM (\current filterPath -> applyFilter environment ["html5"] filterPath current) document filters
    case filtered of
      Pandoc metadata _
        | lookupMeta "bibliography" metadata /= Nothing
            || lookupMeta "references" metadata /= Nothing -> processCitations filtered
      _ -> pure filtered
  pure $
    case operation of
      Left problem -> Left [pandocDiagnostic sourcePath problem]
      Right result ->
        case result of
          Left problem -> Left [pandocDiagnostic sourcePath problem]
          Right document -> Right document

pandocResourcePaths :: ProjectPaths -> Bundle -> [FilePath]
pandocResourcePaths paths bundle =
  [ bundleDirectory bundle
  , bundleDirectory bundle </> "extension"
  , projectLatex paths
  ]

writeHtmlDocument
  :: FilePath
  -> Pandoc
  -> [PluginAnalysis]
  -> IO (Either [Diagnostic] RenderedBundle)
writeHtmlDocument sourcePath filtered analyses = do
  let writerOptions =
        def
          { writerMathMethod = MathJax ""
          , writerSectionDivs = True
          , writerWrapText = WrapNone
          }
      normalized = normalizeTemplateOwnedLayout filtered
  operation <- try @PandocError . runIO $
    case residualRawTeX normalized of
      [] -> do
        html <- writeHtml5String writerOptions normalized
        toc <- writeTableOfContents writerOptions normalized
        pure (html, toc)
      leftovers -> failResidual leftovers
  pure $
    case operation of
      Left problem -> Left [pandocDiagnostic sourcePath problem]
      Right result ->
        case result of
          Left problem -> Left [pandocDiagnostic sourcePath problem]
          Right (html, toc) -> Right (RenderedBundle html toc analyses)

writeTableOfContents :: WriterOptions -> Pandoc -> PandocIO Text
writeTableOfContents writerOptions (Pandoc _ blocks) =
  case toTableOfContents writerOptions blocks of
    BulletList [] -> pure ""
    toc -> writeHtml5String writerOptions (Pandoc nullMeta [toc])

splicePandocFragments :: Map Text [Block] -> Pandoc -> Either Text Pandoc
splicePandocFragments fragments document
  | not (Set.null missing) =
      Left $
        "generated Pandoc block markers were not parsed in block context: "
          <> Text.intercalate ", " (Set.toAscList missing)
  | otherwise = Right (walk replaceBlocks document)
 where
  byMarker = fragments
  expected = Map.keysSet byMarker
  present = Set.fromList (query markerInBlock document)
  missing = expected `Set.difference` present

  markerInBlock = \case
    Para [Str marker] | Map.member marker byMarker -> [marker]
    Plain [Str marker] | Map.member marker byMarker -> [marker]
    _ -> []

  replaceBlocks :: [Block] -> [Block]
  replaceBlocks = concatMap $ \case
    Para [Str marker] | Just blocks <- Map.lookup marker byMarker -> blocks
    Plain [Str marker] | Just blocks <- Map.lookup marker byMarker -> blocks
    block -> [block]

failResidual :: [(Text, Text)] -> PandocIO value
failResidual leftovers =
  throwError . PandocAppError $
    "unsupported raw TeX remains after filters: "
      <> Text.intercalate "; " (map summarize $ take 8 leftovers)
 where
  summarize (kind, body) = kind <> " " <> Text.take 120 (Text.unwords $ Text.words body)

residualRawTeX :: Pandoc -> [(Text, Text)]
residualRawTeX document = blockRaws <> inlineRaws
 where
  blockRaws = query blockRaw document
  inlineRaws = query inlineRaw document
  blockRaw = \case
    RawBlock format body | isTeX format && contentful body -> [("block", body)]
    _ -> []
  inlineRaw = \case
    RawInline format body | isTeX format && contentful body -> [("inline", body)]
    _ -> []
  isTeX (Format format) = Text.toCaseFold format `elem` ["tex", "latex"]
  contentful = not . Text.null . Text.strip

normalizeTemplateOwnedLayout :: Pandoc -> Pandoc
normalizeTemplateOwnedLayout = walk normalizeBlock
 where
  normalizeBlock block@(RawBlock format body)
    | isTeX format && Text.strip body == "\\maketitle" = Plain []
    | otherwise = block
  normalizeBlock block = block
  isTeX (Format format) = Text.toCaseFold format `elem` ["tex", "latex"]

pandocDiagnostic :: FilePath -> PandocError -> Diagnostic
pandocDiagnostic sourcePath problem =
  diagnosticAt Error "pandoc.failed" sourcePath (renderError problem)
