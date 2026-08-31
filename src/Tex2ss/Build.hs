{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Build
  ( BuildPlan (..)
  , buildHtml
  , prepareBuildPlan
  ) where

import Control.Exception (IOException, finally, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson (Value (..), encode)
import qualified Data.ByteString.Lazy.Char8 as LazyChar8
import Data.List (isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Time (defaultTimeLocale, formatTime)
import Hakyll
  ( Compiler
  , Configuration (..)
  , Context
  , Identifier
  , Item
  , Rules
  , bodyField
  , compile
  , constField
  , copyFileCompiler
  , customRoute
  , defaultConfiguration
  , fromFilePath
  , fromGlob
  , fromList
  , getResourceBody
  , loadAndApplyTemplate
  , loadBody
  , makeItem
  , makePatternDependency
  , match
  , route
  , rulesExtraDependencies
  , templateCompiler
  , toFilePath
  , unsafeCompiler
  , (.||.)
  )
import Hakyll.Core.Dependencies (DependencyKind (KindContent))
import qualified Hakyll.Core.Logger as Logger
import Hakyll.Core.Runtime (RunMode (RunModeNormal), run)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , createDirectory
  , doesDirectoryExist
  , listDirectory
  , removeDirectory
  , removeFile
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath
  ( isAbsolute
  , makeRelative
  , normalise
  , splitDirectories
  , takeDirectory
  , takeFileName
  , (</>)
  )
import Tex2ss.Config (loadSiteConfig, validateConfigPaths)
import Tex2ss.Diagnostics
  ( Diagnostic (diagnosticHint)
  , Severity (Error)
  , diagnostic
  , diagnosticAt
  , renderDiagnostics
  )
import Tex2ss.Discovery (discoverBundles)
import Tex2ss.Include (ExpandedSource (expandedDependencies), expandBundleSource)
import Tex2ss.Manifest (commitHtmlSnapshot, htmlWorkDirectory)
import Tex2ss.Pandoc (renderBundleHtml)
import Tex2ss.Paths (mkProjectPaths, resolveExistingUnder)
import Tex2ss.SiteIndex (buildSiteIndex)
import Tex2ss.Types
  ( Bundle (..)
  , BundleMetadata (..)
  , ProjectPaths (..)
  , SiteConfig (..)
  , SiteIndex
  , SiteSettings (..)
  , Visibility (..)
  , isVisible
  , renderSlot
  , slotOutputPath
  , slotRoute
  )

data BuildPlan = BuildPlan
  { planPaths :: ProjectPaths
  , planConfig :: SiteConfig
  , planSiteIndex :: SiteIndex
  , planAllBundles :: [Bundle]
  , planBundles :: [Bundle]
  , planBundleDependencies :: Map.Map FilePath [FilePath]
  , planExpectedOutputs :: Set.Set FilePath
  }
  deriving stock (Eq, Show)

prepareBuildPlan :: FilePath -> Bool -> IO (Either [Diagnostic] BuildPlan)
prepareBuildPlan root includeDrafts = do
  let paths = mkProjectPaths root
  configResult <- loadSiteConfig (projectConfig paths)
  bundlesResult <- discoverBundles paths
  case (configResult, bundlesResult) of
    (Left configProblems, Left bundleProblems) -> pure $ Left (configProblems <> bundleProblems)
    (Left problems, _) -> pure $ Left problems
    (_, Left problems) -> pure $ Left problems
    (Right config, Right allBundles) -> do
      configPathProblems <- validateConfigPaths paths config
      bundleChecks <- traverse (validateBundle config) allBundles
      let bundleProblems = concat [problems | Left problems <- bundleChecks]
      if not (null $ configPathProblems <> bundleProblems)
        then pure $ Left (configPathProblems <> bundleProblems)
        else do
          let dependencies =
                Map.fromList
                  [ (bundleDirectory bundle, pathsForBundle)
                  | Right (bundle, pathsForBundle) <- bundleChecks
                  ]
              selected = filter (isVisible includeDrafts . metadataVisibility . bundleMetadata) allBundles
          assetResult <- expectedAssetOutputs paths
          mediaResults <- traverse expectedMediaOutputs selected
          let resourceProblems =
                either id (const []) assetResult
                  <> concat [problems | Left problems <- mediaResults]
          if not (null resourceProblems)
            then pure (Left resourceProblems)
            else do
              let assetOutputs = either (const []) id assetResult
                  mediaOutputs = concat [outputs | Right outputs <- mediaResults]
                  pageOutputs = map (normalise . slotOutputPath . bundleSlot) selected
              pure . Right $
                BuildPlan
                  { planPaths = paths
                  , planConfig = config
                  , planSiteIndex = buildSiteIndex allBundles
                  , planAllBundles = allBundles
                  , planBundles = selected
                  , planBundleDependencies = dependencies
                  , planExpectedOutputs = Set.fromList (pageOutputs <> assetOutputs <> mediaOutputs)
                  }

validateBundle :: SiteConfig -> Bundle -> IO (Either [Diagnostic] (Bundle, [FilePath]))
validateBundle config bundle = do
  let metadata = bundleMetadata bundle
      templateAlias = fromMaybe (configDefaultTemplate config) (metadataTemplate metadata)
      localFilterRoot = bundleDirectory bundle </> "extension"
  includeResult <- expandBundleSource (bundleDirectory bundle) (bundleIndexPath bundle)
  localFilters <- traverse (resolveExistingUnder localFilterRoot) (metadataFilters metadata)
  generator <- traverse (resolveExistingUnder localFilterRoot) (metadataGenerator metadata)
  let templateProblems =
        [ diagnosticAt
            Error
            "template.unknown-alias"
            (bundleMetaPath bundle)
            ("unknown template alias: " <> templateAlias)
        | not (Map.member templateAlias $ configTemplates config)
        ]
      filterProblems = [problem | Left problem <- localFilters]
      generatorProblems = maybe [] (either (: []) (const [])) generator
      includeProblems = either id (const []) includeResult
      problems = templateProblems <> filterProblems <> generatorProblems <> includeProblems
      includes = filter (/= bundleIndexPath bundle) $ either (const []) expandedDependencies includeResult
      resolvedLocalFilters = [path | Right path <- localFilters]
      resolvedGenerator = maybe [] (either (const []) (: [])) generator
  pure $
    if null problems
      then Right (bundle, includes <> resolvedLocalFilters <> resolvedGenerator)
      else Left problems

buildHtml :: FilePath -> Bool -> IO (Either [Diagnostic] Bool)
buildHtml root includeDrafts = do
  let paths = mkProjectPaths root
      lockDirectory = projectState paths </> "build.lock"
  createDirectoryIfMissing True (projectState paths)
  acquired <- try @IOException (createDirectory lockDirectory)
  case acquired of
    Left _ ->
      pure . Left $
        [ (diagnosticAt Error "build.locked" lockDirectory "another tex2ss build owns this project")
            { diagnosticHint = Just "If no build is running, remove the stale .tex2ss/build.lock directory."
            }
        ]
    Right () -> buildHtmlUnlocked root includeDrafts `finally` removeDirectory lockDirectory

buildHtmlUnlocked :: FilePath -> Bool -> IO (Either [Diagnostic] Bool)
buildHtmlUnlocked root includeDrafts = do
  planResult <- prepareBuildPlan root includeDrafts
  case planResult of
    Left problems -> pure (Left problems)
    Right plan -> do
      let paths = planPaths plan
          configuration = hakyllConfiguration paths
      createDirectoryIfMissing True (htmlWorkDirectory paths)
      logger <- Logger.new Logger.Message
      (exitCode, _) <- run RunModeNormal configuration logger (siteRules plan)
      case exitCode of
        ExitFailure _ ->
          pure . Left $
            [ diagnostic Error "build.hakyll-failed" "Hakyll failed; the previous public snapshot was preserved"
            ]
        ExitSuccess -> do
          pruneCandidate plan
          commitHtmlSnapshot paths

hakyllConfiguration :: ProjectPaths -> Configuration
hakyllConfiguration paths =
  defaultConfiguration
    { providerDirectory = projectRoot paths
    , destinationDirectory = htmlWorkDirectory paths
    , storeDirectory = projectState paths </> "store"
    , tmpDirectory = projectState paths </> "tmp"
    , inMemoryCache = True
    , ignoreFile = ignoreProjectFile paths
    }

ignoreProjectFile :: ProjectPaths -> FilePath -> Bool
ignoreProjectFile paths path =
  case splitDirectories relative of
    first : _
      | first `elem` [".git", ".tex2ss", "public", "pdfs", "dist-newstyle", ".stack-work"] -> True
    _ -> editorTemporary (takeFileName path)
 where
  editorTemporary name =
    "#" `isPrefixOf` name
      || "~" `isSuffixOf` name
      || ".swp" `isSuffixOf` name
  relative = normalise $ if isAbsolute path then makeRelative (projectRoot paths) path else path

siteRules :: BuildPlan -> Rules ()
siteRules plan = do
  let paths = planPaths plan
      config = planConfig plan
      bundles = planBundles plan
      templateIds = map (projectIdentifier paths . templatePath paths) (Map.elems $ configTemplates config)
      metaPattern = fromGlob "content/meta.json" .||. fromGlob "content/**/meta.json"
      sourceIds =
        map (projectIdentifier paths)
          . nub
          . concat
          $ Map.elems (planBundleDependencies plan)
      filterIds =
        map (projectIdentifier paths)
          [ projectPandoc paths </> path
          | path <- configFilters config
          ]

  match (fromList templateIds) $ compile templateCompiler
  match metaPattern $ compile getResourceBody
  compileDependencies (nub $ fromFilePath "config.json" : sourceIds <> filterIds)

  match (fromGlob "site/assets/**") $ do
    route $ customRoute assetRoute
    compile copyFileCompiler

  forM_ bundles $ \bundle -> do
    let mediaPattern = fromGlob $ slashPath (projectRelative paths $ bundleDirectory bundle </> "media" </> "**")
    match mediaPattern $ do
      route $ customRoute (bundleMediaRoute paths bundle)
      compile copyFileCompiler

  siteIndexDependency <-
    makePatternDependency
      KindContent
      metaPattern

  forM_ bundles $ \bundle ->
    rulesExtraDependencies [siteIndexDependency] $
      match (fromList [projectIdentifier paths $ bundleIndexPath bundle]) $ do
        route $ customRoute (const $ slotOutputPath $ bundleSlot bundle)
        compile $ pageCompiler plan bundle
compileDependencies :: [Identifier] -> Rules ()
compileDependencies [] = pure ()
compileDependencies identifiers =
  match (fromList identifiers) $ compile getResourceBody

pageCompiler :: BuildPlan -> Bundle -> Compiler (Item String)
pageCompiler plan bundle = do
  let paths = planPaths plan
      config = planConfig plan
      allMeta = map bundleMetaPath (allIndexedBundles plan)
      directDependencies =
        [projectConfig paths]
          <> allMeta
          <> Map.findWithDefault [] (bundleDirectory bundle) (planBundleDependencies plan)
          <> [projectPandoc paths </> path | path <- configFilters config]
  void getResourceBody
  forM_ (nub directDependencies) $ \path ->
    void (loadBody $ projectIdentifier paths path :: Compiler String)
  rendered <- unsafeCompiler $ renderBundleHtml paths config (planSiteIndex plan) bundle
  html <-
    case rendered of
      Left problems -> fail (Text.unpack $ renderDiagnostics problems)
      Right value -> pure value
  let templateAlias = fromMaybe (configDefaultTemplate config) (metadataTemplate $ bundleMetadata bundle)
      selectedTemplate = configTemplates config Map.! templateAlias
      templateIdentifier = projectIdentifier paths (templatePath paths selectedTemplate)
  makeItem (Text.unpack html)
    >>= loadAndApplyTemplate templateIdentifier (pageContext config bundle)

pageContext :: SiteConfig -> Bundle -> Context String
pageContext config bundle =
  mconcat
    ( [ bodyField "body"
      , constField "title" (Text.unpack $ metadataTitle metadata)
      , constField "author" (Text.unpack $ fromMaybe (siteAuthor site) $ metadataAuthor metadata)
      , constField "date" (maybe "" (formatTime defaultTimeLocale "%F") $ metadataDate metadata)
      , constField "visibility" (visibilityText $ metadataVisibility metadata)
      , constField "slot" (Text.unpack $ renderSlot $ bundleSlot bundle)
      , constField "route" (Text.unpack $ slotRoute $ bundleSlot bundle)
      , constField "site_title" (Text.unpack $ siteTitle site)
      , constField "site_description" (Text.unpack $ siteDescription site)
      , constField "base_url" (Text.unpack $ siteBaseUrl site)
      , constField "lang" (Text.unpack $ siteLang site)
      ]
        <> map customField (Map.toAscList $ metadataData metadata)
    )
 where
  metadata = bundleMetadata bundle
  site = configSite config
  customField (key, value) = constField ("data_" <> Text.unpack key) (renderValue value)
  visibilityText Published = "published"
  visibilityText Draft = "draft"

renderValue :: Value -> String
renderValue (String value) = Text.unpack value
renderValue (Number value) = show value
renderValue (Bool True) = "true"
renderValue (Bool False) = "false"
renderValue Null = ""
renderValue value = LazyChar8.unpack (encode value)

templatePath :: ProjectPaths -> FilePath -> FilePath
templatePath paths relative = projectTemplates paths </> relative

projectIdentifier :: ProjectPaths -> FilePath -> Identifier
projectIdentifier paths = fromFilePath . projectRelative paths

projectRelative :: ProjectPaths -> FilePath -> FilePath
projectRelative paths = normalise . makeRelative (projectRoot paths)

assetRoute :: Identifier -> FilePath
assetRoute identifier =
  "assets"
    </> makeRelative
      (normalise $ "site" </> "assets")
      (toFilePath identifier)

bundleMediaRoute :: ProjectPaths -> Bundle -> Identifier -> FilePath
bundleMediaRoute paths bundle identifier =
  let mediaRoot = bundleDirectory bundle </> "media"
      source = projectRoot paths </> toFilePath identifier
      relative = makeRelative mediaRoot source
      slotPrefix =
        case splitDirectories (slotOutputPath $ bundleSlot bundle) of
          ["index.html"] -> ""
          segments -> foldl (</>) "" (init segments)
   in slotPrefix </> "media" </> relative

expectedAssetOutputs :: ProjectPaths -> IO (Either [Diagnostic] [FilePath])
expectedAssetOutputs paths = do
  files <- listFilesIfPresent (projectAssets paths)
  pure $ fmap (map $ \file -> normalise $ "assets" </> makeRelative (projectAssets paths) file) files

expectedMediaOutputs :: Bundle -> IO (Either [Diagnostic] [FilePath])
expectedMediaOutputs bundle = do
  let mediaRoot = bundleDirectory bundle </> "media"
  files <- listFilesIfPresent mediaRoot
  let pageDirectory = takeDirectory (slotOutputPath $ bundleSlot bundle)
      prefix = if pageDirectory == "." then "" else pageDirectory
  pure $ fmap (map $ \file -> normalise $ prefix </> "media" </> makeRelative mediaRoot file) files

listFilesIfPresent :: FilePath -> IO (Either [Diagnostic] [FilePath])
listFilesIfPresent root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure (Right [])
    else do
      result <- try @IOException $ do
        canonicalRoot <- canonicalizePath root
        listFiles canonicalRoot Set.empty root
      pure $
        case result of
          Left exception -> Left [diagnosticAt Error "resource.io" root (Text.pack $ show exception)]
          Right value -> value
 where
  listFiles canonicalRoot seen directory = do
    canonicalDirectory <- canonicalizePath directory
    if not (insidePath canonicalRoot canonicalDirectory)
      then pure $ Left [diagnosticAt Error "resource.path-escape" directory "resource directory escapes its owning root"]
      else
        if Set.member canonicalDirectory seen
          then pure $ Left [diagnosticAt Error "resource.directory-cycle" directory "resource directory forms a symlink or junction cycle"]
          else do
            names <- sort <$> listDirectory directory
            entries <- forM names $ \name -> do
              let path = directory </> name
              canonicalPath <- canonicalizePath path
              if not (insidePath canonicalRoot canonicalPath)
                then pure $ Left [diagnosticAt Error "resource.path-escape" path "resource escapes its owning root"]
                else do
                  isDirectory <- doesDirectoryExist path
                  if isDirectory
                    then listFiles canonicalRoot (Set.insert canonicalDirectory seen) path
                    else pure (Right [path])
            let problems = concat [items | Left items <- entries]
            pure $
              if null problems
                then Right (concat [items | Right items <- entries])
                else Left problems

insidePath :: FilePath -> FilePath -> Bool
insidePath root candidate =
  let relative = makeRelative root candidate
   in relative == "."
        || (not (isAbsolute relative) && not (".." `elem` splitDirectories relative))

pruneCandidate :: BuildPlan -> IO ()
pruneCandidate plan = pruneDirectory (htmlWorkDirectory $ planPaths plan)
 where
  expected = planExpectedOutputs plan
  pruneDirectory directory = do
    names <- listDirectory directory
    forM_ names $ \name -> do
      let path = directory </> name
      isDirectory <- doesDirectoryExist path
      if isDirectory
        then do
          pruneDirectory path
          remaining <- listDirectory path
          when (null remaining) $ removeDirectory path
        else do
          let relative = normalise $ makeRelative (htmlWorkDirectory $ planPaths plan) path
          unless (Set.member relative expected) $ removeFile path

allIndexedBundles :: BuildPlan -> [Bundle]
allIndexedBundles = planAllBundles

slashPath :: FilePath -> FilePath
slashPath = map (\character -> if character == '\\' then '/' else character)
