module Tex2ss.SiteIndex
  ( buildSiteIndex
  , visiblePages
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (..)
  , PageRef (..)
  , SiteIndex (..)
  , Slot
  , isVisible
  , renderSlot
  , slotRoute
  )

buildSiteIndex :: [Bundle] -> SiteIndex
buildSiteIndex bundles = SiteIndex $ Map.fromList (map pageEntry bundles)
 where
  pageEntry bundle =
    let metadata = bundleMetadata bundle
        slot = bundleSlot bundle
     in ( slot
        , PageRef
            { pageId = renderSlot slot
            , pageSlot = slot
            , pageRoute = slotRoute slot
            , pageVisibility = metadataVisibility metadata
            , pageTitle = metadataTitle metadata
            , pageAuthor = metadataAuthor metadata
            , pageDate = metadataDate metadata
            , pageData = metadataData metadata
            }
        )

visiblePages :: Bool -> SiteIndex -> Map Slot PageRef
visiblePages includeDrafts = Map.filter (isVisible includeDrafts . pageVisibility) . sitePages
