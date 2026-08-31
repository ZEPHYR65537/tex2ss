{-# LANGUAGE OverloadedStrings #-}

module GeneratorSpec (tests) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Text.Pandoc.Definition (Block (Para), Inline (Str))
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Generator
  ( AssembledSource (assembledPandocFragments, assembledText)
  , GeneratorResult (GeneratorResult)
  , assembleGeneratedSource
  , runPreGenerator
  )
import Tex2ss.SiteIndex (buildSiteIndex)
import Tex2ss.Types
  ( Bundle (Bundle)
  , BundleMetadata (BundleMetadata)
  , Slot (Slot)
  , Visibility (Published)
  )

tests :: TestTree
tests =
  testGroup
    "pre-generator experiment"
    [ testCase "exposes the complete SiteIndex and assembles a named fragment" $
        withSystemTempDirectory "tex2ss-generator" $ \root -> do
          let rootBundle = bundle root (Slot []) "Root" (Just "tree.lua")
              childBundle = bundle root (Slot ["guide"]) "Guide" Nothing
              scriptPath = root </> "content" </> "extension" </> "tree.lua"
              sourcePath = root </> "content" </> "index.tex"
          createDirectoryIfMissing True (root </> "content" </> "extension")
          TextIO.writeFile scriptPath generatorScript
          generated <- runPreGenerator scriptPath (buildSiteIndex [rootBundle, childBundle]) rootBundle
          case generated of
            Left _ -> assertBool "expected generator success" False
            Right result ->
              (assembledText <$> assembleGeneratedSource sourcePath result "Before\n\\tex2ssgenerated{children}\nAfter")
                @?= Right "Before\nGenerated from Guide\nAfter"
    , testCase "decodes pandoc.Blocks without a JSON or text round trip" $
        withSystemTempDirectory "tex2ss-generator" $ \root -> do
          let rootBundle = bundle root (Slot []) "Root" (Just "semantic.lua")
              scriptPath = root </> "content" </> "extension" </> "semantic.lua"
              sourcePath = root </> "content" </> "index.tex"
          createDirectoryIfMissing True (root </> "content" </> "extension")
          TextIO.writeFile scriptPath semanticGeneratorScript
          generated <- runPreGenerator scriptPath (buildSiteIndex [rootBundle]) rootBundle
          case generated of
            Left _ -> assertBool "expected Pandoc AST generator success" False
            Right result ->
              case assembleGeneratedSource sourcePath result "\\tex2ssgenerated{semantic}" of
                Left _ -> assertBool "expected Pandoc AST assembly success" False
                Right assembled ->
                  assembledPandocFragments assembled
                    @?= Map.singleton "semantic" [Para [Str "Generated semantic block"]]
    , testCase "rejects raw target content inside pandoc_blocks" $
        withSystemTempDirectory "tex2ss-generator" $ \root -> do
          let rootBundle = bundle root (Slot []) "Root" (Just "raw.lua")
              scriptPath = root </> "content" </> "extension" </> "raw.lua"
          createDirectoryIfMissing True (root </> "content" </> "extension")
          TextIO.writeFile scriptPath rawGeneratorScript
          result <- runPreGenerator scriptPath (buildSiteIndex [rootBundle]) rootBundle
          case result of
            Left problems -> map diagnosticCode problems @?= ["generator.pandoc-blocks-raw"]
            Right _ -> assertBool "expected raw generated AST rejection" False
    , testCase "rejects implicit target-string variants" $
        withSystemTempDirectory "tex2ss-generator" $ \root -> do
          let rootBundle = bundle root (Slot []) "Root" (Just "html.lua")
              scriptPath = root </> "content" </> "extension" </> "html.lua"
          createDirectoryIfMissing True (root </> "content" </> "extension")
          TextIO.writeFile scriptPath htmlGeneratorScript
          result <- runPreGenerator scriptPath (buildSiteIndex [rootBundle]) rootBundle
          case result of
            Left problems -> map diagnosticCode problems @?= ["generator.failed"]
            Right _ -> assertBool "expected implicit HTML fragment rejection" False
    , testCase "rejects unknown generator result fields" $
        withSystemTempDirectory "tex2ss-generator" $ \root -> do
          let rootBundle = bundle root (Slot []) "Root" (Just "unknown.lua")
              scriptPath = root </> "content" </> "extension" </> "unknown.lua"
          createDirectoryIfMissing True (root </> "content" </> "extension")
          TextIO.writeFile scriptPath unknownFieldGeneratorScript
          result <- runPreGenerator scriptPath (buildSiteIndex [rootBundle]) rootBundle
          case result of
            Left problems -> map diagnosticCode problems @?= ["generator.failed"]
            Right _ -> assertBool "expected unknown result field rejection" False
    , testCase "rejects a placeholder with no returned fragment" $
        case assembleGeneratedSource "index.tex" (GeneratorResult Map.empty) "\\tex2ssgenerated{missing}" of
          Left problems -> map diagnosticCode problems @?= ["generator.fragment-missing"]
          Right _ -> assertBool "expected missing fragment failure" False
    ]

bundle :: FilePath -> Slot -> Text.Text -> Maybe FilePath -> Bundle
bundle root slot title generator =
  let directory =
        case slot of
          Slot [] -> root </> "content"
          Slot segments -> foldl (</>) (root </> "content") (map Text.unpack segments)
      metadata = BundleMetadata 1 title Nothing Nothing Nothing Published generator [] Map.empty
   in Bundle slot directory (directory </> "index.tex") (directory </> "meta.json") metadata

generatorScript :: Text.Text
generatorScript =
  Text.unlines
    [ "function pre_generator(context)"
    , "  assert(context.document.slot == '.')"
    , "  assert(#context.site_index.pages == 2)"
    , "  local child_title = nil"
    , "  for _, page in ipairs(context.site_index.pages) do"
    , "    if page.slot == 'guide' then child_title = page.title end"
    , "  end"
    , "  assert(child_title ~= nil)"
    , "  return {"
    , "    fragments = {"
    , "      children = { type = 'deferred_latex', value = 'Generated from ' .. child_title }"
    , "    }"
    , "  }"
    , "end"
    ]

semanticGeneratorScript :: Text.Text
semanticGeneratorScript =
  Text.unlines
    [ "function pre_generator(context)"
    , "  return {"
    , "    fragments = {"
    , "      semantic = {"
    , "        type = 'pandoc_blocks',"
    , "        blocks = pandoc.Blocks({ pandoc.Para({ pandoc.Str('Generated semantic block') }) })"
    , "      }"
    , "    }"
    , "  }"
    , "end"
    ]

rawGeneratorScript :: Text.Text
rawGeneratorScript =
  Text.unlines
    [ "function pre_generator(context)"
    , "  return {"
    , "    fragments = {"
    , "      raw = {"
    , "        type = 'pandoc_blocks',"
    , "        blocks = pandoc.Blocks({ pandoc.RawBlock('html', '<aside>raw</aside>') })"
    , "      }"
    , "    }"
    , "  }"
    , "end"
    ]

htmlGeneratorScript :: Text.Text
htmlGeneratorScript =
  Text.unlines
    [ "function pre_generator(context)"
    , "  return { fragments = { bad = { type = 'html', value = '<b>target</b>' } } }"
    , "end"
    ]

unknownFieldGeneratorScript :: Text.Text
unknownFieldGeneratorScript =
  Text.unlines
    [ "function pre_generator(context)"
    , "  return { fragments = {}, extra = true }"
    , "end"
    ]
