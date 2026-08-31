{-# LANGUAGE OverloadedStrings #-}

module DiscoverySpec (tests) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Discovery (discoverBundles)
import Tex2ss.Paths (mkProjectPaths)
import Tex2ss.Types (Bundle (bundleSlot), Slot (..))

tests :: TestTree
tests =
  testGroup
    "discovery"
    [ testCase "requires both bundle markers" $
        withSystemTempDirectory "tex2ss-discovery" $ \root -> do
          let content = root </> "content" </> "broken"
          createDirectoryIfMissing True content
          TextIO.writeFile (content </> "index.tex") "body"
          result <- discoverBundles (mkProjectPaths root)
          case result of
            Left problems -> map diagnosticCode problems @?= ["bundle.meta-missing"]
            Right _ -> assertBool "expected a partial-bundle diagnostic" False
    , testCase "finds nested slots and skips reserved subtrees" $
        withSystemTempDirectory "tex2ss-discovery" $ \root -> do
          let bundle = root </> "content" </> "posts" </> "one"
              reserved = bundle </> "sources"
          createDirectoryIfMissing True reserved
          TextIO.writeFile (bundle </> "index.tex") "body"
          ByteString.writeFile (bundle </> "meta.json") validMeta
          TextIO.writeFile (reserved </> "index.tex") "support file, not a bundle"
          result <- discoverBundles (mkProjectPaths root)
          case result of
            Left _ -> assertBool "expected discovery success" False
            Right bundles -> map bundleSlot bundles @?= [Slot ["posts", "one"]]
    ]

validMeta :: ByteString.ByteString
validMeta = "{\"schema_version\":1,\"title\":\"One\"}"
