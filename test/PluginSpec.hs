{-# LANGUAGE OverloadedStrings #-}

module PluginSpec (tests) where

import qualified Data.ByteString.Char8 as ByteString
import Data.Either (isLeft)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Build (BuildPlan (..), buildHtml, prepareBuildPlan)
import Tex2ss.Diagnostics (Diagnostic (diagnosticCode))
import Tex2ss.Pandoc (analyzePreparedBundle, prepareBundleSourceWith)
import Tex2ss.Plugin
  ( ContentPlugin (pluginEntryPath, pluginId, pluginSelectedSlots)
  , PluginAnalysis
  , PluginReference (PluginReference)
  , ownerPlugins
  , parsePluginReferences
  , runPluginGenerators
  )
import Tex2ss.Scaffold (initializeProject)
import Tex2ss.Types (Bundle (bundleSlot), Slot (..))

tests :: TestTree
tests =
  testGroup
    "LaTeX-declared content plugins"
    [ testCase "parses ordered two-argument block macros and comments" $ do
        parsePluginReferences
          "index.tex"
          ( Text.unlines
              [ "% \\texssgenerated{ignored}{value}"
              , "  \\texssgenerated{archive}{latest} % presentation position"
              , "\\texssgenerated{tree}{children}"
              ]
          )
          @?= Right [PluginReference "archive" "latest", PluginReference "tree" "children"]
    , testCase "uses a bundle-local plugin override and standard require" $
        withSystemTempDirectory "tex2ss-plugin-local" $ \root -> do
          initializeFixture root
          let local = root </> "content" </> "extension" </> "demo"
              site = root </> "plugins" </> "demo"
          createDirectoryIfMissing True local
          createDirectoryIfMissing True site
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{demo}{message}"])
          TextIO.writeFile (site </> "init.lua") pluginUsingHelper
          TextIO.writeFile (site </> "helper.lua") "return { message = 'Site implementation' }"
          TextIO.writeFile (local </> "helper.lua") "return { message = 'Local override' }"
          buildHtml root False >>= (@?= Right True)
          fallbackHtml <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "site plugin should be used when local init.lua is absent" ("Site implementation" `Text.isInfixOf` fallbackHtml)
          TextIO.writeFile (local </> "init.lua") pluginUsingHelper
          planResult <- prepareBuildPlan root False
          case planResult of
            Left _ -> assertBool "expected plugin plan" False
            Right plan -> do
              let plugins = ownerPlugins (planPluginPlan plan) (Slot [])
              assertBool "local init.lua was not selected" (any (Text.isInfixOf "extension" . Text.pack . pluginEntryPath) plugins)
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "local required module result missing" ("Local override" `Text.isInfixOf` html)
          assertBool "site fallback should be shadowed" (not $ "Site implementation" `Text.isInfixOf` html)
    , testCase "maps filtered strict-descendant AST and folds it into the owner" $
        withSystemTempDirectory "tex2ss-plugin-fold" $ \root -> do
          initializeFixture root
          createChild root "chapter" "Child body."
          let plugin = root </> "plugins" </> "outline"
          createDirectoryIfMissing True plugin
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{outline}{tree}"])
          TextIO.writeFile (plugin </> "init.lua") outlinePlugin
          planResult <- prepareBuildPlan root False
          case planResult of
            Left _ -> assertBool "expected plugin plan" False
            Right plan ->
              case ownerPlugins (planPluginPlan plan) (Slot []) of
                [selected] -> pluginSelectedSlots selected @?= [Slot ["chapter"]]
                _ -> assertBool "expected exactly one plugin" False
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "descendant analysis was not folded" ("chapter: Child body." `Text.isInfixOf` html)
    , testCase "keeps multiple plugins isolated while macro position orders fragments" $
        withSystemTempDirectory "tex2ss-plugin-order" $ \root -> do
          initializeFixture root
          writeSimplePlugin root "alpha" "Alpha fragment"
          writeSimplePlugin root "beta" "Beta fragment"
          TextIO.writeFile
            (root </> "content" </> "index.tex")
            (document ["\\texssgenerated{beta}{value}", "\\texssgenerated{alpha}{value}"])
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          let betaAt = Text.breakOn "Beta fragment" html
              alphaAt = Text.breakOn "Alpha fragment" html
          assertBool "both fragments must be present" (not (Text.null $ snd betaAt) && not (Text.null $ snd alphaAt))
          assertBool "macro position must order content" (Text.length (fst betaAt) < Text.length (fst alphaAt))
          planResult <- prepareBuildPlan root False
          fmap (\plan -> map pluginId $ ownerPlugins (planPluginPlan plan) (Slot [])) planResult
            @?= Right ["beta", "alpha"]
    , testCase "reuses one filtered AST across multiple analyzers" $
        withSystemTempDirectory "tex2ss-plugin-counts" $ \root -> do
          initializeFixture root
          createChild root "chapter" "Child body."
          let extension = root </> "content" </> "chapter" </> "extension"
          createDirectoryIfMissing True extension
          TextIO.writeFile (extension </> "count.lua") (countingFilter root)
          ByteString.writeFile
            (root </> "content" </> "chapter" </> "meta.json")
            "{\"schema_version\":1,\"title\":\"chapter\",\"visibility\":\"published\",\"filters\":[\"count.lua\"]}"
          writeInstrumentedPlugin root "alpha"
          writeInstrumentedPlugin root "beta"
          TextIO.writeFile
            (root </> "content" </> "index.tex")
            (document ["\\texssgenerated{alpha}{value}", "\\texssgenerated{beta}{value}"])
          buildHtml root False >>= (@?= Right True)
          traverse (readCount root) ["filter", "alpha-analyze", "alpha-generate", "beta-analyze", "beta-generate"]
            >>= (@?= replicate 5 1)
    , testCase "supports multiple named fragments and repeated insertion" $
        withSystemTempDirectory "tex2ss-plugin-fragments" $ \root -> do
          initializeFixture root
          let plugin = root </> "plugins" </> "many"
          createDirectoryIfMissing True plugin
          TextIO.writeFile
            (plugin </> "init.lua")
            ( Text.unlines
                [ "local tex2ss = require 'tex2ss'"
                , "return { generate = function(_) return {"
                , "  first = tex2ss.latex('Repeated fragment'),"
                , "  second = tex2ss.blocks(pandoc.Blocks({pandoc.Para('Second fragment')}))"
                , "} end }"
                ]
            )
          TextIO.writeFile
            (root </> "content" </> "index.tex")
            (document ["\\texssgenerated{many}{first}", "\\texssgenerated{many}{second}", "\\texssgenerated{many}{first}"])
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          Text.count "Repeated fragment" html @?= 2
          assertBool "second named fragment missing" ("Second fragment" `Text.isInfixOf` html)
    , testCase "fails when a declared fragment is missing" $
        withSystemTempDirectory "tex2ss-plugin-missing-fragment" $ \root -> do
          initializeFixture root
          writeSimplePlugin root "demo" "Available"
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{demo}{missing}"])
          isLeft <$> buildHtml root False >>= (@?= True)
    , testCase "rejects select results outside visible strict descendants" $
        withSystemTempDirectory "tex2ss-plugin-boundary" $ \root -> do
          initializeFixture root
          let plugin = root </> "plugins" </> "bad"
          createDirectoryIfMissing True plugin
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{bad}{value}"])
          TextIO.writeFile
            (plugin </> "init.lua")
            ( Text.unlines
                [ "local tex2ss = require 'tex2ss'"
                , "return {"
                , "  select = function(_) return {'.'} end,"
                , "  analyze = function(_) return {} end,"
                , "  generate = function(_) return { value = tex2ss.latex('bad') } end"
                , "}"
                ]
            )
          result <- prepareBuildPlan root False
          case result of
            Left problems -> map diagnosticCode problems @?= ["plugin.selection-outside-descendants"]
            Right _ -> assertBool "expected strict-descendant failure" False
    , testCase "rejects target-specific raw nodes from direct blocks" $
        withSystemTempDirectory "tex2ss-plugin-raw" $ \root -> do
          initializeFixture root
          let plugin = root </> "plugins" </> "raw"
          createDirectoryIfMissing True plugin
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{raw}{value}"])
          TextIO.writeFile
            (plugin </> "init.lua")
            ( Text.unlines
                [ "local tex2ss = require 'tex2ss'"
                , "return { generate = function(_)"
                , "  return { value = tex2ss.blocks(pandoc.Blocks({pandoc.RawBlock('html', '<b>bad</b>')})) }"
                , "end }"
                ]
            )
          planResult <- prepareBuildPlan root False
          result <-
            case planResult of
              Left problems -> pure (Left problems)
              Right plan ->
                case planBundles plan of
                  bundle : _ -> runPluginGenerators (planSiteIndex plan) (planPluginPlan plan) [] bundle
                  [] -> pure (Left [])
          case result of
            Left problems -> assertBool "expected raw block rejection" ("plugin.pandoc-blocks-raw" `elem` map diagnosticCode problems)
            Right _ -> assertBool "expected raw block rejection" False
    , testCase "rejects duplicate selection and select without analyze" $
        withSystemTempDirectory "tex2ss-plugin-hook-validation" $ \root -> do
          initializeFixture root
          createChild root "chapter" "Child."
          let plugin = root </> "plugins" </> "bad"
          createDirectoryIfMissing True plugin
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{bad}{value}"])
          TextIO.writeFile (plugin </> "init.lua") duplicateSelectionPlugin
          duplicate <- prepareBuildPlan root False
          case duplicate of
            Left problems -> map diagnosticCode problems @?= ["plugin.selection-duplicate"]
            Right _ -> assertBool "expected duplicate selection failure" False
          TextIO.writeFile (plugin </> "init.lua") selectWithoutAnalyzePlugin
          isLeft <$> prepareBuildPlan root False >>= (@?= True)
    , testCase "enforces JSON analysis values and the 1 MiB limit" $
        withSystemTempDirectory "tex2ss-plugin-analysis-limit" $ \root -> do
          initializeFixture root
          createChild root "chapter" "Child."
          let plugin = root </> "plugins" </> "limit"
          createDirectoryIfMissing True plugin
          TextIO.writeFile (root </> "content" </> "index.tex") (document ["\\texssgenerated{limit}{value}"])
          TextIO.writeFile (plugin </> "init.lua") oversizedAnalysisPlugin
          oversized <- analyzeChild root
          case oversized of
            Left problems -> map diagnosticCode problems @?= ["plugin.analysis-too-large"]
            Right _ -> assertBool "expected analysis size failure" False
          TextIO.writeFile (plugin </> "init.lua") nonJsonAnalysisPlugin
          isLeft <$> analyzeChild root >>= (@?= True)
    , testCase "ships a callable SiteIndex plugin example in each scaffold" $
        withSystemTempDirectory "tex2ss-plugin-scaffold-example" $ \root -> do
          initialized <- initializeProject root "Plugin example"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          createChild root "guide" "Guide body."
          TextIO.writeFile
            (root </> "content" </> "index.tex")
            (document ["\\texssgenerated{site-list}{list}"])
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "scaffold plugin did not generate a SiteIndex link" ("href=\"/guide/\"" `Text.isInfixOf` html)
    , testCase "ships semantic audio, video and link macros as a first-party filter" $
        withSystemTempDirectory "tex2ss-semantic-macros" $ \root -> do
          initialized <- initializeProject root "Semantic fixture"
          assertBool "scaffold failed" (either (const False) (const True) initialized)
          TextIO.writeFile
            (root </> "content" </> "index.tex")
            ( document
                [ "\\texssaudio{media/song.mp3}{Listen}"
                , "\\texssvideo{https://example.test/movie.mp4}{Watch}"
                , "See \\texsslink{/posts/}{the posts}."
                ]
            )
          buildHtml root False >>= (@?= Right True)
          html <- TextIO.readFile (root </> "public" </> "index.html")
          assertBool "audio semantic class missing" ("tex2ss-audio" `Text.isInfixOf` html)
          assertBool "video semantic class missing" ("tex2ss-video" `Text.isInfixOf` html)
          assertBool "semantic link missing" ("href=\"/posts/\"" `Text.isInfixOf` html)
    ]

initializeFixture :: FilePath -> IO ()
initializeFixture root = do
  initialized <- initializeProject root "Plugin fixture"
  assertBool "scaffold failed" (either (const False) (const True) initialized)
  ByteString.writeFile
    (root </> "config.json")
    "{\"schema_version\":1,\"site\":{\"title\":\"Plugin fixture\"},\"templates\":{\"default\":\"default.html\"},\"default_template\":\"default\",\"filters\":[],\"pdf_engine\":\"pdflatex\"}"

createChild :: FilePath -> FilePath -> Text.Text -> IO ()
createChild root slot body = do
  let directory = root </> "content" </> slot
  createDirectoryIfMissing True (directory </> "sources")
  TextIO.writeFile (directory </> "index.tex") (document [body])
  ByteString.writeFile
    (directory </> "meta.json")
    (ByteString.pack $ "{\"schema_version\":1,\"title\":\"" <> slot <> "\",\"visibility\":\"published\"}")

document :: [Text.Text] -> Text.Text
document body =
  Text.unlines $
    ["\\documentclass{article}", "\\begin{document}"]
      <> body
      <> ["\\end{document}"]

pluginUsingHelper :: Text.Text
pluginUsingHelper =
  Text.unlines
    [ "local tex2ss = require 'tex2ss'"
    , "local helper = require 'helper'"
    , "return { generate = function(_) return { message = tex2ss.latex(helper.message) } end }"
    ]

outlinePlugin :: Text.Text
outlinePlugin =
  Text.unlines
    [ "local tex2ss = require 'tex2ss'"
    , "return {"
    , "  analyze = function(document, _)"
    , "    return { text = pandoc.utils.stringify(document) }"
    , "  end,"
    , "  generate = function(ctx)"
    , "    local items = {}"
    , "    for _, item in ipairs(ctx.analysis) do"
    , "      table.insert(items, item.document .. ': ' .. item.value.text)"
    , "    end"
    , "    return { tree = tex2ss.latex(table.concat(items, '\\n\\n')) }"
    , "  end"
    , "}"
    ]

writeSimplePlugin :: FilePath -> Text.Text -> Text.Text -> IO ()
writeSimplePlugin root name value = do
  let directory = root </> "plugins" </> Text.unpack name
  createDirectoryIfMissing True directory
  TextIO.writeFile
    (directory </> "init.lua")
    ( Text.unlines
        [ "local tex2ss = require 'tex2ss'"
        , "return { generate = function(_) return { value = tex2ss.latex('" <> value <> "') } end }"
        ]
    )

writeInstrumentedPlugin :: FilePath -> Text.Text -> IO ()
writeInstrumentedPlugin root name = do
  let directory = root </> "plugins" </> Text.unpack name
      state = luaPath root <> "/.tex2ss/" <> name
  createDirectoryIfMissing True directory
  TextIO.writeFile
    (directory </> "init.lua")
    ( Text.unlines
        [ "local tex2ss = require 'tex2ss'"
        , "local function tick(kind)"
        , "  local file = assert(io.open('" <> state <> "-' .. kind .. '.count', 'a'))"
        , "  file:write('x\\n'); file:close()"
        , "end"
        , "return {"
        , "  analyze = function(_, _) tick('analyze'); return {} end,"
        , "  generate = function(_) tick('generate'); return {value = tex2ss.latex('" <> name <> "')} end"
        , "}"
        ]
    )

countingFilter :: FilePath -> Text.Text
countingFilter root =
  Text.unlines
    [ "local file = assert(io.open('" <> luaPath root <> "/.tex2ss/filter.count', 'a'))"
    , "file:write('x\\n'); file:close()"
    , "return {}"
    ]

readCount :: FilePath -> Text.Text -> IO Int
readCount root name = length . Text.lines <$> TextIO.readFile (root </> ".tex2ss" </> Text.unpack name <> ".count")

luaPath :: FilePath -> Text.Text
luaPath = Text.replace "\\" "/" . Text.pack

duplicateSelectionPlugin :: Text.Text
duplicateSelectionPlugin =
  "local t=require 'tex2ss'; return {select=function(_) return {'chapter','chapter'} end, analyze=function(_,_) return {} end, generate=function(_) return {value=t.latex('x')} end}"

selectWithoutAnalyzePlugin :: Text.Text
selectWithoutAnalyzePlugin =
  "local t=require 'tex2ss'; return {select=function(_) return {'chapter'} end, generate=function(_) return {value=t.latex('x')} end}"

oversizedAnalysisPlugin :: Text.Text
oversizedAnalysisPlugin =
  "local t=require 'tex2ss'; return {analyze=function(_,_) return string.rep('x', 1024*1024) end, generate=function(_) return {value=t.latex('x')} end}"

nonJsonAnalysisPlugin :: Text.Text
nonJsonAnalysisPlugin =
  "local t=require 'tex2ss'; return {analyze=function(_,_) return function() end end, generate=function(_) return {value=t.latex('x')} end}"

analyzeChild :: FilePath -> IO (Either [Diagnostic] [PluginAnalysis])
analyzeChild root = do
  planned <- prepareBuildPlan root False
  case planned of
    Left problems -> pure (Left problems)
    Right plan ->
      case [bundle | bundle <- planBundles plan, bundleSlot bundle == Slot ["chapter"]] of
        child : _ -> do
          prepared <-
            prepareBundleSourceWith
              (planPaths plan)
              (planSiteIndex plan)
              (planPluginPlan plan)
              []
              child
          case prepared of
            Left problems -> pure (Left problems)
            Right source ->
              analyzePreparedBundle
                (planPaths plan)
                (planConfig plan)
                (planSiteIndex plan)
                (planPluginPlan plan)
                child
                source
        [] -> pure (Left [])
