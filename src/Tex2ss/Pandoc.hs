{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Pandoc
  ( PreparedBundle (..)
  , prepareBundleSource
  , renderBundleHtml
  , renderBundleLaTeX
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
import System.FilePath ((</>))
import Text.Pandoc
  ( Extension (Ext_raw_tex)
  , Pandoc (Pandoc)
  , PandocError
  , enableExtension
  , nullMeta
  , readLaTeX
  , runIO
  , writeHtml5String
  , writeLaTeX
  )
import Text.Pandoc.Class (PandocIO)
import Text.Pandoc.Definition
  ( Block (Para, Plain, RawBlock)
  , Format (..)
  , Inline (RawInline, Str)
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
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Generator
  ( AssembledSource (..)
  , GeneratorResult (GeneratorResult)
  , assembleGeneratedSource
  , pandocFragmentMarker
  , runPreGenerator
  )
import Tex2ss.Include (ExpandedSource (expandedText), expandBundleSource)
import Tex2ss.Paths (resolveExistingUnder)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (metadataFilters, metadataGenerator)
  , ProjectPaths (projectPandoc)
  , SiteConfig (configFilters)
  , SiteIndex
  )

data PreparedBundle = PreparedBundle
  { preparedSource :: Text
  , preparedPandocFragments :: Map Text [Block]
  }
  deriving stock (Eq, Show)

renderBundleHtml :: ProjectPaths -> SiteConfig -> SiteIndex -> Bundle -> IO (Either [Diagnostic] Text)
renderBundleHtml paths config siteIndex bundle = do
  source <- prepareBundleSource paths siteIndex bundle
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
      runPipeline (bundleIndexPath bundle) (global <> local) prepared

prepareBundleSource :: ProjectPaths -> SiteIndex -> Bundle -> IO (Either [Diagnostic] PreparedBundle)
prepareBundleSource _ siteIndex bundle = do
  source <- expandBundleSource (bundleDirectory bundle) (bundleIndexPath bundle)
  generated <- resolveGenerator
  pure $ do
    expanded <- source
    fragments <- generated
    assembled <- assembleGeneratedSource (bundleIndexPath bundle) fragments (expandedText expanded)
    pure
      PreparedBundle
        { preparedSource = assembledText assembled
        , preparedPandocFragments = assembledPandocFragments assembled
        }
 where
  resolveGenerator =
    case metadataGenerator (bundleMetadata bundle) of
      Nothing -> pure (Right $ GeneratorResult mempty)
      Just relative -> do
        resolved <- resolveExistingUnder (bundleDirectory bundle </> "extension") relative
        case resolved of
          Left problem -> pure (Left [problem])
          Right scriptPath -> runPreGenerator scriptPath siteIndex bundle

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
  replaceFragment source name body = Text.replace (pandocFragmentMarker name) body source

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

runPipeline :: FilePath -> [FilePath] -> PreparedBundle -> IO (Either [Diagnostic] Text)
runPipeline sourcePath filters prepared = do
  let readerOptions =
        def
          { readerExtensions = enableExtension Ext_raw_tex (readerExtensions def)
          }
      writerOptions =
        def
          { writerMathMethod = MathJax ""
          , writerSectionDivs = True
          }
      environment = Environment readerOptions writerOptions
  operation <- try @PandocError . runIO $ do
    parsed <- readLaTeX readerOptions [(sourcePath, preparedSource prepared)]
    document <-
      either (throwError . PandocAppError) pure $
        splicePandocFragments (preparedPandocFragments prepared) parsed
    filtered <- foldM (\current filterPath -> applyFilter environment ["html5"] filterPath current) document filters
    let normalized = normalizeTemplateOwnedLayout filtered
    case residualRawTeX normalized of
      [] -> writeHtml5String writerOptions normalized
      leftovers -> failResidual leftovers
  pure $
    case operation of
      Left problem -> Left [pandocDiagnostic sourcePath problem]
      Right result ->
        case result of
          Left problem -> Left [pandocDiagnostic sourcePath problem]
          Right html -> Right html

splicePandocFragments :: Map Text [Block] -> Pandoc -> Either Text Pandoc
splicePandocFragments fragments document
  | not (Set.null missing) =
      Left $
        "generated Pandoc block markers were not parsed in block context: "
          <> Text.intercalate ", " (Set.toAscList missing)
  | otherwise = Right (walk replaceBlocks document)
 where
  byMarker = Map.fromList [(pandocFragmentMarker name, blocks) | (name, blocks) <- Map.toList fragments]
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

failResidual :: [(Text, Text)] -> PandocIO Text
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
