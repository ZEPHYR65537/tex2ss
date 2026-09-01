{-# LANGUAGE OverloadedStrings #-}

module DiscoverySpec (tests) where

import Control.Exception (IOException, try)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing, createDirectoryLink)
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
    , testCase "reports a directory link that cycles back into an ancestor" $
        withSystemTempDirectory "tex2ss-discovery" $ \root -> do
          let content = root </> "content"
              loop = content </> "loop"
          createDirectoryIfMissing True content
          linked <- try (createDirectoryLink content loop) :: IO (Either IOException ())
          case linked of
            Left _ -> pure ()
            Right () -> do
              result <- discoverBundles (mkProjectPaths root)
              case result of
                Left problems ->
                  assertBool
                    "expected the directory-cycle diagnostic"
                    ("bundle.directory-cycle" `elem` map diagnosticCode problems)
                Right _ -> assertBool "expected discovery to reject the cycle" False
    ]

validMeta :: ByteString.ByteString
validMeta = "{\"schema_version\":1,\"title\":\"One\"}"
