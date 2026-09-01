{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Build
  ( BuildPlan (..)
  , buildHtml
  , buildHtmlWith
  , prepareBuildPlan
  , prepareBuildPlanWith
  ) where

import Control.Exception (IOException, finally, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson (Value (..), eitherDecode, encode)
import qualified Data.ByteString.Lazy.Char8 as LazyChar8
import Data.List (isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Time (defaultTimeLocale, formatTime)
import Data.Version (showVersion)
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
  , loadSnapshotBody
  , makeItem
  , makePatternDependency
  , match
  , route
  , rulesExtraDependencies
  , saveSnapshot
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
  , copyFile
  , createDirectoryIfMissing
  , createDirectory
  , doesDirectoryExist
  , listDirectory
  , removeDirectory
  , removeFile
  , removePathForcibly
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
import Tex2ss.Pandoc (RenderedBundle (..), renderBundleHtmlWith)
import Tex2ss.Plugin
  ( ContentPlugin (pluginOwner, pluginSelectedSlots)
  , PluginAnalysis
  , PluginPlan (pluginsByOwner)
  , analysisSnapshotName
  , ownerAnalysisSlots
  , pluginDependencyDirectories
  , pluginDependencyFiles
  , preparePluginPlan
  )
import Tex2ss.Paths (mkProjectPaths, resolveExistingUnder)
import Tex2ss.SiteIndex (buildSiteIndex)
import Tex2ss.Types
  ( BuildSelector (..)
  , Bundle (..)
  , BundleMetadata (..)
  , ProjectPaths (..)
  , SiteConfig (..)
  , SiteIndex
  , SiteSettings (..)
  , Visibility (..)
  , Slot
  , isVisible
  , renderSlot
  , slotOutputPath
  , slotRoute
  )
import Text.Regex.TDFA (Regex, defaultCompOpt, defaultExecOpt, matchTest)
import qualified Text.Regex.TDFA.String as Regex
import Text.Pandoc (pandocVersion)
import qualified Paths_tex2ss

data BuildPlan = BuildPlan
  { planPaths :: ProjectPaths
  , planConfig :: SiteConfig
  , planSiteIndex :: SiteIndex
  , planPluginPlan :: PluginPlan
  , planAllBundles :: [Bundle]
  , planVisibleBundles :: [Bundle]
  , planBundles :: [Bundle]
  , planBundleDependencies :: Map.Map FilePath [FilePath]
  , planExpectedOutputs :: Set.Set FilePath
  , planSelective :: Bool
  , planForce :: Bool
  }
  deriving stock (Eq, Show)

prepareBuildPlan :: FilePath -> Bool -> IO (Either [Diagnostic] BuildPlan)
prepareBuildPlan root includeDrafts =
  prepareBuildPlanWith root includeDrafts [SelectAll] False

prepareBuildPlanWith
  :: FilePath
  -> Bool
  -> [BuildSelector]
  -> Bool
  -> IO (Either [Diagnostic] BuildPlan)
prepareBuildPlanWith root includeDrafts selectors force = do
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
          bibliographyResult <- listFilesIfPresent (projectLatex paths </> "bibliography")
          let bibliographyFiles = either (const []) id bibliographyResult
              baseDependencies =
                Map.fromList
                  [ (bundleDirectory bundle, pathsForBundle <> bibliographyFiles)
                  | Right (bundle, pathsForBundle) <- bundleChecks
                  ]
              visible = filter (isVisible includeDrafts . metadataVisibility . bundleMetadata) allBundles
              siteIndex = buildSiteIndex allBundles
          pluginResult <- preparePluginPlan paths siteIndex visible
          assetResult <- expectedAssetOutputs paths
          mediaResults <- traverse expectedMediaOutputs visible
          let resourceProblems =
                either id (const []) assetResult
                  <> either id (const []) bibliographyResult
                  <> concat [problems | Left problems <- mediaResults]
                  <> either id (const []) pluginResult
          if not (null resourceProblems)
            then pure (Left resourceProblems)
            else
              case pluginResult of
                Left problems -> pure (Left problems)
                Right pluginPlan -> do
                  case selectBuildBundles selectors pluginPlan visible of
                    Left problems -> pure (Left problems)
                    Right selected -> do
                      let dependencies =
                            Map.mapWithKey
                              (\directory files ->
                                  case [bundle | bundle <- visible, bundleDirectory bundle == directory] of
                                    bundle : _ -> files <> pluginDependencyFiles pluginPlan (bundleSlot bundle)
                                    [] -> files
                              )
                              baseDependencies
                          assetOutputs = either (const []) id assetResult
                          mediaOutputs = concat [outputs | Right outputs <- mediaResults]
                          pageOutputs = map (normalise . slotOutputPath . bundleSlot) visible
                      pure . Right $
                        BuildPlan
                          { planPaths = paths
                          , planConfig = config
                          , planSiteIndex = siteIndex
                          , planPluginPlan = pluginPlan
                          , planAllBundles = allBundles
                          , planVisibleBundles = visible
                          , planBundles = selected
                          , planBundleDependencies = dependencies
                          , planExpectedOutputs = Set.fromList (pageOutputs <> assetOutputs <> mediaOutputs)
                          , planSelective = length selected < length visible
                          , planForce = force
                          }

selectBuildBundles
  :: [BuildSelector]
  -> PluginPlan
  -> [Bundle]
  -> Either [Diagnostic] [Bundle]
selectBuildBundles rawSelectors pluginPlan visible = do
  let selectors = if null rawSelectors then [SelectAll] else rawSelectors
      hasAll = SelectAll `elem` selectors
  when (hasAll && length selectors > 1) $
    Left [diagnostic Error "build.selector-all-mixed" "--which all cannot be combined with other selectors"]
  seedSlots <-
    if hasAll
      then Right (Set.fromList $ map bundleSlot visible)
      else Set.unions <$> traverse matchingSlots selectors
  when (Set.null seedSlots) $
    Left [diagnostic Error "build.selector-empty" "--which matched no visible physical bundle"]
  let closed = dependencyClosure pluginPlan seedSlots
  pure [bundle | bundle <- visible, Set.member (bundleSlot bundle) closed]
 where
  matchingSlots SelectAll = Right Set.empty
  matchingSlots (SelectSlot slot) =
    Right . Set.fromList $
      [bundleSlot bundle | bundle <- visible, bundleSlot bundle == slot]
  matchingSlots (SelectRegex patternText) =
    case Regex.compile defaultCompOpt defaultExecOpt (Text.unpack patternText) of
      Left message ->
        Left [diagnostic Error "build.selector-regex-invalid" (Text.pack message)]
      Right (regex :: Regex) ->
        Right . Set.fromList $
          [ bundleSlot bundle
          | bundle <- visible
          , matchTest regex (Text.unpack $ renderSlot $ bundleSlot bundle)
          ]

dependencyClosure :: PluginPlan -> Set.Set Slot -> Set.Set Slot
dependencyClosure pluginPlan = go
 where
  allPlugins = concat (Map.elems $ pluginsByOwner pluginPlan)
  go current =
    let ownerInputs =
          Set.fromList
            [ selected
            | plugin <- allPlugins
            , Set.member (pluginOwner plugin) current
            , selected <- pluginSelectedSlots plugin
            ]
        affectedOwners =
          Set.fromList
            [ pluginOwner plugin
            | plugin <- allPlugins
            , any (`Set.member` current) (pluginSelectedSlots plugin)
            ]
        next = current <> ownerInputs <> affectedOwners
     in if next == current then current else go next

validateBundle :: SiteConfig -> Bundle -> IO (Either [Diagnostic] (Bundle, [FilePath]))
validateBundle config bundle = do
  let metadata = bundleMetadata bundle
      templateAlias = fromMaybe (configDefaultTemplate config) (metadataTemplate metadata)
      localFilterRoot = bundleDirectory bundle </> "extension"
  includeResult <- expandBundleSource (bundleDirectory bundle) (bundleIndexPath bundle)
  localFilters <- traverse (resolveExistingUnder localFilterRoot) (metadataFilters metadata)
  let templateProblems =
        [ diagnosticAt
            Error
            "template.unknown-alias"
            (bundleMetaPath bundle)
            ("unknown template alias: " <> templateAlias)
        | not (Map.member templateAlias $ configTemplates config)
        ]
      filterProblems = [problem | Left problem <- localFilters]
      includeProblems = either id (const []) includeResult
      problems = templateProblems <> filterProblems <> includeProblems
      includes = filter (/= bundleIndexPath bundle) $ either (const []) expandedDependencies includeResult
      resolvedLocalFilters = [path | Right path <- localFilters]
  pure $
    if null problems
      then Right (bundle, includes <> resolvedLocalFilters)
      else Left problems

buildHtml :: FilePath -> Bool -> IO (Either [Diagnostic] Bool)
buildHtml root includeDrafts = buildHtmlWith root includeDrafts [SelectAll] False

buildHtmlWith
  :: FilePath
  -> Bool
  -> [BuildSelector]
  -> Bool
  -> IO (Either [Diagnostic] Bool)
buildHtmlWith root includeDrafts selectors force = do
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
    Right () -> buildHtmlUnlocked root includeDrafts selectors force `finally` removeDirectory lockDirectory

buildHtmlUnlocked :: FilePath -> Bool -> [BuildSelector] -> Bool -> IO (Either [Diagnostic] Bool)
buildHtmlUnlocked root includeDrafts selectors force = do
  planResult <- prepareBuildPlanWith root includeDrafts selectors force
  case planResult of
    Left problems -> pure (Left problems)
    Right plan -> do
      let paths = planPaths plan
          configuration = hakyllConfiguration paths force
      seeded <- seedSelectiveCandidate plan
      case seeded of
        Left problems -> pure (Left problems)
        Right () -> do
          when force $ resetHakyllForceStore paths
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

hakyllConfiguration :: ProjectPaths -> Bool -> Configuration
hakyllConfiguration paths force =
  defaultConfiguration
    { providerDirectory = projectRoot paths
    , destinationDirectory = htmlWorkDirectory paths
    , storeDirectory = projectState paths </> runtimeStoreName force
    , tmpDirectory = projectState paths </> "tmp"
    , inMemoryCache = True
    , ignoreFile = ignoreProjectFile paths
    }

runtimeStoreName :: Bool -> FilePath
runtimeStoreName force =
  "store-tex2ss-"
    <> showVersion Paths_tex2ss.version
    <> "-pandoc-"
    <> showVersion pandocVersion
    <> if force then "-force" else ""

seedSelectiveCandidate :: BuildPlan -> IO (Either [Diagnostic] ())
seedSelectiveCandidate plan
  | not (planSelective plan) = pure (Right ())
  | otherwise = do
      let paths = planPaths plan
      published <- doesDirectoryExist (projectPublic paths)
      if not published
        then
          pure . Left $
            [ diagnosticAt
                Error
                "build.selective-needs-baseline"
                (projectPublic paths)
                "selective build requires an existing successful public snapshot; run --which all first"
            ]
        else do
          result <- try @IOException $ do
            candidateExists <- doesDirectoryExist (htmlWorkDirectory paths)
            when candidateExists $ removePathForcibly (htmlWorkDirectory paths)
            copyDirectoryTree (projectPublic paths) (htmlWorkDirectory paths)
          pure $
            case result of
              Left exception -> Left [diagnosticAt Error "build.seed-failed" (projectPublic paths) (Text.pack $ show exception)]
              Right () -> Right ()

resetHakyllForceStore :: ProjectPaths -> IO ()
resetHakyllForceStore paths = do
  let target = projectState paths </> runtimeStoreName True
  exists <- doesDirectoryExist target
  when exists $ removePathForcibly target

copyDirectoryTree :: FilePath -> FilePath -> IO ()
copyDirectoryTree source destination = do
  createDirectoryIfMissing True destination
  names <- listDirectory source
  forM_ names $ \name -> do
    let sourcePath = source </> name
        destinationPath = destination </> name
    directory <- doesDirectoryExist sourcePath
    if directory
      then copyDirectoryTree sourcePath destinationPath
      else copyFile sourcePath destinationPath

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
  bibliographyDependency <-
    makePatternDependency
      KindContent
      (fromGlob "latex/bibliography/**")

  forM_ bundles $ \bundle -> do
    pluginSetDependencies <-
      traverse
        (makePatternDependency KindContent . fromGlob . (<> "/**") . slashPath . projectRelative paths)
        (pluginDependencyDirectories (planPluginPlan plan) $ bundleSlot bundle)
    rulesExtraDependencies (siteIndexDependency : bibliographyDependency : pluginSetDependencies) $
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
      bundleBySlot = Map.fromList [(bundleSlot candidate, candidate) | candidate <- planBundles plan]
      analysisBundles =
        [ candidate
        | slot <- ownerAnalysisSlots (planPluginPlan plan) (bundleSlot bundle)
        , Just candidate <- [Map.lookup slot bundleBySlot]
        ]
  void getResourceBody
  forM_ (nub directDependencies) $ \path ->
    void (loadBody $ projectIdentifier paths path :: Compiler String)
  encodedAnalyses <-
    forM analysisBundles $ \candidate ->
      loadSnapshotBody
        (projectIdentifier paths $ bundleIndexPath candidate)
        analysisSnapshotName
  descendantAnalyses <- concat <$> traverse decodeAnalysisSnapshot encodedAnalyses
  rendered <-
    unsafeCompiler $
      renderBundleHtmlWith
        paths
        config
        (planSiteIndex plan)
        (planPluginPlan plan)
        descendantAnalyses
        bundle
  compiled <-
    case rendered of
      Left problems -> fail (Text.unpack $ renderDiagnostics problems)
      Right value -> pure value
  analysisItem <- makeItem (LazyChar8.unpack $ encode $ renderedAnalyses compiled)
  void $ saveSnapshot analysisSnapshotName analysisItem
  let templateAlias = fromMaybe (configDefaultTemplate config) (metadataTemplate $ bundleMetadata bundle)
      selectedTemplate = configTemplates config Map.! templateAlias
      templateIdentifier = projectIdentifier paths (templatePath paths selectedTemplate)
  makeItem (Text.unpack $ renderedHtml compiled)
    >>= loadAndApplyTemplate templateIdentifier (pageContext config bundle $ renderedToc compiled)

decodeAnalysisSnapshot :: String -> Compiler [PluginAnalysis]
decodeAnalysisSnapshot encoded =
  case eitherDecode (LazyChar8.pack encoded) of
    Left problem -> fail ("invalid tex2ss analysis snapshot: " <> problem)
    Right value -> pure value

pageContext :: SiteConfig -> Bundle -> Text.Text -> Context String
pageContext config bundle toc =
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
      , constField "toc" (Text.unpack toc)
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
