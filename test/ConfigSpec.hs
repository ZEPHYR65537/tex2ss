{-# LANGUAGE OverloadedStrings #-}

module ConfigSpec (tests) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Config (loadBundleMetadata, loadSiteConfig)
import Tex2ss.Types
  ( BundleMetadata (metadataPdfName)
  , DeployTarget (DeployTarget)
  , PdfEngine (..)
  , PdfName (PdfName)
  , SiteConfig (configDeploy, configPdfEngine)
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
          fmap configPdfEngine result @?= Right PdfLaTeX
    , testCase "accepts each supported PDF engine" $
        withSystemTempDirectory "tex2ss-config" $ \root -> do
          let path = root </> "config.json"
          forM_
            [("pdflatex", PdfLaTeX), ("xelatex", XeLaTeX), ("lualatex", LuaLaTeX)]
            $ \(name, expected) -> do
              ByteString.writeFile path (configWithPdfEngine name)
              result <- loadSiteConfig path
              fmap configPdfEngine result @?= Right expected
    , testCase "rejects unsupported or non-string PDF engines" $
        withSystemTempDirectory "tex2ss-config" $ \root -> do
          let path = root </> "config.json"
          forM_ ["\"latex\"", "\"XeLaTeX\"", "{}", "[]", "null"] $ \value -> do
            ByteString.writeFile path (configWithRawPdfEngine value)
            result <- loadSiteConfig path
            assertBool ("expected invalid pdf_engine: " <> value) (either (const True) (const False) result)
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
    , testCase "rejects the superseded generator and analyzer fields" $
        withSystemTempDirectory "tex2ss-meta" $ \root -> do
          let path = root </> "meta.json"
          forM_
            [ "{\"schema_version\":1,\"title\":\"x\",\"generator\":\"tree.lua\"}"
            , "{\"schema_version\":1,\"title\":\"x\",\"analysis_inputs\":[\"example.outline\"]}"
            , "{\"schema_version\":1,\"title\":\"x\",\"post_analyzer\":{\"script\":\"outline.lua\"}}"
            ]
            $ \document -> do
            ByteString.writeFile path document
            result <- loadBundleMetadata path
            assertBool "expected superseded field rejection" (either (const True) (const False) result)
    , testCase "accepts named deploy targets" $
        withSystemTempDirectory "tex2ss-config" $ \root -> do
          let path = root </> "config.json"
          ByteString.writeFile
            path
            "{\"schema_version\":1,\"site\":{\"title\":\"Example\"},\"templates\":{\"default\":\"default.html\"},\"default_template\":\"default\",\"deploy\":{\"production\":{\"script\":\"deploy/production.lua\",\"data\":{\"project\":\"demo\"}}}}"
          result <- loadSiteConfig path
          fmap configDeploy result @?= Right (Map.singleton "production" $ DeployTarget "deploy/production.lua" (Map.singleton "project" "demo"))
    , testCase "rejects deploy scripts outside the deploy directory" $
        withSystemTempDirectory "tex2ss-config" $ \root -> do
          let path = root </> "config.json"
          forM_ ["production.lua", "deploy/../production.lua", "deploy\\production.lua"] $ \script -> do
            ByteString.writeFile
              path
              (ByteString.pack $ "{\"schema_version\":1,\"site\":{\"title\":\"Example\"},\"templates\":{\"default\":\"default.html\"},\"default_template\":\"default\",\"deploy\":{\"production\":{\"script\":\"" <> escapeJson script <> "\"}}}")
            result <- loadSiteConfig path
            assertBool ("expected invalid deploy path: " <> script) (either (const True) (const False) result)
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

configWithPdfEngine :: String -> ByteString.ByteString
configWithPdfEngine name = configWithRawPdfEngine ("\"" <> name <> "\"")

configWithRawPdfEngine :: String -> ByteString.ByteString
configWithRawPdfEngine value =
  ByteString.pack $
    "{\"schema_version\":1,\"site\":{\"title\":\"Example\"},\"templates\":{\"default\":\"default.html\"},\"default_template\":\"default\",\"filters\":[],\"pdf_engine\":"
      <> value
      <> "}"

escapeJson :: String -> String
escapeJson = concatMap $ \character -> if character == '\\' then "\\\\" else [character]
