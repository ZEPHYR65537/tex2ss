{-# LANGUAGE OverloadedStrings #-}

module ConfigSpec (tests) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as ByteString
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Config (loadBundleMetadata, loadSiteConfig)
import Tex2ss.Types
  ( BundleMetadata (metadataGenerator, metadataPdfName)
  , PdfName (PdfName)
  )

tests :: TestTree
tests =
  testGroup
    "config"
    [ testCase "accepts schema v1" $
        withSystemTempDirectory "tex2ss-config" $ \root -> do
          let path = root </> "config.json"
          ByteString.writeFile path validConfig
          result <- loadSiteConfig path
          assertBool "expected valid config" (either (const False) (const True) result)
    , testCase "rejects unknown top-level keys" $
        withSystemTempDirectory "tex2ss-config" $ \root -> do
          let path = root </> "config.json"
          ByteString.writeFile path $ ByteString.init validConfig <> ",\"surprise\":true}"
          result <- loadSiteConfig path
          assertBool "expected strict schema failure" (either (const True) (const False) result)
    , testCase "requires YYYY-MM-DD dates" $
        withSystemTempDirectory "tex2ss-meta" $ \root -> do
          let path = root </> "meta.json"
          ByteString.writeFile path "{\"schema_version\":1,\"title\":\"x\",\"date\":\"31/08/2026\"}"
          result <- loadBundleMetadata path
          assertBool "expected invalid date" (either (const True) (const False) result)
    , testCase "accepts a bundle-local Lua generator" $
        withSystemTempDirectory "tex2ss-meta" $ \root -> do
          let path = root </> "meta.json"
          ByteString.writeFile path "{\"schema_version\":1,\"title\":\"x\",\"generator\":\"tree.lua\"}"
          result <- loadBundleMetadata path
          fmap metadataGenerator result @?= Right (Just "tree.lua")
    , testCase "accepts a portable PDF filename stem" $
        withSystemTempDirectory "tex2ss-meta" $ \root -> do
          let path = root </> "meta.json"
          ByteString.writeFile path "{\"schema_version\":1,\"title\":\"x\",\"pdf_name\":\"site-book\"}"
          result <- loadBundleMetadata path
          fmap metadataPdfName result @?= Right (Just $ PdfName "site-book")
    , testCase "rejects paths and extensions in pdf_name" $
        withSystemTempDirectory "tex2ss-meta" $ \root -> do
          let path = root </> "meta.json"
          forM_ ["", "Manual", "manual.pdf", "../manual", "guide/manual"] $ \name -> do
            ByteString.writeFile
              path
              (ByteString.pack $ "{\"schema_version\":1,\"title\":\"x\",\"pdf_name\":\"" <> name <> "\"}")
            result <- loadBundleMetadata path
            assertBool ("expected invalid pdf_name: " <> name) (either (const True) (const False) result)
    ]

validConfig :: ByteString.ByteString
validConfig =
  "{\"schema_version\":1,\"site\":{\"title\":\"Example\"},\"templates\":{\"default\":\"default.html\"},\"default_template\":\"default\",\"filters\":[]}"
