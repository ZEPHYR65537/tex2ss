{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.App
  ( main
  ) where

import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Options.Applicative
  ( Parser
  , ParserInfo
  , ReadM
  , auto
  , command
  , customExecParser
  , eitherReader
  , fullDesc
  , header
  , help
  , helper
  , hsubparser
  , info
  , long
  , metavar
  , option
  , optional
  , prefs
  , progDesc
  , short
  , showDefault
  , strArgument
  , strOption
  , switch
  , value
  )
import System.Directory (getCurrentDirectory, makeAbsolute)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.FilePath (takeFileName)
import System.IO (stderr)
import Tex2ss.Build (BuildPlan (..), buildHtml, prepareBuildPlan)
import Tex2ss.Diagnostics
  ( Diagnostic
  , Severity (Error)
  , diagnostic
  , renderDiagnostics
  )
import Tex2ss.Paths (findProjectRoot, mkProjectPaths, validateSlot)
import Tex2ss.Scaffold (initializeGitRepository, initializeProject, initializeSite, initializeView)
import Tex2ss.Serve (serveProject)
import Tex2ss.Types (BuildTarget (..))

data Command
  = NewSite FilePath FilePath
  | NewView Text.Text
  | Init (Maybe FilePath)
  | Doctor (Maybe FilePath)
  | Build BuildTarget Bool
  | Serve String Int Bool

main :: IO ()
main = do
  selected <- customExecParser (prefs mempty) parserInfo
  exitWith =<< runCommand selected

runCommand :: Command -> IO ExitCode
runCommand commandValue =
  case commandValue of
    NewSite name parent -> do
      absoluteParent <- makeAbsolute parent
      initializeSite absoluteParent name >>= reportResult (\path -> putStrLn $ "created site: " <> path)
    NewView rawSlot ->
      case validateSlot rawSlot of
        Left problem -> reportProblems 2 [problem]
        Right slot -> withProject Nothing $ \root ->
          initializeView (mkProjectPaths root) slot >>= reportResult (\path -> putStrLn $ "created view: " <> path)
    Init requested -> do
      target <- maybe getCurrentDirectory makeAbsolute requested
      initialized <- initializeProject target (Text.pack $ takeFileName target)
      case initialized of
        Left problems -> reportProblems 3 problems
        Right () ->
          initializeGitRepository target
            >>= reportResult (const $ putStrLn $ "initialized site: " <> target)
    Doctor requested -> withProject requested $ \root -> do
      result <- prepareBuildPlan root True
      case result of
        Left problems -> reportProblems 3 problems
        Right plan -> do
          putStrLn $ "project is valid: " <> show (length $ planAllBundles plan) <> " physical bundle(s)"
          pure ExitSuccess
    Build Pdf _ ->
      reportProblems
        2
        [ diagnostic Error "build.pdf-not-in-m1" "PDF is the next M2 milestone and is not implemented by this M1 executable"
        ]
    Build Html includeDrafts -> withProject Nothing $ \root -> do
      result <- buildHtml root includeDrafts
      case result of
        Left problems -> reportProblems 4 problems
        Right True -> putStrLn "build succeeded; public snapshot updated" >> pure ExitSuccess
        Right False -> putStrLn "build succeeded; public snapshot unchanged" >> pure ExitSuccess
    Serve host port includeDrafts -> withProject Nothing $ \root -> do
      result <- serveProject root host port includeDrafts
      case result of
        Left problems -> reportProblems 5 problems
        Right () -> pure ExitSuccess

withProject :: Maybe FilePath -> (FilePath -> IO ExitCode) -> IO ExitCode
withProject requested action = do
  found <- findProjectRoot requested
  case found of
    Left problems -> reportProblems 3 problems
    Right root -> action root

reportResult :: (value -> IO ()) -> Either [Diagnostic] value -> IO ExitCode
reportResult onSuccess result =
  case result of
    Left problems -> reportProblems 3 problems
    Right resultValue -> onSuccess resultValue >> pure ExitSuccess

reportProblems :: Int -> [Diagnostic] -> IO ExitCode
reportProblems code problems = do
  TextIO.hPutStrLn stderr (renderDiagnostics problems)
  pure (ExitFailure code)

parserInfo :: ParserInfo Command
parserInfo =
  info
    (helper <*> commandParser)
    ( fullDesc
        <> header "tex2ss - a LaTeX-first static site generator"
        <> progDesc "Build semantic HTML from physical LaTeX bundles"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "new" (info newParser $ progDesc "Create a site or a physical view")
        <> command "init" (info initParser $ progDesc "Initialize a project without overwriting files")
        <> command "doctor" (info doctorParser $ progDesc "Validate project structure and schemas")
        <> command "build" (info buildParser $ progDesc "Build an output snapshot")
        <> command "serve" (info serveParser $ progDesc "Build, watch, and serve the last successful snapshot")
    )

newParser :: Parser Command
newParser =
  hsubparser
    ( command "site" (info newSiteParser $ progDesc "Create a new site and Git repository")
        <> command "view" (info newViewParser $ progDesc "Create a physical index.tex + meta.json bundle")
    )

newSiteParser :: Parser Command
newSiteParser =
  NewSite
    <$> strArgument (metavar "NAME")
    <*> strOption (long "parent" <> metavar "PATH" <> value "." <> showDefault <> help "Parent directory")

newViewParser :: Parser Command
newViewParser = NewView . Text.pack <$> strArgument (metavar "SLOT")

initParser :: Parser Command
initParser = Init <$> optional (strArgument $ metavar "PATH")

doctorParser :: Parser Command
doctorParser = Doctor <$> optional (strArgument $ metavar "PATH")

buildParser :: Parser Command
buildParser =
  Build
    <$> option buildTargetReader (long "format" <> metavar "html|pdf" <> value Html <> showDefault)
    <*> switch (long "include-drafts" <> help "Include draft bundles")
    <* switch (long "all" <> help "Build all physical bundles (the M1 default)")

buildTargetReader :: ReadM BuildTarget
buildTargetReader = eitherReader $ \rawFormat ->
  case rawFormat of
    "html" -> Right Html
    "pdf" -> Right Pdf
    _ -> Left "format must be html or pdf"

serveParser :: Parser Command
serveParser =
  Serve
    <$> strOption (long "host" <> metavar "HOST" <> value "127.0.0.1" <> showDefault)
    <*> option auto (long "port" <> short 'p' <> metavar "PORT" <> value 8000 <> showDefault)
    <*> switch (long "include-drafts" <> help "Include draft bundles")
