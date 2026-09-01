{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Tex2ss.Config
  ( loadBundleMetadata
  , loadSiteConfig
  , validateConfigPaths
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Data.Foldable (traverse_)
import Data.Aeson
  ( FromJSON (parseJSON)
  , Object
  , eitherDecodeStrict'
  , withObject
  , withText
  , (.:)
  , (.:?)
  , (.!=)
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day, defaultTimeLocale, parseTimeM)
import System.FilePath (takeExtension)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Paths (isPortableName, resolveExistingUnder, validateRelativePath)
import Tex2ss.Types
  ( BundleMetadata (..)
  , DeployTarget (..)
  , PdfEngine (..)
  , PdfName (..)
  , ProjectPaths (..)
  , SiteConfig (..)
  , SiteSettings (..)
  , Visibility (..)
  )

instance FromJSON Visibility where
  parseJSON = withText "visibility" $ \value ->
    case value of
      "published" -> pure Published
      "draft" -> pure Draft
      _ -> fail "visibility must be 'published' or 'draft'"

instance FromJSON PdfName where
  parseJSON = withText "pdf_name" $ \value ->
    if isPortableName value
      then pure (PdfName value)
      else fail "pdf_name must match [a-z0-9][a-z0-9_-]* and omit the .pdf extension"

instance FromJSON PdfEngine where
  parseJSON = withText "pdf_engine" $ \value ->
    case value of
      "pdflatex" -> pure PdfLaTeX
      "xelatex" -> pure XeLaTeX
      "lualatex" -> pure LuaLaTeX
      _ -> fail "pdf_engine must be 'pdflatex', 'xelatex', or 'lualatex'"

instance FromJSON SiteSettings where
  parseJSON = withObject "site" $ \object -> do
    rejectUnknown "site" siteKeys object
    title <- object .: "title" >>= nonEmpty "site.title"
    SiteSettings title
      <$> object .:? "description" .!= ""
      <*> object .:? "base_url" .!= ""
      <*> object .:? "lang" .!= "en"
      <*> object .:? "author" .!= ""
      <*> object .:? "email"

instance FromJSON SiteConfig where
  parseJSON = withObject "config" $ \object -> do
    rejectUnknown "config" configKeys object
    version <- object .: "schema_version"
    when (version /= (1 :: Int)) $ fail "schema_version must be 1"
    pdfEngine <-
      if KeyMap.member "pdf_engine" object
        then object .: "pdf_engine"
        else pure PdfLaTeX
    config <-
      SiteConfig version
        <$> object .: "site"
        <*> object .: "templates"
        <*> object .: "default_template"
        <*> object .:? "filters" .!= []
        <*> pure pdfEngine
        <*> object .:? "deploy" .!= Map.empty
    unless (Map.member (configDefaultTemplate config) (configTemplates config)) $
      fail "default_template must name an entry in templates"
    when (Map.null (configTemplates config)) $
      fail "templates must contain at least one alias"
    traverse_ (validateExtension ".html" "template") (Map.elems $ configTemplates config)
    traverse_ (validateExtension ".lua" "filter") (configFilters config)
    traverse_ validateDeployTarget (Map.toAscList $ configDeploy config)
    pure config

instance FromJSON DeployTarget where
  parseJSON = withObject "deploy target" $ \object -> do
    rejectUnknown "deploy target" deployTargetKeys object
    DeployTarget
      <$> object .: "script"
      <*> object .:? "data" .!= Map.empty

instance FromJSON BundleMetadata where
  parseJSON = withObject "bundle metadata" $ \object -> do
    rejectUnknown "bundle metadata" metadataKeys object
    version <- object .: "schema_version"
    when (version /= (1 :: Int)) $ fail "schema_version must be 1"
    title <- object .: "title" >>= nonEmpty "title"
    rawDate <- object .:? "date"
    parsedDate <- traverse parseDay rawDate
    filters <- object .:? "filters" .!= []
    traverse_ (validateExtension ".lua" "filter") filters
    BundleMetadata version title
      <$> object .:? "author"
      <*> pure parsedDate
      <*> object .:? "template"
      <*> object .:? "visibility" .!= Published
      <*> pure filters
      <*> object .:? "data" .!= Map.empty
      <*> object .:? "pdf_name"
   where
    parseDay :: Text -> Aeson.Parser Day
    parseDay value =
      case parseTimeM True defaultTimeLocale "%F" (Text.unpack value) of
        Nothing -> fail "date must use YYYY-MM-DD"
        Just day -> pure day

loadSiteConfig :: FilePath -> IO (Either [Diagnostic] SiteConfig)
loadSiteConfig = loadJson "config.invalid"

loadBundleMetadata :: FilePath -> IO (Either [Diagnostic] BundleMetadata)
loadBundleMetadata = loadJson "bundle.meta-invalid"

loadJson :: FromJSON value => Text -> FilePath -> IO (Either [Diagnostic] value)
loadJson code path = do
  result <- try @IOException (ByteString.readFile path)
  pure $
    case result of
      Left exception -> Left [diagnosticAt Error "file.read" path (Text.pack $ show exception)]
      Right bytes ->
        case eitherDecodeStrict' bytes of
          Left message -> Left [diagnosticAt Error code path (Text.pack message)]
          Right value -> Right value

validateConfigPaths :: ProjectPaths -> SiteConfig -> IO [Diagnostic]
validateConfigPaths paths config = do
  templateResults <-
    traverse
      (resolveExistingUnder $ projectTemplates paths)
      (Map.elems $ configTemplates config)
  filterResults <-
    traverse
      (resolveExistingUnder $ projectPandoc paths)
      (configFilters config)
  deployResults <-
    traverse
      (resolveExistingUnder $ projectDeploy paths)
      [drop 7 script | target <- Map.elems (configDeploy config), let script = deployScript target]
  pure (lefts templateResults <> lefts filterResults <> lefts deployResults)
 where
  lefts = foldr (\value rest -> either (: rest) (const rest) value) []

rejectUnknown :: String -> Set Text -> Object -> Aeson.Parser ()
rejectUnknown label allowed object =
  let present = Set.fromList (map Key.toText $ KeyMap.keys object)
      unknown = Set.toAscList (present `Set.difference` allowed)
   in unless (null unknown) $
        fail $ label <> " contains unknown fields: " <> Text.unpack (Text.intercalate ", " unknown)

nonEmpty :: String -> Text -> Aeson.Parser Text
nonEmpty field value
  | Text.null (Text.strip value) = fail (field <> " must not be empty")
  | otherwise = pure value

validateExtension :: String -> String -> FilePath -> Aeson.Parser ()
validateExtension expected label path =
  unless (takeExtension path == expected) $
    fail $ label <> " path must end in " <> expected

validateDeployTarget :: (Text, DeployTarget) -> Aeson.Parser ()
validateDeployTarget (name, target) = do
  unless (isPortableName name) $
    fail "deploy target names must match [a-z0-9][a-z0-9_-]*"
  validateExtension ".lua" "deploy script" (deployScript target)
  case validateRelativePath (deployScript target) of
    Left _ -> fail "deploy scripts must use portable relative paths beneath deploy/"
    Right _ -> pure ()
  unless ("deploy/" `Text.isPrefixOf` Text.pack (deployScript target)) $
    fail "deploy scripts must be portable paths beneath deploy/"

siteKeys :: Set Text
siteKeys = Set.fromList ["title", "description", "base_url", "lang", "author", "email"]

configKeys :: Set Text
configKeys = Set.fromList ["schema_version", "site", "templates", "default_template", "filters", "pdf_engine", "deploy"]

deployTargetKeys :: Set Text
deployTargetKeys = Set.fromList ["script", "data"]

metadataKeys :: Set Text
metadataKeys = Set.fromList ["schema_version", "title", "author", "date", "template", "visibility", "filters", "data", "pdf_name"]
