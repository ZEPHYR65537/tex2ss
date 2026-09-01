{-# LANGUAGE OverloadedStrings #-}

module PandocSpec (tests) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)
import Tex2ss.Build (buildHtml)
import Tex2ss.Diagnostics (Diagnostic (..))
import Tex2ss.Pandoc (RenderedBundle (renderedToc), renderBundleHtml, renderBundleHtmlWith)
import Tex2ss.Paths (mkProjectPaths)
import Tex2ss.Plugin (preparePluginPlan)
import Tex2ss.Scaffold (initializeProject)
import Tex2ss.SiteIndex (buildSiteIndex)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (..)
  , PdfEngine (PdfLaTeX)
  , SiteConfig (..)
  , SiteSettings (..)
  , Slot (..)
  , Visibility (Published)
  )

tests :: TestTree
tests =
  testGroup
    "pandoc adapter"
    [ testCase "runs configured Lua filters in process" $
        withSystemTempDirectory "tex2ss-pandoc" $ \root -> do
          (config, bundle, filterPath) <- fixture root
          TextIO.writeFile filterPath validFilter
          result <- renderBundleHtml (mkProjectPaths root) config (buildSiteIndex [bundle]) bundle
          case result of
            Left _ -> assertBool "expected Pandoc success" False
            Right html -> assertBool "Lua filter result missing" ("Filtered by Lua" `Text.isInfixOf` html)
    , testCase "turns Lua syntax exceptions into stable diagnostics" $
        withSystemTempDirectory "tex2ss-pandoc" $ \root -> do
          (config, bundle, filterPath) <- fixture root
          TextIO.writeFile filterPath "function Para(element) this is invalid end"
          result <- renderBundleHtml (mkProjectPaths root) config (buildSiteIndex [bundle]) bundle
          case result of
            Left problems -> do
              assertBool "expected pandoc.failed" ("pandoc.failed" `elem` map diagnosticCode problems)
              assertBool "expected Lua detail" (any (Text.isInfixOf "syntax" . diagnosticMessage) problems)
            Right _ -> assertBool "expected Lua filter failure" False
    , testCase "splices generated Pandoc blocks before filters run" $
        withSystemTempDirectory "tex2ss-pandoc" $ \root -> do
          (config, originalBundle, filterPath) <- fixture root
          let extensionDirectory = bundleDirectory originalBundle </> "extension" </> "semantic"
              generatorPath = extensionDirectory </> "init.lua"
              bundle = originalBundle
          createDirectoryIfMissing True extensionDirectory
          TextIO.writeFile (bundleIndexPath bundle) generatedSourceDocument
          TextIO.writeFile generatorPath semanticGenerator
          TextIO.writeFile filterPath generatedBlockFilter
          result <- renderBundleHtml (mkProjectPaths root) config (buildSiteIndex [bundle]) bundle
          case result of
            Left _ -> assertBool "expected generated Pandoc block success" False
            Right html -> do
              assertBool "filter did not see generated AST" ("Filtered semantic block" `Text.isInfixOf` html)
              assertBool "first deferred fragment is missing" ("First deferred paragraph" `Text.isInfixOf` html)
              assertBool "second deferred fragment is missing" ("Second deferred paragraph" `Text.isInfixOf` html)
              assertBool "internal marker leaked" (not $ "texssgeneratedpandocblocks" `Text.isInfixOf` html)
    , testCase "uses the Pandoc LaTeX reader profile for author macros" $
        withSystemTempDirectory "tex2ss-pandoc-macros" $ \root -> do
          (configured, bundle, _) <- fixture root
          let config = configured {configFilters = []}
          TextIO.writeFile (bundleIndexPath bundle) macroDocument
          result <- renderBundleHtml (mkProjectPaths root) config (buildSiteIndex [bundle]) bundle
          case result of
            Left _ -> assertBool "expected LaTeX macro expansion" False
            Right html ->
              assertBool
                "expanded macro did not become semantic HTML"
                ("<strong>Expanded macro</strong>" `Text.isInfixOf` html)
    , testCase "preserves native math, citations, figures and references" $
        withSystemTempDirectory "tex2ss-pandoc-native-semantics" $ \root -> do
          initialized <- initializeProject root "Native semantics"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          TextIO.writeFile (root </> "latex" </> "bibliography" </> "references.bib") nativeBibliography
          TextIO.writeFile (root </> "content" </> "index.tex") nativeSemanticDocument
          buildHtml root False >>= either (const $ assertBool "expected native Pandoc semantics" False) (const $ pure ())
          html <- TextIO.readFile (root </> "public" </> "index.html")
          let rendered = Text.unpack html
          assertBool ("inline math missing: " <> rendered) ("math inline" `Text.isInfixOf` html)
          assertBool ("display math missing: " <> rendered) ("math display" `Text.isInfixOf` html)
          assertBool ("citation AST missing: " <> rendered) ("data-cites=\"doe2026\"" `Text.isInfixOf` html)
          assertBool ("processed bibliography missing: " <> rendered) ("Doe" `Text.isInfixOf` html && "id=\"refs\"" `Text.isInfixOf` html)
          assertBool ("figure missing: " <> rendered) ("<figure" `Text.isInfixOf` html)
          assertBool ("figure reference missing: " <> rendered) ("href=\"#fig:demo\"" `Text.isInfixOf` html)
          assertBool ("equation reference missing: " <> rendered) ("href=\"#eq:demo\"" `Text.isInfixOf` html)
    , testCase "derives the template TOC from the filtered document" $
        withSystemTempDirectory "tex2ss-pandoc-toc" $ \root -> do
          (config, bundle, filterPath) <- fixture root
          TextIO.writeFile (bundleIndexPath bundle) sectionDocument
          TextIO.writeFile filterPath headingFilter
          let paths = mkProjectPaths root
              siteIndex = buildSiteIndex [bundle]
          pluginPlan <- preparePluginPlan paths siteIndex [bundle]
          case pluginPlan of
            Left _ -> assertBool "expected empty plugin plan" False
            Right plan -> do
              result <- renderBundleHtmlWith paths config siteIndex plan [] bundle
              case result of
                Left _ -> assertBool "expected TOC derivation" False
                Right rendered -> do
                  assertBool
                    ("filtered heading missing from TOC: " <> Text.unpack (renderedToc rendered))
                    ("Filtered heading" `Text.isInfixOf` renderedToc rendered)
                  assertBool "TOC did not link to the generated heading id" ("#filtered-heading" `Text.isInfixOf` renderedToc rendered)
    ]

fixture :: FilePath -> IO (SiteConfig, Bundle, FilePath)
fixture root = do
  let bundleDirectory = root </> "content"
      indexPath = bundleDirectory </> "index.tex"
      metaPath = bundleDirectory </> "meta.json"
      filterDirectory = root </> "pandoc" </> "filters"
      filterPath = filterDirectory </> "test.lua"
  createDirectoryIfMissing True (bundleDirectory </> "sources")
  createDirectoryIfMissing True filterDirectory
  TextIO.writeFile indexPath sourceDocument
  TextIO.writeFile metaPath "{}"
  let config =
        SiteConfig
          1
          (SiteSettings "Test" "" "" "en" "" Nothing)
          (Map.singleton "default" "default.html")
          "default"
          ["filters/test.lua"]
          PdfLaTeX
          Map.empty
      metadata = BundleMetadata 1 "Page" Nothing Nothing Nothing Published [] Map.empty Nothing
      bundle = Bundle (Slot []) bundleDirectory indexPath metaPath metadata
  pure (config, bundle, filterPath)

sourceDocument :: Text.Text
sourceDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , "Original paragraph."
    , "\\end{document}"
    ]

validFilter :: Text.Text
validFilter =
  Text.unlines
    [ "function Para(element)"
    , "  return pandoc.Para({ pandoc.Str('Filtered by Lua') })"
    , "end"
    ]

generatedSourceDocument :: Text.Text
generatedSourceDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , "\\texssgenerated{semantic}{first}"
    , "\\texssgenerated{semantic}{semantic}"
    , "\\texssgenerated{semantic}{second}"
    , "\\end{document}"
    ]

semanticGenerator :: Text.Text
semanticGenerator =
  Text.unlines
    [ "local tex2ss = require 'tex2ss'"
    , "return {"
    , "  generate = function(context)"
    , "    return {"
    , "      first = tex2ss.latex('First deferred paragraph.'),"
    , "      semantic = tex2ss.blocks(pandoc.Blocks({ pandoc.Para({ pandoc.Str('Generated semantic block') }) })),"
    , "      second = tex2ss.latex('Second deferred paragraph.')"
    , "    }"
    , "  end"
    , "}"
    ]

generatedBlockFilter :: Text.Text
generatedBlockFilter =
  Text.unlines
    [ "function Para(element)"
    , "  if pandoc.utils.stringify(element) == 'Generated semantic block' then"
    , "    return pandoc.Para({ pandoc.Str('Filtered semantic block') })"
    , "  end"
    , "end"
    ]

macroDocument :: Text.Text
macroDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\newcommand{\\important}[1]{\\textbf{#1}}"
    , "\\begin{document}"
    , "\\important{Expanded macro}"
    , "\\end{document}"
    ]

sectionDocument :: Text.Text
sectionDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , "\\section{Original heading}"
    , "Body."
    , "\\end{document}"
    ]

headingFilter :: Text.Text
headingFilter =
  Text.unlines
    [ "function Header(element)"
    , "  element.content = pandoc.Inlines({ pandoc.Str('Filtered heading') })"
    , "  element.identifier = 'filtered-heading'"
    , "  return element"
    , "end"
    ]

nativeSemanticDocument :: Text.Text
nativeSemanticDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , "Inline math $x^2 + y^2 = z^2$."
    , "\\[a^2 + b^2 = c^2\\]"
    , "\\begin{equation}\\label{eq:demo}E = mc^2\\end{equation}"
    , "See Equation \\ref{eq:demo}; cite \\cite{doe2026}."
    , "\\begin{figure}"
    , "\\centering"
    , "\\includegraphics{media/figure.png}"
    , "\\caption{A figure}\\label{fig:demo}"
    , "\\end{figure}"
    , "See Figure \\ref{fig:demo}."
    , "\\bibliography{bibliography/references.bib}"
    , "\\end{document}"
    ]

nativeBibliography :: Text.Text
nativeBibliography =
  Text.unlines
    [ "@article{doe2026,"
    , "  author = {Doe, Jane},"
    , "  title = {Semantic Sites},"
    , "  journal = {Example Journal},"
    , "  year = {2026}"
    , "}"
    ]
