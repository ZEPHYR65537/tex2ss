{-# LANGUAGE OverloadedStrings #-}

module IncludeSpec (tests) where

import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Include (ExpandedSource (..), expandBundleSource)

tests :: TestTree
tests =
  testGroup
    "includes"
    [ testCase "expands literal sources in one staged document" $
        withSystemTempDirectory "tex2ss-include" $ \bundle -> do
          let sources = bundle </> "sources"
              indexPath = bundle </> "index.tex"
          createDirectoryIfMissing True sources
          TextIO.writeFile indexPath "Before\\input{sources/part}After"
          TextIO.writeFile (sources </> "part.tex") " middle "
          result <- expandBundleSource bundle indexPath
          case result of
            Left _ -> assertBool "expected include success" False
            Right expanded -> assertBool "included content missing" ("Before middle After" `Text.isInfixOf` expandedText expanded)
    , testCase "rejects include cycles" $
        withSystemTempDirectory "tex2ss-include" $ \bundle -> do
          let sources = bundle </> "sources"
              indexPath = bundle </> "index.tex"
          createDirectoryIfMissing True sources
          TextIO.writeFile indexPath "\\input{sources/a}"
          TextIO.writeFile (sources </> "a.tex") "\\input{b}"
          TextIO.writeFile (sources </> "b.tex") "\\input{a}"
          result <- expandBundleSource bundle indexPath
          case result of
            Left problems -> assertBool "expected cycle code" ("include.cycle" `elem` map diagnosticCode problems)
            Right _ -> assertBool "expected include cycle failure" False
    ]
