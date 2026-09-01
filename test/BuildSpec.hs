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
import Tex2ss.Build (BuildPlan (planBundles), buildHtml, buildHtmlWith, prepareBuildPlanWith)
import Tex2ss.Scaffold (initializeProject)
import Tex2ss.Types (BuildSelector (..), Bundle (bundleSlot), Slot (..))

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
    , testCase "rebuilds citations when the shared bibliography changes" $
        withSystemTempDirectory "tex2ss-build-bibliography" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          TextIO.writeFile (root </> "content" </> "index.tex") citationDocument
          let bibliography = root </> "latex" </> "bibliography" </> "references.bib"
          TextIO.writeFile bibliography (bibliographyWithAuthor "Doe, Jane")
          buildHtml root False >>= (@?= Right True)
          first <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "first citation missing" ("Doe" `Text.isInfixOf` first)
          TextIO.writeFile bibliography (bibliographyWithAuthor "Roe, Jane")
          buildHtml root False >>= (@?= Right True)
          second <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "bibliography change did not invalidate page" ("Roe" `Text.isInfixOf` second)
    , testCase "selective slot and regex builds preserve unselected outputs" $
        withSystemTempDirectory "tex2ss-build-selective" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          createView root "alpha" "Alpha one."
          createView root "beta" "Beta one."
          buildHtml root False >>= (@?= Right True)
          betaBefore <- ByteString.readFile (root </> "public" </> "beta" </> "index.html")
          TextIO.writeFile (root </> "content" </> "alpha" </> "index.tex") (plainDocument "Alpha two.")
          buildHtmlWith root False [SelectSlot $ Slot ["alpha"]] False >>= (@?= Right True)
          alpha <- TextIO.readFile (root </> "public" </> "alpha" </> "index.html")
          assertBool "selected slot was not rebuilt" ("Alpha two." `Text.isInfixOf` alpha)
          ByteString.readFile (root </> "public" </> "beta" </> "index.html") >>= (@?= betaBefore)
          TextIO.writeFile (root </> "content" </> "beta" </> "index.tex") (plainDocument "Beta two.")
          buildHtmlWith root False [SelectRegex "^beta$"] False >>= (@?= Right True)
          beta <- TextIO.readFile (root </> "public" </> "beta" </> "index.html")
          assertBool "regex-selected slot was not rebuilt" ("Beta two." `Text.isInfixOf` beta)
    , testCase "rejects mixed all and empty selectors and keeps force content-stable" $
        withSystemTempDirectory "tex2ss-build-selectors" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          buildHtml root False >>= (@?= Right True)
          mixed <- buildHtmlWith root False [SelectAll, SelectSlot $ Slot []] False
          assertBool "expected mixed selector failure" (either (const True) (const False) mixed)
          empty <- buildHtmlWith root False [SelectRegex "^missing$"] False
          assertBool "expected empty selector failure" (either (const True) (const False) empty)
          buildHtmlWith root False [SelectAll] True >>= (@?= Right False)
    , testCase "selective plugin closure excludes unrelated owners" $
        withSystemTempDirectory "tex2ss-build-plugin-closure" $ \root -> do
          initialized <- initializeProject root "Test"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          createPluginOwner root "alpha" "alpha-tree"
          createView root ("alpha" </> "child") "Alpha child."
          createPluginOwner root "gamma" "gamma-tree"
          createView root ("gamma" </> "child") "Gamma child."
          result <- prepareBuildPlanWith root False [SelectSlot $ Slot ["alpha"]] False
          fmap (map bundleSlot . planBundles) result
            @?= Right [Slot ["alpha"], Slot ["alpha", "child"]]
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

createView :: FilePath -> FilePath -> Text -> IO ()
createView root slot body = do
  let directory = root </> "content" </> slot
  createDirectoryIfMissing True directory
  TextIO.writeFile (directory </> "index.tex") (plainDocument body)
  TextIO.writeFile
    (directory </> "meta.json")
    "{\"schema_version\":1,\"title\":\"View\",\"visibility\":\"published\"}"

createPluginOwner :: FilePath -> FilePath -> Text -> IO ()
createPluginOwner root slot pluginId = do
  createView root slot ("\\texssgenerated{" <> pluginId <> "}{value}")
  let pluginDirectory = root </> "plugins" </> Text.unpack pluginId
  createDirectoryIfMissing True pluginDirectory
  TextIO.writeFile
    (pluginDirectory </> "init.lua")
    ( Text.unlines
        [ "local tex2ss = require 'tex2ss'"
        , "return {"
        , "  analyze = function(_, _) return {} end,"
        , "  generate = function(_) return {value = tex2ss.latex('generated')} end"
        , "}"
        ]
    )

plainDocument :: Text -> Text
plainDocument body =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , body
    , "\\end{document}"
    ]

citationDocument :: Text
citationDocument =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\begin{document}"
    , "See \\cite{example}."
    , "\\bibliography{bibliography/references.bib}"
    , "\\end{document}"
    ]

bibliographyWithAuthor :: Text -> Text
bibliographyWithAuthor author =
  Text.unlines
    [ "@article{example,"
    , "  author = {" <> author <> "},"
    , "  title = {Example},"
    , "  journal = {Journal},"
    , "  year = {2026}"
    , "}"
    ]
