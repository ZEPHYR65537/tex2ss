{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Serve
  ( serveProject
  ) where

import Control.Concurrent
  ( MVar
  , forkIO
  , newEmptyMVar
  , takeMVar
  , threadDelay
  , tryPutMVar
  , tryTakeMVar
  )
import Control.Exception (SomeException, try)
import Control.Monad (forever, unless, void)
import Data.String (fromString)
import qualified Data.Text.IO as TextIO
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import Network.Wai.Handler.Warp
  ( defaultSettings
  , runSettings
  , setBeforeMainLoop
  , setHost
  , setPort
  )
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath (makeRelative, splitDirectories)
import System.FSNotify (eventPath, watchTree, withManager)
import Tex2ss.Build (buildHtml)
import Tex2ss.Diagnostics
  ( Diagnostic
  , Severity (Error)
  , diagnostic
  , renderDiagnostics
  )
import Tex2ss.Paths (mkProjectPaths)
import Tex2ss.Types (ProjectPaths (projectPublic))

serveProject :: FilePath -> String -> Int -> Bool -> IO (Either [Diagnostic] ())
serveProject root host port includeDrafts = do
  let publicDirectory = projectPublic (mkProjectPaths root)
  initial <- buildHtml root includeDrafts
  publicExists <- doesDirectoryExist publicDirectory
  case (initial, publicExists) of
    (Left problems, False) -> pure (Left problems)
    (Left problems, True) -> do
      TextIO.putStrLn (renderDiagnostics problems)
      runServer publicDirectory
    (Right _, _) -> runServer publicDirectory
 where
  runServer publicDirectory = do
    createDirectoryIfMissing True publicDirectory
    signal <- newEmptyMVar
    result <- try @SomeException . withManager $ \manager -> do
      _ <- watchTree manager root (shouldRebuild root . eventPath) (const $ void $ tryPutMVar signal ())
      _ <- forkIO (rebuildWorker signal)
      let settings =
            setHost (fromString host)
              . setPort port
              . setBeforeMainLoop (putStrLn $ "tex2ss preview: http://" <> host <> ":" <> show port)
              $ defaultSettings
      runSettings settings (staticApp $ defaultFileServerSettings publicDirectory)
    pure $
      case result of
        Left exception -> Left [diagnostic Error "serve.failed" (fromString $ show exception)]
        Right () -> Right ()

  rebuildWorker :: MVar () -> IO ()
  rebuildWorker signal = forever $ do
    takeMVar signal
    threadDelay 150000
    drain signal
    result <- buildHtml root includeDrafts
    case result of
      Left problems -> TextIO.putStrLn (renderDiagnostics problems)
      Right changed -> unless changed $ pure ()

  drain signal = do
    pending <- tryTakeMVar signal
    case pending of
      Nothing -> pure ()
      Just () -> drain signal

shouldRebuild :: FilePath -> FilePath -> Bool
shouldRebuild root path =
  case splitDirectories (makeRelative root path) of
    first : _ -> first `notElem` [".git", ".tex2ss", "public", "pdfs", "dist-newstyle"]
    [] -> False
