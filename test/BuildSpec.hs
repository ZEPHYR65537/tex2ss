{-# LANGUAGE OverloadedStrings #-}

module BuildSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Build (buildHtml)
import Tex2ss.Scaffold (initializeProject)

tests :: TestTree
tests =
  testGroup
    "transactional build"
    [ testCase "does not rewrite an identical public snapshot" $
        withSystemTempDirectory "tex2ss-build" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          first <- buildHtml root False
          second <- buildHtml root False
          first @?= Right True
          second @?= Right False
    , testCase "preserves public when a later compile fails" $
        withSystemTempDirectory "tex2ss-build" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          first <- buildHtml root False
          first @?= Right True
          let publicIndex = root </> "public" </> "index.html"
              sourceIndex = root </> "content" </> "index.tex"
          previous <- ByteString.readFile publicIndex
          TextIO.writeFile sourceIndex unsupportedDocument
          failed <- buildHtml root False
          assertBool "expected compiler failure" (either (const True) (const False) failed)
          current <- ByteString.readFile publicIndex
          current @?= previous
    ]

unsupportedDocument :: Text
unsupportedDocument =
  "\\documentclass{article}\n\\begin{document}\n\\tex2ssUnknownCommand\n\\end{document}\n"
