{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Scaffold
  ( initializeGitRepository
  , initializeProject
  , initializeSite
  , initializeView
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (hasDrive, takeDirectory, takeFileName, (</>))
import System.Process (readProcessWithExitCode)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Types (ProjectPaths (..), Slot (..), renderSlot)

initializeSite :: FilePath -> FilePath -> IO (Either [Diagnostic] FilePath)
initializeSite parent name
  | not (validSiteName name) =
      pure $ Left [diagnosticAt Error "scaffold.site-name-invalid" name "site name must be a single non-special directory name"]
  | otherwise = do
      let target = parent </> name
      existing <- doesDirectoryExist target
      nonEmpty <- if existing then not . null <$> listDirectory target else pure False
      if nonEmpty
        then pure $ Left [diagnosticAt Error "scaffold.target-not-empty" target "target directory is not empty"]
        else do
          initialized <- initializeProject target (Text.pack name)
          case initialized of
            Left problems -> pure (Left problems)
            Right () -> do
              gitResult <- initializeGitRepository target
              pure $ target <$ gitResult

initializeGitRepository :: FilePath -> IO (Either [Diagnostic] ())
initializeGitRepository root = do
  gitDirectory <- doesDirectoryExist (root </> ".git")
  gitFile <- doesFileExist (root </> ".git")
  if gitDirectory || gitFile
    then pure (Right ())
    else do
      gitResult <- try @IOException $ readProcessWithExitCode "git" ["init", "-b", "main", root] ""
      pure $
        case gitResult of
          Left exception -> Left [diagnosticAt Error "scaffold.git-failed" root (Text.pack $ show exception)]
          Right (ExitSuccess, _, _) -> Right ()
          Right (_, _, stderrText) -> Left [diagnosticAt Error "scaffold.git-failed" root (Text.pack stderrText)]

initializeProject :: FilePath -> Text -> IO (Either [Diagnostic] ())
initializeProject root title = do
  let paths = scaffoldFiles root title
  collisions <- filterMPathExists (map fst paths)
  if not (null collisions)
    then
      pure . Left $
        [ diagnosticAt Error "scaffold.would-overwrite" path "refusing to overwrite an existing scaffold file"
        | path <- collisions
        ]
    else do
      result <- try @IOException $ do
        forM_ scaffoldDirectories $ \relative -> createDirectoryIfMissing True (root </> relative)
        forM_ paths $ \(path, contents) -> do
          createDirectoryIfMissing True (takeDirectory path)
          contents path
      pure $
        case result of
          Left exception -> Left [diagnosticAt Error "scaffold.write-failed" root (Text.pack $ show exception)]
          Right () -> Right ()

initializeView :: ProjectPaths -> Slot -> IO (Either [Diagnostic] FilePath)
initializeView paths slot = do
  let directory = foldl (</>) (projectContent paths) (map Text.unpack $ slotSegments slot)
      indexPath = directory </> "index.tex"
      metaPath = directory </> "meta.json"
  collisions <- filterMPathExists [indexPath, metaPath]
  if not (null collisions)
    then
      pure . Left $
        [ diagnosticAt Error "scaffold.view-exists" path "bundle marker already exists; refusing to overwrite it"
        | path <- collisions
        ]
    else do
      result <- try @IOException $ do
        forM_
          [ directory
          , directory </> "sources"
          , directory </> "media" </> "img"
          , directory </> "media" </> "video"
          , directory </> "extension"
          ]
          (createDirectoryIfMissing True)
        TextIO.writeFile indexPath (viewLatex $ renderSlot slot)
        LazyByteString.writeFile metaPath (viewMetadata $ renderSlot slot)
      pure $
        case result of
          Left exception -> Left [diagnosticAt Error "scaffold.write-failed" directory (Text.pack $ show exception)]
          Right () -> Right directory

scaffoldFiles :: FilePath -> Text -> [(FilePath, FilePath -> IO ())]
scaffoldFiles root title =
  [ (root </> "config.json", \path -> LazyByteString.writeFile path $ siteConfig title)
  , (root </> "content" </> "index.tex", \path -> TextIO.writeFile path $ viewLatex "Home")
  , (root </> "content" </> "meta.json", \path -> LazyByteString.writeFile path $ viewMetadata "Home")
  , (root </> "latex" </> "tex2ss.sty", \path -> TextIO.writeFile path tex2ssStyle)
  , (root </> "pandoc" </> "filters" </> "tex2ss-semantic.lua", \path -> TextIO.writeFile path semanticFilter)
  , (root </> "site" </> "templates" </> "default.html", \path -> TextIO.writeFile path defaultTemplate)
  , (root </> "site" </> "assets" </> "style.css", \path -> TextIO.writeFile path defaultCss)
  , (root </> "site" </> "assets" </> "tex2ss-media.js", \path -> TextIO.writeFile path mediaJavascript)
  , (root </> "plugins" </> "site-list" </> "init.lua", \path -> TextIO.writeFile path siteListPlugin)
  , (root </> "deploy" </> "cloudflare-pages.lua", \path -> TextIO.writeFile path cloudflareDeploy)
  , (root </> "deploy" </> "github-pages.lua", \path -> TextIO.writeFile path githubPagesDeploy)
  , (root </> ".gitignore", \path -> TextIO.writeFile path scaffoldGitignore)
  ]

scaffoldDirectories :: [FilePath]
scaffoldDirectories =
  [ "content"
  , "pandoc" </> "filters"
  , "latex" </> "bibliography"
  , "plugins"
  , "deploy"
  , "site" </> "templates"
  , "site" </> "assets"
  , "public"
  , "pdfs"
  ]

siteConfig :: Text -> LazyByteString.ByteString
siteConfig title =
  encode $
    object
      [ "schema_version" .= (1 :: Int)
      , "site"
          .= object
            [ "title" .= title
            , "description" .= ("" :: Text)
            , "base_url" .= ("" :: Text)
            , "lang" .= ("en" :: Text)
            , "author" .= ("" :: Text)
            ]
      , "templates" .= object ["default" .= ("default.html" :: Text)]
      , "default_template" .= ("default" :: Text)
      , "filters" .= (["filters/tex2ss-semantic.lua"] :: [Text])
      , "pdf_engine" .= ("pdflatex" :: Text)
      , "deploy" .= object []
      ]

viewMetadata :: Text -> LazyByteString.ByteString
viewMetadata title =
  encode $
    object
      [ "schema_version" .= (1 :: Int)
      , "title" .= title
      , "visibility" .= ("published" :: Text)
      , "data" .= object []
      ]

viewLatex :: Text -> Text
viewLatex title =
  Text.unlines
    [ "\\documentclass{article}"
    , "\\usepackage{tex2ss}"
    , "\\title{" <> escapeLaTeX title <> "}"
    , "\\begin{document}"
    , "\\maketitle"
    , ""
    , "Write this page in LaTeX."
    , ""
    , "\\end{document}"
    ]

defaultTemplate :: Text
defaultTemplate =
  Text.unlines
    [ "<!doctype html>"
    , "<html lang=\"$lang$\">"
    , "<head>"
    , "  <meta charset=\"utf-8\">"
    , "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "  <title>$title$ · $site_title$</title>"
    , "  <link rel=\"stylesheet\" href=\"/assets/style.css\">"
    , "  <script defer src=\"/assets/tex2ss-media.js\"></script>"
    , "</head>"
    , "<body>"
    , "  <main>"
    , "    <h1>$title$</h1>"
    , "$body$"
    , "  </main>"
    , "</body>"
    , "</html>"
    ]

defaultCss :: Text
defaultCss =
  Text.unlines
    [ ":root { color-scheme: light dark; font-family: system-ui, sans-serif; }"
    , "body { margin: 0; }"
    , "main { max-width: 72ch; margin: 0 auto; padding: 3rem 1.25rem; line-height: 1.65; }"
    , "img, video { max-width: 100%; height: auto; }"
    , ".tex2ss-media { margin: 1rem 0; }"
    , ".tex2ss-media audio, .tex2ss-media video { display: block; max-width: 100%; width: 100%; }"
    , ".tex2ss-equation { align-items: center; display: flex; gap: 1rem; justify-content: center; }"
    , ".tex2ss-equation-number { margin-left: auto; }"
    , "pre { overflow-x: auto; }"
    ]

tex2ssStyle :: Text
tex2ssStyle =
  Text.unlines
    [ "\\NeedsTeXFormat{LaTeX2e}"
    , "\\ProvidesPackage{tex2ss}[2026/09/01 tex2ss semantic authoring macros]"
    , "\\RequirePackage{amsmath}"
    , "\\RequirePackage{hyperref}"
    , "\\providecommand{\\texssgenerated}[2]{}"
    , "\\newcommand{\\texssaudio}[2]{\\href{#1}{#2 (audio: \\texttt{#1})}}"
    , "\\newcommand{\\texssvideo}[2]{\\href{#1}{#2 (video: \\texttt{#1})}}"
    , "\\newcommand{\\texsslink}[2]{\\href{#1}{#2}}"
    ]

semanticFilter :: Text
semanticFilter =
  Text.unlines
    [ "local function parse(raw, name)"
    , "  local pattern = '^\\\\' .. name .. '{([^{}]*)}{([^{}]*)}$'"
    , "  return raw:match(pattern)"
    , "end"
    , ""
    , "local function media(kind, source, label, block)"
    , "  local attr = pandoc.Attr('', {'tex2ss-media', 'tex2ss-' .. kind}, {{'data-source', source}})"
    , "  local fallback = pandoc.Link({pandoc.Str(label)}, source)"
    , "  if block then"
    , "    return pandoc.Div({pandoc.Para({fallback})}, attr)"
    , "  end"
    , "  return pandoc.Span({fallback}, attr)"
    , "end"
    , ""
    , "local references = {}"
    , "local figure_number = 0"
    , "local equation_number = 0"
    , ""
    , "local function index_document(document)"
    , "  return document:walk {"
    , "    Header = function(el)"
    , "      if el.identifier ~= '' then references[el.identifier] = pandoc.utils.stringify(el.content) end"
    , "      return el"
    , "    end,"
    , "    Figure = function(el)"
    , "      if el.identifier ~= '' then"
    , "        figure_number = figure_number + 1"
    , "        references[el.identifier] = tostring(figure_number)"
    , "        el.attributes['data-number'] = tostring(figure_number)"
    , "        el.classes:insert('tex2ss-numbered-figure')"
    , "      end"
    , "      return el"
    , "    end,"
    , "    Math = function(el)"
    , "      if el.mathtype ~= 'DisplayMath' then return nil end"
    , "      local label = el.text:match('\\\\label%s*{([^{}]+)}')"
    , "      if not label then return nil end"
    , "      equation_number = equation_number + 1"
    , "      local number = tostring(equation_number)"
    , "      references[label] = number"
    , "      el.text = el.text:gsub('\\\\label%s*{[^{}]+}', '', 1)"
    , "      el.text = el.text:gsub('^%s*\\\\begin%s*{equation%*}%s*', ''):gsub('^%s*\\\\begin%s*{equation}%s*', '')"
    , "      el.text = el.text:gsub('%s*\\\\end%s*{equation%*}%s*$', ''):gsub('%s*\\\\end%s*{equation}%s*$', '')"
    , "      local attr = pandoc.Attr(label, {'tex2ss-equation'}, {{'data-number', number}})"
    , "      return pandoc.Span({el, pandoc.Span({pandoc.Str('(' .. number .. ')')}, pandoc.Attr('', {'tex2ss-equation-number'}))}, attr)"
    , "    end"
    , "  }"
    , "end"
    , ""
    , "local function citation_fallback(el)"
    , "  local ids = {}"
    , "  for _, citation in ipairs(el.citations) do ids[#ids + 1] = citation.id end"
    , "  el.content = pandoc.Inlines({pandoc.Str('[' .. table.concat(ids, '; ') .. ']')})"
    , "  return el"
    , "end"
    , ""
    , "return {"
    , "  { Pandoc = index_document },"
    , "  {"
    , "    RawBlock = function(el)"
    , "      if el.format == 'latex' and el.text:match('^\\\\centering%s*$') then return {} end"
    , "      if el.format == 'latex' and el.text:match('^\\\\bibliographystyle%s*{[^{}]+}%s*$') then return {} end"
    , "      local source, label = parse(el.text, 'texssaudio')"
    , "      if source then return media('audio', source, label, true) end"
    , "      source, label = parse(el.text, 'texssvideo')"
    , "      if source then return media('video', source, label, true) end"
    , "      return nil"
    , "    end,"
    , "    Para = function(el)"
    , "      if #el.content ~= 1 or el.content[1].tag ~= 'RawInline' then return nil end"
    , "      local raw = el.content[1].text"
    , "      local source, label = parse(raw, 'texssaudio')"
    , "      if source then return media('audio', source, label, true) end"
    , "      source, label = parse(raw, 'texssvideo')"
    , "      if source then return media('video', source, label, true) end"
    , "      return nil"
    , "    end"
    , "  },"
    , "  {"
    , "    Cite = citation_fallback,"
    , "    RawInline = function(el)"
    , "      local target, label = parse(el.text, 'texsslink')"
    , "      if target then return pandoc.Link({pandoc.Str(label)}, target) end"
    , "      local reference = el.text:match('^\\\\ref%s*{([^{}]+)}$')"
    , "      if reference then"
    , "        return pandoc.Link({pandoc.Str(references[reference] or reference)}, '#' .. reference, '', pandoc.Attr('', {'tex2ss-reference'}))"
    , "      end"
    , "      reference = el.text:match('^\\\\eqref%s*{([^{}]+)}$')"
    , "      if reference then"
    , "        return pandoc.Link({pandoc.Str('(' .. (references[reference] or reference) .. ')')}, '#' .. reference, '', pandoc.Attr('', {'tex2ss-reference'}))"
    , "      end"
    , "      local source"
    , "      source, label = parse(el.text, 'texssaudio')"
    , "      if source then return media('audio', source, label, false) end"
    , "      source, label = parse(el.text, 'texssvideo')"
    , "      if source then return media('video', source, label, false) end"
    , "      return nil"
    , "    end"
    , "  }"
    , "}"
    ]

mediaJavascript :: Text
mediaJavascript =
  Text.unlines
    [ "document.addEventListener('DOMContentLoaded', () => {"
    , "  document.querySelectorAll('.tex2ss-audio, .tex2ss-video').forEach((container) => {"
    , "    const source = container.dataset.source;"
    , "    if (!source || container.querySelector('audio, video')) return;"
    , "    const player = document.createElement(container.classList.contains('tex2ss-audio') ? 'audio' : 'video');"
    , "    player.controls = true;"
    , "    player.src = source;"
    , "    container.prepend(player);"
    , "  });"
    , "});"
    ]

siteListPlugin :: Text
siteListPlugin =
  Text.unlines
    [ "local tex2ss = require 'tex2ss'"
    , ""
    , "return {"
    , "  generate = function(ctx)"
    , "    local items = {}"
    , "    for _, page in ipairs(ctx.site_index.pages) do"
    , "      if page.slot ~= ctx.owner.slot then"
    , "        local label = pandoc.Inlines({pandoc.Str(page.title)})"
    , "        local link = pandoc.Link(label, page.route)"
    , "        items[#items + 1] = pandoc.Blocks({pandoc.Plain({link})})"
    , "      end"
    , "    end"
    , "    return { list = tex2ss.blocks(pandoc.Blocks({pandoc.BulletList(items)})) }"
    , "  end"
    , "}"
    ]

cloudflareDeploy :: Text
cloudflareDeploy =
  Text.unlines
    [ "return function(ctx)"
    , "  local project = assert(ctx.target.data.project, 'target.data.project is required')"
    , "  return { commands = {"
    , "    { executable = 'wrangler', arguments = {'pages', 'deploy', '.', '--project-name', project}, cwd = 'public' }"
    , "  } }"
    , "end"
    ]

githubPagesDeploy :: Text
githubPagesDeploy =
  Text.unlines
    [ "return function(_)"
    , "  return { commands = {"
    , "    { executable = 'npx', arguments = {'--yes', 'gh-pages', '--dist', '.'}, cwd = 'public' }"
    , "  } }"
    , "end"
    ]

scaffoldGitignore :: Text
scaffoldGitignore = Text.unlines [".tex2ss/", "public/", "pdfs/"]

escapeLaTeX :: Text -> Text
escapeLaTeX = Text.concatMap $ \character ->
  case character of
    '\\' -> "\\textbackslash{}"
    '{' -> "\\{"
    '}' -> "\\}"
    '#' -> "\\#"
    '$' -> "\\$"
    '%' -> "\\%"
    '&' -> "\\&"
    '_' -> "\\_"
    '^' -> "\\textasciicircum{}"
    '~' -> "\\textasciitilde{}"
    _ -> Text.singleton character

filterMPathExists :: [FilePath] -> IO [FilePath]
filterMPathExists paths = fmap concat . forM paths $ \path -> do
  file <- doesFileExist path
  directory <- doesDirectoryExist path
  pure [path | file || directory]

validSiteName :: FilePath -> Bool
validSiteName name =
  not (null name)
    && name `notElem` [".", ".."]
    && takeFileName name == name
    && not (hasDrive name)
