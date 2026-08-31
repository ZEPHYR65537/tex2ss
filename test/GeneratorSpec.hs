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
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Generator
  ( GeneratorResult (GeneratorResult)
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
              assembleGeneratedSource sourcePath result "Before\n\\tex2ssgenerated{children}\nAfter"
                @?= Right "Before\nGenerated from Guide\nAfter"
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
