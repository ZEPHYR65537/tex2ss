{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Deploy
  ( DeployCommand (..)
  , DeployPlan (..)
  , deployProject
  , loadDeployPlan
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HsLua as Lua
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.Process
  ( CreateProcess (cwd)
  , proc
  , readCreateProcessWithExitCode
  )
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Text.Pandoc (PandocError, runIO)
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Lua (Global (PANDOC_SCRIPT_FILE), runLua, setGlobals)
import Tex2ss.Build (buildHtmlWith)
import Tex2ss.Config (loadSiteConfig)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Paths (mkProjectPaths, resolveExistingUnder)
import Tex2ss.Types
  ( BuildSelector (SelectAll)
  , DeployTarget (..)
  , ProjectPaths (..)
  , SiteConfig (configDeploy)
  )

data DeployCommand = DeployCommand
  { commandExecutable :: FilePath
  , commandArguments :: [String]
  , commandWorkingDirectory :: FilePath
  }
  deriving stock (Eq, Show)

newtype DeployPlan = DeployPlan
  { deployCommands :: [DeployCommand]
  }
  deriving stock (Eq, Show)

deployProject :: FilePath -> Text -> Bool -> IO (Either [Diagnostic] ())
deployProject root targetName dryRun = do
  built <- buildHtmlWith root False [SelectAll] False
  case built of
    Left problems -> pure (Left problems)
    Right _ -> do
      let paths = mkProjectPaths root
      configResult <- loadSiteConfig (projectConfig paths)
      case configResult of
        Left problems -> pure (Left problems)
        Right config ->
          case Map.lookup targetName (configDeploy config) of
            Nothing ->
              pure . Left $
                [ diagnosticAt
                    Error
                    "deploy.target-unknown"
                    (projectConfig paths)
                    ("unknown deploy target: " <> targetName)
                ]
            Just target -> do
              scriptResult <-
                resolveExistingUnder
                  (projectDeploy paths)
                  (drop 7 $ deployScript target)
              case scriptResult of
                Left problem -> pure (Left [problem])
                Right scriptPath -> do
                  planResult <- loadDeployPlan paths targetName target scriptPath
                  case planResult of
                    Left problems -> pure (Left problems)
                    Right plan -> do
                      startedAt <- getCurrentTime
                      started <- writeDeploymentRecord paths targetName scriptPath startedAt Nothing
                      case started of
                        Left problems -> pure (Left problems)
                        Right () -> do
                          outcome <-
                            if dryRun
                              then do
                                mapM_ printCommand (deployCommands plan)
                                pure (Right ())
                              else executeCommands paths (deployCommands plan)
                          finishedAt <- getCurrentTime
                          recorded <-
                            writeDeploymentRecord
                              paths
                              targetName
                              scriptPath
                              startedAt
                              (Just (dryRun, outcome, finishedAt))
                          pure $ outcome *> recorded

loadDeployPlan
  :: ProjectPaths
  -> Text
  -> DeployTarget
  -> FilePath
  -> IO (Either [Diagnostic] DeployPlan)
loadDeployPlan paths targetName target scriptPath = do
  manifestResult <- readManifestValue (projectPublic paths </> ".tex2ss-manifest.json")
  case manifestResult of
    Left problems -> pure (Left problems)
    Right manifest -> do
      let context =
            object
              [ "public" .= projectPublic paths
              , "manifest" .= manifest
              , "target" .= object ["name" .= targetName, "data" .= deployData target]
              ]
      operation <- try @PandocError . runIO $ do
        result <- runLua $ do
          setGlobals [PANDOC_SCRIPT_FILE scriptPath]
          oldTop <- Lua.gettop
          Lua.dofileTrace (Just scriptPath) >>= \case
            Lua.OK -> pure ()
            _ -> Lua.throwErrorAsException
          newTop <- Lua.gettop
          unless (newTop == oldTop + 1) $
            Lua.failLua "deploy script must return exactly one function"
          Lua.ltype Lua.top >>= \case
            Lua.TypeFunction -> pure ()
            _ -> Lua.failLua "deploy script must return function(ctx)"
          Lua.pushViaJSON context
          Lua.callTrace 1 1
          plan <- Lua.forcePeek (peekDeployPlan Lua.top `Lua.lastly` Lua.pop 1)
          Lua.settop oldTop
          pure plan
        either throwError pure result
      pure $
        case operation of
          Left problem -> Left [deployLuaDiagnostic scriptPath problem]
          Right (Left problem) -> Left [deployLuaDiagnostic scriptPath problem]
          Right (Right plan) -> validateDeployPlan scriptPath plan

peekDeployPlan :: Lua.LuaError error => Lua.Peeker error DeployPlan
peekDeployPlan index = do
  rejectUnknown "deploy plan" (Set.singleton "commands") index
  DeployPlan <$> Lua.peekFieldRaw (Lua.peekList peekDeployCommand) "commands" index

peekDeployCommand :: Lua.LuaError error => Lua.Peeker error DeployCommand
peekDeployCommand index = do
  rejectUnknown "deploy command" (Set.fromList ["executable", "arguments", "cwd"]) index
  DeployCommand
    <$> (Text.unpack <$> Lua.peekFieldRaw Lua.peekText "executable" index)
    <*> (map Text.unpack <$> Lua.peekFieldRaw (Lua.peekList Lua.peekText) "arguments" index)
    <*> (Text.unpack <$> Lua.peekFieldRaw Lua.peekText "cwd" index)

rejectUnknown
  :: Lua.LuaError error
  => String
  -> Set.Set Text
  -> Lua.Peeker error ()
rejectUnknown label allowed index = do
  present <- Map.keysSet <$> Lua.peekMap Lua.peekText (const $ pure ()) index
  let unknown = Set.toAscList (present `Set.difference` allowed)
  unless (null unknown) . Lua.failPeek . ByteString8.pack $
    label <> " contains unknown fields: " <> Text.unpack (Text.intercalate ", " unknown)

validateDeployPlan :: FilePath -> DeployPlan -> Either [Diagnostic] DeployPlan
validateDeployPlan scriptPath plan
  | null problems = Right plan
  | otherwise = Left problems
 where
  problems = concatMap validateCommand (zip [1 :: Int ..] $ deployCommands plan)
  validateCommand (index, command) =
    [ diagnosticAt Error "deploy.command-executable-empty" scriptPath (label index <> " executable must not be empty")
    | null (commandExecutable command)
    ]
      <> [ diagnosticAt Error "deploy.command-cwd-invalid" scriptPath (label index <> " cwd must be 'public'")
         | commandWorkingDirectory command /= "public"
         ]
  label index = "command " <> Text.pack (show index)

executeCommands :: ProjectPaths -> [DeployCommand] -> IO (Either [Diagnostic] ())
executeCommands paths = go
 where
  go [] = pure (Right ())
  go (command : rest) = do
    result <-
      try @IOException $
        readCreateProcessWithExitCode
          ((proc (commandExecutable command) (commandArguments command)) {cwd = Just $ projectPublic paths})
          ""
    case result of
      Left exception ->
        pure . Left $
          [ diagnosticAt Error "deploy.command-io" (projectPublic paths) (Text.pack $ show exception)
          ]
      Right (ExitFailure code, _, _) ->
        pure . Left $
          [ diagnosticAt
              Error
              "deploy.command-failed"
              (projectPublic paths)
              ("deploy command failed with exit code " <> Text.pack (show code))
          ]
      Right (ExitSuccess, _, _) -> go rest

printCommand :: DeployCommand -> IO ()
printCommand command =
  putStrLn . Text.unpack $
    "dry-run: "
      <> Text.pack (commandExecutable command)
      <> Text.concat [" " <> quote (Text.pack argument) | argument <- commandArguments command]
 where
  quote value
    | Text.any (`elem` [' ', '\t', '"']) value = "\"" <> Text.replace "\"" "\\\"" value <> "\""
    | otherwise = value

readManifestValue :: FilePath -> IO (Either [Diagnostic] Value)
readManifestValue path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left [diagnosticAt Error "deploy.manifest-missing" path "successful public manifest is missing"])
    else do
      bytes <- ByteString.readFile path
      pure $
        case eitherDecodeStrict' bytes of
          Left message -> Left [diagnosticAt Error "deploy.manifest-invalid" path (Text.pack message)]
          Right value -> Right value

writeDeploymentRecord
  :: ProjectPaths
  -> Text
  -> FilePath
  -> UTCTime
  -> Maybe (Bool, Either [Diagnostic] (), UTCTime)
  -> IO (Either [Diagnostic] ())
writeDeploymentRecord paths targetName scriptPath startedAt completion = do
  result <- try @IOException $ do
    scriptBytes <- ByteString.readFile scriptPath
    manifestBytes <- ByteString.readFile (projectPublic paths </> ".tex2ss-manifest.json")
    let directory = projectState paths </> "deployments"
        filename = formatTime defaultTimeLocale "%Y%m%dT%H%M%S%qZ" startedAt <> "-" <> Text.unpack targetName <> ".json"
        digest bytes = Text.pack . show $ (hash bytes :: Digest SHA256)
        status = case completion of
          Nothing -> "started" :: Text
          Just (True, _, _) -> "dry-run"
          Just (False, Left _, _) -> "failed"
          Just (False, Right (), _) -> "success"
        finishedAt = case completion of
          Nothing -> Nothing
          Just (_, _, value) -> Just value
        record =
          object
            [ "schema_version" .= (1 :: Int)
            , "target" .= targetName
            , "status" .= status
            , "script_sha256" .= digest scriptBytes
            , "build_manifest_sha256" .= digest manifestBytes
            , "started_at" .= formatTime defaultTimeLocale "%FT%TZ" startedAt
            , "finished_at" .= fmap (formatTime defaultTimeLocale "%FT%TZ") finishedAt
            ]
    createDirectoryIfMissing True directory
    LazyByteString.writeFile (directory </> filename) (encode record)
  pure $
    case result of
      Left exception -> Left [diagnosticAt Error "deploy.record-write" (takeDirectory scriptPath) (Text.pack $ show exception)]
      Right () -> Right ()

deployLuaDiagnostic :: FilePath -> PandocError -> Diagnostic
deployLuaDiagnostic scriptPath problem =
  diagnosticAt Error "deploy.lua-failed" scriptPath (renderError problem)
