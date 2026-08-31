{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Pandoc
  ( renderBundleHtml
  ) where

import Control.Monad (foldM)
import Control.Monad.Except (throwError)
import Control.Exception (try)
import Data.Default (def)
import Data.Either (partitionEithers)
import Data.Text (Text)
import qualified Data.Text as Text
import System.FilePath ((</>))
import Text.Pandoc
  ( Extension (Ext_raw_tex)
  , Pandoc
  , PandocError
  , enableExtension
  , readLaTeX
  , runIO
  , writeHtml5String
  )
import Text.Pandoc.Class (PandocIO)
import Text.Pandoc.Definition (Block (Plain, RawBlock), Format (..), Inline (RawInline))
import Text.Pandoc.Error (PandocError (PandocAppError), renderError)
import Text.Pandoc.Filter (Environment (..))
import Text.Pandoc.Lua (applyFilter)
import Text.Pandoc.Options
  ( MathMethod (MathJax)
  , ReaderOptions (readerExtensions)
  , WriterOptions (writerMathMethod, writerSectionDivs)
  )
import Text.Pandoc.Walk (query, walk)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Include (ExpandedSource (expandedText), expandBundleSource)
import Tex2ss.Paths (resolveExistingUnder)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (metadataFilters)
  , ProjectPaths (projectPandoc)
  , SiteConfig (configFilters)
  )

renderBundleHtml :: ProjectPaths -> SiteConfig -> Bundle -> IO (Either [Diagnostic] Text)
renderBundleHtml paths config bundle = do
  source <- expandBundleSource (bundleDirectory bundle) (bundleIndexPath bundle)
  globalFilters <- resolveFilters (projectPandoc paths) (configFilters config)
  localFilters <-
    resolveFilters
      (bundleDirectory bundle </> "extension")
      (metadataFilters $ bundleMetadata bundle)
  case (source, globalFilters, localFilters) of
    (Left problems, _, _) -> pure (Left problems)
    (_, Left problems, _) -> pure (Left problems)
    (_, _, Left problems) -> pure (Left problems)
    (Right expanded, Right global, Right local) ->
      runPipeline (bundleIndexPath bundle) (global <> local) (expandedText expanded)

resolveFilters :: FilePath -> [FilePath] -> IO (Either [Diagnostic] [FilePath])
resolveFilters root filters = do
  resolved <- traverse (resolveExistingUnder root) filters
  let (problems, paths) = partitionEithers resolved
  pure $ if null problems then Right paths else Left problems

runPipeline :: FilePath -> [FilePath] -> Text -> IO (Either [Diagnostic] Text)
runPipeline sourcePath filters source = do
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
    document <- readLaTeX readerOptions [(sourcePath, source)]
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
