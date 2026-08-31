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
import Tex2ss.Diagnostics (Diagnostic (..))
import Tex2ss.Pandoc (renderBundleHtml)
import Tex2ss.Paths (mkProjectPaths)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (..)
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
          result <- renderBundleHtml (mkProjectPaths root) config bundle
          case result of
            Left _ -> assertBool "expected Pandoc success" False
            Right html -> assertBool "Lua filter result missing" ("Filtered by Lua" `Text.isInfixOf` html)
    , testCase "turns Lua syntax exceptions into stable diagnostics" $
        withSystemTempDirectory "tex2ss-pandoc" $ \root -> do
          (config, bundle, filterPath) <- fixture root
          TextIO.writeFile filterPath "function Para(element) this is invalid end"
          result <- renderBundleHtml (mkProjectPaths root) config bundle
          case result of
            Left problems -> do
              assertBool "expected pandoc.failed" ("pandoc.failed" `elem` map diagnosticCode problems)
              assertBool "expected Lua detail" (any (Text.isInfixOf "syntax" . diagnosticMessage) problems)
            Right _ -> assertBool "expected Lua filter failure" False
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
      metadata = BundleMetadata 1 "Page" Nothing Nothing Nothing Published [] Map.empty
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
