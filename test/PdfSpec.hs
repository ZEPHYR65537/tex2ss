{-# LANGUAGE OverloadedStrings #-}

module PdfSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode, diagnosticMessage))
import Tex2ss.Pdf
  ( LatexEnvironment (LatexEnvironment)
  , LatexInvocation (..)
  , LatexRunResult (LatexRunResult)
  , buildPdfWith
  , inspectLatexEnvironmentWith
  , probeLatexEnvironmentWith
  )
import Tex2ss.Scaffold (initializeProject)

tests :: TestTree
tests =
  testGroup
    "PDF build"
    [ testCase "publishes atomically and skips unchanged TeX work" $
        withSystemTempDirectory "tex2ss-pdf" $ \root -> do
          initializeFixture root
          invocations <- newIORef (0 :: Int)
          let runner _ invocation = do
                modifyIORef' invocations (+ 1)
                createDirectoryIfMissing True (invocationOutputDirectory invocation)
                source <- ByteString.readFile (invocationSourcePath invocation)
                ByteString.writeFile (invocationExpectedPdf invocation) ("%PDF-fake\n" <> source)
                pure (LatexRunResult ExitSuccess "" "")
          first <- buildPdfWith fakeEnvironment runner root False
          second <- buildPdfWith fakeEnvironment runner root False
          first @?= Right True
          second @?= Right False
          readIORef invocations >>= (@?= 1)
          doesFileExist (root </> "pdfs" </> "index.pdf") >>= assertBool "published PDF missing"
          doesFileExist (root </> "pdfs" </> ".tex2ss-manifest.json") >>= assertBool "PDF manifest missing"
    , testCase "preserves the last PDF snapshot when latexmk fails" $
        withSystemTempDirectory "tex2ss-pdf" $ \root -> do
          initializeFixture root
          let success _ invocation = do
                createDirectoryIfMissing True (invocationOutputDirectory invocation)
                ByteString.writeFile (invocationExpectedPdf invocation) "%PDF-previous"
                pure (LatexRunResult ExitSuccess "" "")
              failure _ invocation = do
                createDirectoryIfMissing True (invocationOutputDirectory invocation)
                TextIO.writeFile
                  (invocationOutputDirectory invocation </> "document.log")
                  "document.tex:9: Undefined control sequence.\nl.9 \\badcommand\nFatal error occurred.\n"
                pure (LatexRunResult (ExitFailure 12) "latex output" "fatal error")
              output = root </> "pdfs" </> "index.pdf"
          buildPdfWith fakeEnvironment success root False >>= (@?= Right True)
          previous <- ByteString.readFile output
          TextIO.appendFile (root </> "content" </> "index.tex") "\nChanged.\n"
          failed <- buildPdfWith fakeEnvironment failure root False
          case failed of
            Left problems -> do
              assertBool "expected pdf.latexmk-failed" ("pdf.latexmk-failed" `elem` map diagnosticCode problems)
              assertBool
                "expected TeX log excerpt"
                (any ("Undefined control sequence" `Text.isInfixOf`) $ map diagnosticMessage problems)
            Right _ -> assertBool "expected PDF failure" False
          ByteString.readFile output >>= (@?= previous)
    , testCase "reports both missing LaTeX executables" $ do
        let neverRuns _ _ _ = error "version runner should not be called"
        result <- inspectLatexEnvironmentWith (const $ pure Nothing) neverRuns
        case result of
          Left problems ->
            map diagnosticCode problems @?= ["latex.latexmk-missing", "latex.pdflatex-missing"]
          Right _ -> assertBool "expected missing tool diagnostics" False
    , testCase "requires the doctor compile probe to produce a PDF" $ do
        let noOutput _ _ = pure (LatexRunResult ExitSuccess "" "")
        result <- probeLatexEnvironmentWith noOutput fakeEnvironment
        case result of
          Left problems -> map diagnosticCode problems @?= ["latex.probe-output-missing"]
          Right _ -> assertBool "expected missing probe output" False
    ]

initializeFixture :: FilePath -> IO ()
initializeFixture root = do
  initialized <- initializeProject root "PDF fixture"
  assertBool "scaffold failed" (either (const False) (const True) initialized)

fakeEnvironment :: LatexEnvironment
fakeEnvironment =
  LatexEnvironment
    "fake-latexmk"
    "Latexmk 1.0"
    "fake-pdflatex"
    "pdfTeX 1.0"
