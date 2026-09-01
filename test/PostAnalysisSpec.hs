{-# LANGUAGE OverloadedStrings #-}

module PostAnalysisSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.Aeson (object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Text.Pandoc.Definition (Pandoc (Pandoc), nullMeta)
import Tex2ss.Analysis (AnalysisExport (AnalysisExport), matchingAnalyzerBundles, runPostAnalyzer)
import Tex2ss.Build (buildHtml)
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Generator (runPreGeneratorWith)
import Tex2ss.Pdf
  ( LatexEnvironment (..)
  , LatexInvocation (..)
  , LatexRunResult (LatexRunResult)
  , buildPdfWith
  )
import Tex2ss.Scaffold (initializeProject)
import Tex2ss.SiteIndex (buildSiteIndex)
import Tex2ss.Types
  ( AnalyzerSpec (AnalyzerSpec)
  , Bundle (Bundle)
  , BundleMetadata (BundleMetadata, metadataAnalysisInputs, metadataGenerator)
  , PdfEngine (PdfLaTeX)
  , Slot (Slot)
  , Visibility (Published)
  )

tests :: TestTree
tests =
  testGroup
    "post-analyzer upward fold"
    [ testCase "folds filtered descendant AST into an ancestor HTML tree" $
        withSystemTempDirectory "tex2ss-analysis" $ \root -> do
          initializeAnalysisFixture root
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "child analysis missing from root" ("Child source filtered" `Text.isInfixOf` html)
          assertBool "grandchild analysis missing from root" ("Grandchild source filtered" `Text.isInfixOf` html)
          assertBool "expected nested list" (Text.count "<ul" html >= 2)
    , testCase "uses the same descendant exports before the PDF root is staged" $
        withSystemTempDirectory "tex2ss-analysis-pdf" $ \root -> do
          initializeAnalysisFixture root
          rootSource <- newIORef ""
          let runner _ invocation = do
                source <- TextIO.readFile (invocationSourcePath invocation)
                if invocationWorkingDirectory invocation == root </> "content"
                  then writeIORef rootSource source
                  else pure ()
                createDirectoryIfMissing True (invocationOutputDirectory invocation)
                ByteString.writeFile (invocationExpectedPdf invocation) "%PDF-analysis-fixture"
                pure (LatexRunResult ExitSuccess "" "")
          buildPdfWith fakeEnvironment runner root False >>= (@?= Right True)
          source <- readIORef rootSource
          assertBool "child analysis missing from root TeX" ("Child source filtered" `Text.isInfixOf` source)
          assertBool "grandchild analysis missing from root TeX" ("Grandchild source filtered" `Text.isInfixOf` source)
          assertBool "Pandoc list was not lowered" ("\\begin{itemize}" `Text.isInfixOf` source)
    , testCase "preserves the public snapshot when a descendant analyzer fails" $
        withSystemTempDirectory "tex2ss-analysis-failure" $ \root -> do
          initializeAnalysisFixture root
          buildHtml root False >>= (@?= Right True)
          let publicIndex = root </> "public" </> "index.html"
              analyzer = root </> "content" </> "chapter" </> "topic" </> "extension" </> "outline.lua"
          previous <- ByteString.readFile publicIndex
          TextIO.writeFile analyzer "function post_analyzer(document, context) error('broken analyzer') end"
          failed <- buildHtml root False
          assertBool "expected analyzer failure" (either (const True) (const False) failed)
          ByteString.readFile publicIndex >>= (@?= previous)
    , testCase "invalidates an ancestor when an export-set member is added or removed" $
        withSystemTempDirectory "tex2ss-analysis-membership" $ \root -> do
          initializeAnalysisFixture root
          buildHtml root False >>= (@?= Right True)
          let appendix = root </> "content" </> "appendix"
              publicIndex = root </> "public" </> "index.html"
          writeAnalyzedBundle appendix "Appendix" "Appendix source"
          buildHtml root False >>= (@?= Right True)
          added <- TextIO.readFile publicIndex
          assertBool "new matching export did not reach ancestor" ("Appendix source filtered" `Text.isInfixOf` added)
          removeDirectoryRecursive appendix
          buildHtml root False >>= (@?= Right True)
          removed <- TextIO.readFile publicIndex
          assertBool "removed export remained in ancestor" (not $ "Appendix source filtered" `Text.isInfixOf` removed)
    , testCase "selects analyzer bundles only from strict slot descendants" $ do
        let rootBundle = analysisBundle (Slot []) (Just analyzerSpec)
            childBundle = analysisBundle (Slot ["chapter"]) (Just analyzerSpec)
            grandchildBundle = analysisBundle (Slot ["chapter", "topic"]) (Just analyzerSpec)
            siblingBundle = analysisBundle (Slot ["other"]) (Just analyzerSpec)
            candidates = [rootBundle, childBundle, grandchildBundle, siblingBundle]
        map bundleSlotForTest (matchingAnalyzerBundles rootBundle ["example.outline"] candidates)
          @?= [Slot ["chapter"], Slot ["chapter", "topic"], Slot ["other"]]
        map bundleSlotForTest (matchingAnalyzerBundles childBundle ["example.outline"] candidates)
          @?= [Slot ["chapter", "topic"]]
    , testCase "rejects non-serializable and oversized analyzer exports" $
        withSystemTempDirectory "tex2ss-analysis-contract" $ \root -> do
          let script = root </> "outline.lua"
              bundle = analysisBundle (Slot []) (Just analyzerSpec)
              document = Pandoc nullMeta []
          TextIO.writeFile script "function post_analyzer(document, context) return function() end end"
          nonSerializable <- runPostAnalyzer script analyzerSpec bundle document
          case nonSerializable of
            Left problems -> map diagnosticCode problems @?= ["analyzer.failed"]
            Right _ -> assertBool "expected non-serializable export failure" False
          TextIO.writeFile script "function post_analyzer(document, context) return string.rep('x', 1048577) end"
          oversized <- runPostAnalyzer script analyzerSpec bundle document
          case oversized of
            Left problems -> map diagnosticCode problems @?= ["analyzer.export-too-large"]
            Right _ -> assertBool "expected oversized export failure" False
    , testCase "never exposes current or sibling exports to a generator" $
        withSystemTempDirectory "tex2ss-analysis-direction" $ \root -> do
          let script = root </> "check.lua"
              base = analysisBundle (Slot ["chapter"]) Nothing
              metadata =
                (bundleMetadataForTest base)
                  { metadataGenerator = Just "check.lua"
                  , metadataAnalysisInputs = ["example.outline"]
                  }
              ancestor = replaceBundleMetadata base metadata
              exports =
                [ analysisExport (Slot ["chapter"]) "current"
                , analysisExport (Slot ["other"]) "sibling"
                , analysisExport (Slot ["chapter", "topic"]) "grandchild"
                ]
          TextIO.writeFile
            script
            ( Text.unlines
                [ "function pre_generator(context)"
                , "  assert(#context.analysis_exports == 1)"
                , "  assert(context.analysis_exports[1].document == 'chapter/topic')"
                , "  return { fragments = {} }"
                , "end"
                ]
            )
          result <- runPreGeneratorWith script (buildSiteIndex [ancestor]) exports ancestor
          assertBool "expected strict descendant-only context" (either (const False) (const True) result)
    ]

analyzerSpec :: AnalyzerSpec
analyzerSpec = AnalyzerSpec "outline.lua" "example.outline" 1

analysisBundle :: Slot -> Maybe AnalyzerSpec -> Bundle
analysisBundle slot analyzer =
  let directory = "content" </> Text.unpack (Text.replace "/" "-" $ renderTestSlot slot)
      metadata = BundleMetadata 1 "Test" Nothing Nothing Nothing Published Nothing [] mempty Nothing analyzer []
   in Bundle slot directory (directory </> "index.tex") (directory </> "meta.json") metadata

bundleSlotForTest :: Bundle -> Slot
bundleSlotForTest (Bundle slot _ _ _ _) = slot

bundleMetadataForTest :: Bundle -> BundleMetadata
bundleMetadataForTest (Bundle _ _ _ _ metadata) = metadata

replaceBundleMetadata :: Bundle -> BundleMetadata -> Bundle
replaceBundleMetadata (Bundle slot directory indexPath metaPath _) metadata =
  Bundle slot directory indexPath metaPath metadata

analysisExport :: Slot -> Text.Text -> AnalysisExport
analysisExport slot label =
  AnalysisExport
    "outline.lua"
    "example.outline"
    1
    slot
    (object ["heading" .= label])

renderTestSlot :: Slot -> Text.Text
renderTestSlot (Slot []) = "root"
renderTestSlot (Slot segments) = Text.intercalate "/" segments

initializeAnalysisFixture :: FilePath -> IO ()
initializeAnalysisFixture root = do
  initialized <- initializeProject root "Analysis fixture"
  assertBool "scaffold failed" (either (const False) (const True) initialized)
  let content = root </> "content"
      child = content </> "chapter"
      grandchild = child </> "topic"
      rootExtension = content </> "extension"
  createDirectoryIfMissing True rootExtension
  TextIO.writeFile
    (content </> "meta.json")
    ( Text.unlines
        [ "{"
        , "  \"schema_version\": 1,"
        , "  \"title\": \"Analysis tree\","
        , "  \"visibility\": \"published\","
        , "  \"generator\": \"tree.lua\","
        , "  \"analysis_inputs\": [\"example.outline\"]"
        , "}"
        ]
    )
  TextIO.writeFile
    (content </> "index.tex")
    ( latexDocument
        [ "\\section{Generated outline}"
        , "\\tex2ssgenerated{tree}"
        ]
    )
  TextIO.writeFile (rootExtension </> "tree.lua") treeGenerator
  writeAnalyzedBundle child "Child" "Child source"
  writeAnalyzedBundle grandchild "Grandchild" "Grandchild source"

writeAnalyzedBundle :: FilePath -> Text.Text -> Text.Text -> IO ()
writeAnalyzedBundle directory title heading = do
  let extension = directory </> "extension"
  createDirectoryIfMissing True extension
  TextIO.writeFile
    (directory </> "meta.json")
    ( Text.unlines
        [ "{"
        , "  \"schema_version\": 1,"
        , "  \"title\": \"" <> title <> "\","
        , "  \"visibility\": \"published\","
        , "  \"filters\": [\"mark.lua\"],"
        , "  \"post_analyzer\": {"
        , "    \"script\": \"outline.lua\","
        , "    \"namespace\": \"example.outline\","
        , "    \"schema_version\": 1"
        , "  }"
        , "}"
        ]
    )
  TextIO.writeFile (directory </> "index.tex") (latexDocument ["\\section{" <> heading <> "}"])
  TextIO.writeFile (extension </> "mark.lua") markFilter
  TextIO.writeFile (extension </> "outline.lua") outlineAnalyzer

latexDocument :: [Text.Text] -> Text.Text
latexDocument body =
  Text.unlines $
    [ "\\documentclass{article}"
    , "\\begin{document}"
    ]
      <> body
      <> ["\\end{document}"]

markFilter :: Text.Text
markFilter =
  Text.unlines
    [ "function Header(header)"
    , "  header.content:insert(pandoc.Space())"
    , "  header.content:insert(pandoc.Str('filtered'))"
    , "  return header"
    , "end"
    ]

outlineAnalyzer :: Text.Text
outlineAnalyzer =
  Text.unlines
    [ "function post_analyzer(document, context)"
    , "  assert(context.export.namespace == 'example.outline')"
    , "  assert(context.export.schema_version == 1)"
    , "  for _, block in ipairs(document.blocks) do"
    , "    if block.t == 'Header' then"
    , "      return { heading = pandoc.utils.stringify(block) }"
    , "    end"
    , "  end"
    , "  error('heading not found')"
    , "end"
    ]

treeGenerator :: Text.Text
treeGenerator =
  Text.unlines
    [ "function pre_generator(context)"
    , "  local headings = {}"
    , "  local extras = {}"
    , "  for _, export in ipairs(context.analysis_exports) do"
    , "    headings[export.document] = export.value.heading"
    , "    if export.document ~= 'chapter' and export.document ~= 'chapter/topic' then"
    , "      extras[#extras + 1] = pandoc.Plain({ pandoc.Str(export.value.heading) })"
    , "    end"
    , "  end"
    , "  local child = assert(headings['chapter'])"
    , "  local grandchild = assert(headings['chapter/topic'])"
    , "  local items = {"
    , "    { pandoc.Plain({ pandoc.Str(child) }),"
    , "      pandoc.BulletList({ { pandoc.Plain({ pandoc.Str(grandchild) }) } }) }"
    , "  }"
    , "  for _, extra in ipairs(extras) do items[#items + 1] = { extra } end"
    , "  local nested = pandoc.BulletList(items)"
    , "  return { fragments = { tree = { type = 'pandoc_blocks', blocks = pandoc.Blocks({ nested }) } } }"
    , "end"
    ]

fakeEnvironment :: LatexEnvironment
fakeEnvironment =
  LatexEnvironment
    { latexmkExecutable = "fake-latexmk"
    , latexmkVersion = "Latexmk 1.0"
    , latexEngine = PdfLaTeX
    , latexEngineExecutable = "fake-pdflatex"
    , latexEngineVersion = "pdfTeX 1.0"
    }
