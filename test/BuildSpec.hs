{-# LANGUAGE OverloadedStrings #-}

module BuildSpec (tests) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing)
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
    , testCase "exposes the filtered document TOC to the Hakyll template" $
        withSystemTempDirectory "tex2ss-build-toc" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          TextIO.writeFile
            (root </> "site" </> "templates" </> "default.html")
            "<nav>$toc$</nav><main>$body$</main>"
          TextIO.writeFile
            (root </> "content" </> "index.tex")
            sectionDocument
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "TOC field is missing" ("Contents heading" `Text.isInfixOf` html)
          assertBool "TOC link is missing" ("#contents-heading" `Text.isInfixOf` html)
    , testCase "copies bundle media beside the HTML route used by includegraphics" $
        withSystemTempDirectory "tex2ss-build-media" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          let mediaDirectory = root </> "content" </> "media" </> "img"
              sourceMedia = mediaDirectory </> "figure.png"
              publishedMedia = root </> "public" </> "media" </> "img" </> "figure.png"
              bytes = "not-a-decoded-image-but-a-stable-resource"
          createDirectoryIfMissing True mediaDirectory
          ByteString.writeFile sourceMedia bytes
          TextIO.writeFile (root </> "content" </> "index.tex") imageDocument
          buildHtml root False >>= (@?= Right True)
          ByteString.readFile publishedMedia >>= (@?= bytes)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool
            "includegraphics did not keep the route-relative media URL"
            ("media/img/figure.png" `Text.isInfixOf` html)
    ]

unsupportedDocument :: Text
unsupportedDocument =
  "\\documentclass{article}\n\\begin{document}\n\\tex2ssUnknownCommand\n\\end{document}\n"

sectionDocument :: Text
sectionDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , "\\section{Contents heading}"
    , "Body."
    , "\\end{document}"
    ]

imageDocument :: Text
imageDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\usepackage{graphicx}"
    , "\\begin{document}"
    , "\\includegraphics{media/img/figure.png}"
    , "\\end{document}"
    ]
