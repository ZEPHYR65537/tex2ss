{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Types
  ( BuildTarget (..)
  , Bundle (..)
  , BundleMetadata (..)
  , PageRef (..)
  , PdfEngine (..)
  , PdfName (..)
  , ProjectPaths (..)
  , SiteConfig (..)
  , SiteIndex (..)
  , SiteSettings (..)
  , Slot (..)
  , Visibility (..)
  , isVisible
  , pdfOutputPath
  , renderSlot
  , renderPdfEngine
  , slotOutputPath
  , slotPdfOutputPath
  , slotRoute
  ) where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day)
import GHC.Generics (Generic)
import System.FilePath ((</>))

data BuildTarget = Html | Pdf
  deriving stock (Eq, Ord, Show, Generic)

newtype Slot = Slot {slotSegments :: [Text]}
  deriving stock (Eq, Ord, Show, Generic)

newtype PdfName = PdfName {unPdfName :: Text}
  deriving stock (Eq, Ord, Show, Generic)

data PdfEngine = PdfLaTeX | XeLaTeX | LuaLaTeX
  deriving stock (Eq, Ord, Show, Generic)

renderPdfEngine :: PdfEngine -> Text
renderPdfEngine PdfLaTeX = "pdflatex"
renderPdfEngine XeLaTeX = "xelatex"
renderPdfEngine LuaLaTeX = "lualatex"

renderSlot :: Slot -> Text
renderSlot (Slot []) = "."
renderSlot (Slot segments) = Text.intercalate "/" segments

slotRoute :: Slot -> Text
slotRoute (Slot []) = "/"
slotRoute (Slot segments) = "/" <> Text.intercalate "/" segments <> "/"

slotOutputPath :: Slot -> FilePath
slotOutputPath (Slot []) = "index.html"
slotOutputPath (Slot segments) =
  foldl (</>) "" (map Text.unpack segments) </> "index.html"

slotPdfOutputPath :: Slot -> FilePath
slotPdfOutputPath slot = pdfOutputPath slot Nothing

pdfOutputPath :: Slot -> Maybe PdfName -> FilePath
pdfOutputPath (Slot segments) configuredName =
  foldl (</>) "" (map Text.unpack segments)
    </> (Text.unpack outputName <> ".pdf")
 where
  outputName =
    maybe defaultName unPdfName configuredName
  defaultName =
    case reverse segments of
      name : _ -> name
      [] -> "index"

data Visibility = Published | Draft
  deriving stock (Eq, Ord, Show, Generic)

isVisible :: Bool -> Visibility -> Bool
isVisible includeDrafts visibility = includeDrafts || visibility == Published

data SiteSettings = SiteSettings
  { siteTitle :: Text
  , siteDescription :: Text
  , siteBaseUrl :: Text
  , siteLang :: Text
  , siteAuthor :: Text
  , siteEmail :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

data SiteConfig = SiteConfig
  { configSchemaVersion :: Int
  , configSite :: SiteSettings
  , configTemplates :: Map Text FilePath
  , configDefaultTemplate :: Text
  , configFilters :: [FilePath]
  , configPdfEngine :: PdfEngine
  }
  deriving stock (Eq, Show, Generic)

data BundleMetadata = BundleMetadata
  { metadataSchemaVersion :: Int
  , metadataTitle :: Text
  , metadataAuthor :: Maybe Text
  , metadataDate :: Maybe Day
  , metadataTemplate :: Maybe Text
  , metadataVisibility :: Visibility
  , metadataGenerator :: Maybe FilePath
  , metadataFilters :: [FilePath]
  , metadataData :: Map Text Value
  , metadataPdfName :: Maybe PdfName
  }
  deriving stock (Eq, Show, Generic)

data Bundle = Bundle
  { bundleSlot :: Slot
  , bundleDirectory :: FilePath
  , bundleIndexPath :: FilePath
  , bundleMetaPath :: FilePath
  , bundleMetadata :: BundleMetadata
  }
  deriving stock (Eq, Show, Generic)

data PageRef = PageRef
  { pageId :: Text
  , pageSlot :: Slot
  , pageRoute :: Text
  , pageVisibility :: Visibility
  , pageTitle :: Text
  , pageAuthor :: Maybe Text
  , pageDate :: Maybe Day
  , pageData :: Map Text Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Visibility where
  toJSON Published = "published"
  toJSON Draft = "draft"

instance ToJSON Slot where
  toJSON = toJSON . renderSlot

instance ToJSON PageRef where
  toJSON page =
    object
      [ "id" .= pageId page
      , "slot" .= pageSlot page
      , "route" .= pageRoute page
      , "visibility" .= pageVisibility page
      , "title" .= pageTitle page
      , "author" .= pageAuthor page
      , "date" .= fmap show (pageDate page)
      , "data" .= pageData page
      ]

newtype SiteIndex = SiteIndex {sitePages :: Map Slot PageRef}
  deriving stock (Eq, Show, Generic)

instance ToJSON SiteIndex where
  toJSON = toJSON . Map.elems . sitePages

data ProjectPaths = ProjectPaths
  { projectRoot :: FilePath
  , projectConfig :: FilePath
  , projectContent :: FilePath
  , projectTemplates :: FilePath
  , projectAssets :: FilePath
  , projectPandoc :: FilePath
  , projectPublic :: FilePath
  , projectPdfs :: FilePath
  , projectState :: FilePath
  }
  deriving stock (Eq, Show, Generic)
