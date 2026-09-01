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
  , (root </> "site" </> "templates" </> "default.html", \path -> TextIO.writeFile path defaultTemplate)
  , (root </> "site" </> "assets" </> "style.css", \path -> TextIO.writeFile path defaultCss)
  , (root </> ".gitignore", \path -> TextIO.writeFile path scaffoldGitignore)
  ]

scaffoldDirectories :: [FilePath]
scaffoldDirectories =
  [ "content"
  , "pandoc" </> "filters"
  , "latex" </> "bibliography"
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
      , "filters" .= ([] :: [Text])
      , "pdf_engine" .= ("pdflatex" :: Text)
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
    , "pre { overflow-x: auto; }"
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
