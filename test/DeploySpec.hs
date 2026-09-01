{-# LANGUAGE OverloadedStrings #-}

module DeploySpec (tests) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, assertFailure, testCase)
import Tex2ss.Deploy (DeployCommand (..), DeployPlan (..), deployProject, loadDeployPlan)
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Paths (mkProjectPaths)
import Tex2ss.Scaffold (initializeProject)
import Tex2ss.Types (DeployTarget (DeployTarget))

tests :: TestTree
tests =
  testGroup
    "deployment"
    [ testCase "builds and loads a structured Lua deployment dry-run" $
        withSystemTempDirectory "tex2ss-deploy" $ \root -> do
          initializeDeployFixture root validDeployScript
          deployProject root "production" True >>= (@?= Right ())
    , testCase "records a deployment lifecycle with immutable input hashes" $
        withSystemTempDirectory "tex2ss-deploy-record" $ \root -> do
          initializeDeployFixture root validDeployScript
          deployProject root "production" True >>= (@?= Right ())
          let records = root </> ".tex2ss" </> "deployments"
          entries <- listDirectory records
          case entries of
            [entry] -> do
              bytes <- ByteString.readFile (records </> entry)
              assertBool "expected completed dry-run status" ("\"status\":\"dry-run\"" `ByteString.isInfixOf` bytes)
              assertBool "expected start timestamp" ("\"started_at\":" `ByteString.isInfixOf` bytes)
              assertBool "expected finish timestamp" ("\"finished_at\":" `ByteString.isInfixOf` bytes)
              assertBool "expected script hash" ("\"script_sha256\":" `ByteString.isInfixOf` bytes)
              assertBool "expected build manifest hash" ("\"build_manifest_sha256\":" `ByteString.isInfixOf` bytes)
            _ -> assertFailure "expected exactly one deployment record"
    , testCase "rejects a deployment cwd outside the public snapshot" $
        withSystemTempDirectory "tex2ss-deploy" $ \root -> do
          initializeDeployFixture root invalidCwdScript
          _ <- deployProject root "production" True
          let script = root </> "deploy" </> "production.lua"
              target = DeployTarget "deploy/production.lua" Map.empty
          result <- loadDeployPlan (mkProjectPaths root) "production" target script
          case result of
            Left problems -> map diagnosticCode problems @?= ["deploy.command-cwd-invalid"]
            Right _ -> assertBool "expected cwd validation failure" False
    , testCase "decodes executable, argv and public cwd without a shell string" $
        withSystemTempDirectory "tex2ss-deploy" $ \root -> do
          initializeDeployFixture root validDeployScript
          _ <- deployProject root "production" True
          result <-
            loadDeployPlan
              (mkProjectPaths root)
              "production"
              (DeployTarget "deploy/production.lua" Map.empty)
              (root </> "deploy" </> "production.lua")
          result
            @?= Right
              (DeployPlan [DeployCommand "example-publisher" ["upload", "."] "public"])
    ]

initializeDeployFixture :: FilePath -> Text.Text -> IO ()
initializeDeployFixture root script = do
  initialized <- initializeProject root "Deploy fixture"
  assertBool "scaffold failed" (either (const False) (const True) initialized)
  createDirectoryIfMissing True (root </> "deploy")
  ByteString.writeFile
    (root </> "config.json")
    "{\"schema_version\":1,\"site\":{\"title\":\"Deploy fixture\"},\"templates\":{\"default\":\"default.html\"},\"default_template\":\"default\",\"filters\":[],\"deploy\":{\"production\":{\"script\":\"deploy/production.lua\",\"data\":{}}}}"
  TextIO.writeFile (root </> "deploy" </> "production.lua") script

validDeployScript :: Text.Text
validDeployScript =
  Text.unlines
    [ "return function(ctx)"
    , "  assert(ctx.manifest.schema_version == 1)"
    , "  return { commands = { { executable = 'example-publisher', arguments = {'upload', '.'}, cwd = 'public' } } }"
    , "end"
    ]

invalidCwdScript :: Text.Text
invalidCwdScript =
  "return function(_) return { commands = { { executable = 'bad', arguments = {}, cwd = '..' } } } end"
