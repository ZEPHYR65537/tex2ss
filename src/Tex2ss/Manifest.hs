{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Manifest
  ( Manifest (..)
  , ManifestEntry (..)
  , commitHtmlSnapshot
  , createManifest
  , htmlWorkDirectory
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, when)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , eitherDecodeFileStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removePathForcibly
  , renameDirectory
  )
import System.FilePath (makeRelative, (</>))
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Types (ProjectPaths (..))

data ManifestEntry = ManifestEntry
  { manifestPath :: FilePath
  , manifestSha256 :: Text
  , manifestBytes :: Integer
  }
  deriving stock (Eq, Show, Generic)

data Manifest = Manifest
  { manifestSchemaVersion :: Int
  , manifestFiles :: [ManifestEntry]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ManifestEntry where
  toJSON entry =
    object
      [ "path" .= manifestPath entry
      , "sha256" .= manifestSha256 entry
      , "bytes" .= manifestBytes entry
      ]

instance FromJSON ManifestEntry where
  parseJSON = withObject "manifest entry" $ \value ->
    ManifestEntry <$> value .: "path" <*> value .: "sha256" <*> value .: "bytes"

instance ToJSON Manifest where
  toJSON manifest =
    object
      [ "schema_version" .= manifestSchemaVersion manifest
      , "files" .= manifestFiles manifest
      ]

instance FromJSON Manifest where
  parseJSON = withObject "manifest" $ \value ->
    Manifest <$> value .: "schema_version" <*> value .: "files"

htmlWorkDirectory :: ProjectPaths -> FilePath
htmlWorkDirectory paths = projectState paths </> "work" </> "public"

createManifest :: FilePath -> IO Manifest
createManifest root = do
  files <- listFilesRecursively root
  entries <- forM (sort files) $ \path -> do
    bytes <- LazyByteString.readFile path
    let digest = hashlazy bytes :: Digest SHA256
    pure
      ManifestEntry
        { manifestPath = slashPath $ makeRelative root path
        , manifestSha256 = Text.pack (show digest)
        , manifestBytes = fromIntegral (LazyByteString.length bytes)
        }
  pure $ Manifest 1 entries

commitHtmlSnapshot :: ProjectPaths -> IO (Either [Diagnostic] Bool)
commitHtmlSnapshot paths = do
  let candidate = htmlWorkDirectory paths
      staging = projectState paths </> "commit-public"
      backup = projectState paths </> "previous-public"
      destination = projectPublic paths
      manifestName = ".tex2ss-manifest.json"
      destinationManifest = destination </> manifestName
  candidateExists <- doesDirectoryExist candidate
  if not candidateExists
    then pure $ Left [diagnosticAt Error "build.candidate-missing" candidate "Hakyll produced no candidate directory"]
    else do
      operation <- try @IOException $ do
        removeIfExists staging
        removeIfExists backup
        copyDirectory candidate staging
        manifest <- createManifest staging
        LazyByteString.writeFile (staging </> manifestName) (encode manifest)
        oldManifest <- readManifest destinationManifest
        if oldManifest == Just manifest
          then removeIfExists staging >> pure False
          else do
            destinationExists <- doesDirectoryExist destination
            when destinationExists $ renameDirectory destination backup
            committed <- try @IOException (renameDirectory staging destination)
            case committed of
              Right () -> removeIfExists backup >> pure True
              Left exception -> do
                currentExists <- doesDirectoryExist destination
                when currentExists $ removePathForcibly destination
                backupExists <- doesDirectoryExist backup
                when backupExists $ renameDirectory backup destination
                ioError exception
      pure $
        case operation of
          Left exception -> Left [diagnosticAt Error "build.commit-failed" destination (Text.pack $ show exception)]
          Right changed -> Right changed

readManifest :: FilePath -> IO (Maybe Manifest)
readManifest path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      decoded <- eitherDecodeFileStrict' path
      pure $ either (const Nothing) Just decoded

copyDirectory :: FilePath -> FilePath -> IO ()
copyDirectory source destination = do
  createDirectoryIfMissing True destination
  names <- listDirectory source
  mapM_ copyEntry names
 where
  copyEntry name = do
    let sourcePath = source </> name
        destinationPath = destination </> name
    directory <- doesDirectoryExist sourcePath
    if directory
      then copyDirectory sourcePath destinationPath
      else copyFile sourcePath destinationPath

listFilesRecursively :: FilePath -> IO [FilePath]
listFilesRecursively directory = do
  names <- listDirectory directory
  fmap concat . forM names $ \name -> do
    let path = directory </> name
    isDirectory <- doesDirectoryExist path
    if isDirectory then listFilesRecursively path else pure [path]

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  isDirectory <- doesDirectoryExist path
  isFile <- doesFileExist path
  when (isDirectory || isFile) $ removePathForcibly path

slashPath :: FilePath -> FilePath
slashPath = map (\character -> if character == '\\' then '/' else character)
