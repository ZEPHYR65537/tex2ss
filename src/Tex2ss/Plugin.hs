{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Tex2ss.Plugin
  ( AssembledSource (..)
  , ContentPlugin (..)
  , GeneratedContent (..)
  , PluginAnalysis (..)
  , PluginPlan (..)
  , PluginReference (..)
  , PluginResult (..)
  , analysisSnapshotName
  , assembleGeneratedSource
  , interestedPlugins
  , ownerAnalysisSlots
  , ownerPlugins
  , parsePluginReferences
  , pluginDependencyDirectories
  , pluginDependencyFiles
  , preparePluginPlan
  , runPluginAnalyzers
  , runPluginGenerators
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, unless, when)
import Control.Monad.Except (throwError)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value
  , encode
  , object
  , withObject
  , withText
  , (.:)
  , (.=)
  )
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (ord)
import Data.List (isPrefixOf, nubBy, sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HsLua as Lua
import Numeric (showHex)
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.FilePath
  ( isAbsolute
  , makeRelative
  , splitDirectories
  , (</>)
  )
import Text.Pandoc (Pandoc, PandocError, runIO)
import Text.Pandoc.Definition (Block (RawBlock), Format (..), Inline (RawInline))
import Text.Pandoc.Error (renderError)
import Text.Pandoc.Lua (Global (PANDOC_DOCUMENT, PANDOC_SCRIPT_FILE), runLua, setGlobals)
import Text.Pandoc.Walk (query)
import Tex2ss.Diagnostics (Diagnostic, Severity (Error), diagnosticAt)
import Tex2ss.Include (ExpandedSource (expandedText), expandBundleSource)
import Tex2ss.Paths (isPortableName, resolveExistingUnder, validateSlot)
import Tex2ss.Types
  ( Bundle (..)
  , PageRef
  , ProjectPaths (..)
  , SiteIndex (sitePages)
  , Slot (..)
  , renderSlot
  )

data PluginReference = PluginReference
  { referencePlugin :: Text
  , referenceFragment :: Text
  }
  deriving stock (Eq, Ord, Show)

data GeneratedContent
  = DeferredLaTeXBlock Text
  | PandocBlocks [Block]
  deriving stock (Eq, Show)

newtype PluginResult = PluginResult
  { generatedFragments :: Map Text GeneratedContent
  }
  deriving stock (Eq, Show)

data AssembledSource = AssembledSource
  { assembledText :: Text
  , assembledPandocFragments :: Map Text [Block]
  }
  deriving stock (Eq, Show)

data ContentPlugin = ContentPlugin
  { pluginOwner :: Slot
  , pluginId :: Text
  , pluginDirectory :: FilePath
  , pluginEntryPath :: FilePath
  , pluginFiles :: [FilePath]
  , pluginWatchDirectories :: [FilePath]
  , pluginSelectedSlots :: [Slot]
  , pluginHasAnalyzer :: Bool
  }
  deriving stock (Eq, Show)

data PluginPlan = PluginPlan
  { pluginReferencesByOwner :: Map Slot [PluginReference]
  , pluginsByOwner :: Map Slot [ContentPlugin]
  }
  deriving stock (Eq, Show)

data PluginAnalysis = PluginAnalysis
  { analysisOwner :: Slot
  , analysisPlugin :: Text
  , analysisDocument :: Slot
  , analysisValue :: Value
  }
  deriving stock (Eq, Show)

instance ToJSON PluginAnalysis where
  toJSON value =
    object
      [ "owner" .= renderSlot (analysisOwner value)
      , "plugin" .= analysisPlugin value
      , "document" .= renderSlot (analysisDocument value)
      , "value" .= analysisValue value
      ]

instance FromJSON PluginAnalysis where
  parseJSON = withObject "PluginAnalysisV1" $ \value ->
    PluginAnalysis
      <$> (value .: "owner" >>= parseSlot)
      <*> value .: "plugin"
      <*> (value .: "document" >>= parseSlot)
      <*> value .: "value"
   where
    parseSlot = withText "plugin analysis slot" $ \raw ->
      case validateSlot raw of
        Left _ -> fail "plugin analysis contains an invalid slot"
        Right slot -> pure slot

analysisSnapshotName :: String
analysisSnapshotName = "tex2ss-plugin-analysis-v1"

ownerPlugins :: PluginPlan -> Slot -> [ContentPlugin]
ownerPlugins plan owner = Map.findWithDefault [] owner (pluginsByOwner plan)

interestedPlugins :: PluginPlan -> Slot -> [ContentPlugin]
interestedPlugins plan document =
  [ plugin
  | plugin <- concat (Map.elems $ pluginsByOwner plan)
  , pluginHasAnalyzer plugin
  , document `elem` pluginSelectedSlots plugin
  ]

ownerAnalysisSlots :: PluginPlan -> Slot -> [Slot]
ownerAnalysisSlots plan owner =
  sort . Set.toList . Set.fromList $
    concatMap pluginSelectedSlots (ownerPlugins plan owner)

pluginDependencyFiles :: PluginPlan -> Slot -> [FilePath]
pluginDependencyFiles plan slot =
  sort . Set.toList . Set.fromList . concatMap pluginFiles $
    ownerPlugins plan slot <> interestedPlugins plan slot

pluginDependencyDirectories :: PluginPlan -> Slot -> [FilePath]
pluginDependencyDirectories plan slot =
  sort . Set.toList . Set.fromList . concatMap pluginWatchDirectories $
    ownerPlugins plan slot <> interestedPlugins plan slot

preparePluginPlan
  :: ProjectPaths
  -> SiteIndex
  -> [Bundle]
  -> IO (Either [Diagnostic] PluginPlan)
preparePluginPlan paths siteIndex visibleBundles = do
  prepared <- traverse prepareOwner visibleBundles
  let problems = concat [items | Left items <- prepared]
  pure $
    if null problems
      then
        Right
          PluginPlan
            { pluginReferencesByOwner =
                Map.fromList
                  [ (bundleSlot bundle, references)
                  | Right (bundle, references, _) <- prepared
                  ]
            , pluginsByOwner =
                Map.fromList
                  [ (bundleSlot bundle, plugins)
                  | Right (bundle, _, plugins) <- prepared
                  ]
            }
      else Left problems
 where
  visibleBySlot = Map.fromList [(bundleSlot bundle, bundle) | bundle <- visibleBundles]

  prepareOwner bundle = do
    expanded <- expandBundleSource (bundleDirectory bundle) (bundleIndexPath bundle)
    case expanded >>= parsePluginReferences (bundleIndexPath bundle) . expandedText of
      Left problems -> pure (Left problems)
      Right references -> do
        plugins <- traverse (prepareOne bundle) (uniquePluginIds references)
        let problems = concat [items | Left items <- plugins]
        pure $
          if null problems
            then Right (bundle, references, [plugin | Right plugin <- plugins])
            else Left problems

  prepareOne bundle selectedId = do
    resolved <- resolvePlugin paths bundle selectedId
    case resolved of
      Left problems -> pure (Left problems)
      Right (directory, entry) -> do
        filesResult <- listPluginFiles directory
        case filesResult of
          Left problems -> pure (Left problems)
          Right files -> do
            inspected <- inspectPlugin siteIndex bundle directory entry
            pure $ do
              (hasAnalyzer, selectedText) <- inspected
              selectedSlots <-
                if hasAnalyzer
                  then validateSelection bundle selectedId selectedText
                  else Right []
              Right
                ContentPlugin
                  { pluginOwner = bundleSlot bundle
                  , pluginId = selectedId
                  , pluginDirectory = directory
                  , pluginEntryPath = entry
                  , pluginFiles = files
                  , pluginWatchDirectories =
                      [ bundleDirectory bundle </> "extension" </> Text.unpack selectedId
                      , projectPlugins paths </> Text.unpack selectedId
                      ]
                  , pluginSelectedSlots = selectedSlots
                  , pluginHasAnalyzer = hasAnalyzer
                  }

  validateSelection bundle selectedId requested = do
    let defaults =
          [ bundleSlot candidate
          | candidate <- visibleBundles
          , isStrictDescendant (bundleSlot bundle) (bundleSlot candidate)
          ]
    slots <-
      case requested of
        Nothing -> Right defaults
        Just rawSlots -> traverse parseRequested rawSlots
    let duplicateSlots = length slots /= Set.size (Set.fromList slots)
        outside =
          [ slot
          | slot <- slots
          , not (isStrictDescendant (bundleSlot bundle) slot)
              || Map.notMember slot visibleBySlot
          ]
    if duplicateSlots
      then
        Left
          [ pluginDiagnostic
              bundle
              selectedId
              "plugin.selection-duplicate"
              "select(ctx) must not return duplicate slots"
          ]
      else
        if null outside
          then Right (sortOn renderSlot slots)
          else
            Left
              [ pluginDiagnostic
                  bundle
                  selectedId
                  "plugin.selection-outside-descendants"
                  ( "select(ctx) may only return visible strict descendants; invalid: "
                      <> Text.intercalate ", " (map renderSlot outside)
                  )
              ]

  parseRequested raw =
    case validateSlot raw of
      Left _ ->
        Left
          [ diagnosticAt
              Error
              "plugin.selection-invalid-slot"
              (projectPlugins paths)
              ("select(ctx) returned an invalid slot: " <> raw)
          ]
      Right slot -> Right slot

uniquePluginIds :: [PluginReference] -> [Text]
uniquePluginIds = map referencePlugin . nubBy samePlugin
 where
  samePlugin left right = referencePlugin left == referencePlugin right

parsePluginReferences :: FilePath -> Text -> Either [Diagnostic] [PluginReference]
parsePluginReferences sourcePath source =
  case foldr collect ([], []) (zip [1 :: Int ..] $ Text.splitOn "\n" source) of
    ([], references) -> Right references
    (problems, _) -> Left problems
 where
  collect (lineNumber, line) (problems, references) =
    case parseReferenceLine line of
      Right Nothing -> (problems, references)
      Right (Just reference) -> (problems, reference : references)
      Left message ->
        ( diagnosticAt
            Error
            "plugin.placeholder-invalid"
            sourcePath
            ("line " <> Text.pack (show lineNumber) <> ": " <> message)
            : problems
        , references
        )

parseReferenceLine :: Text -> Either Text (Maybe PluginReference)
parseReferenceLine line
  | Text.isPrefixOf "%" stripped = Right Nothing
  | not ("\\texssgenerated" `Text.isInfixOf` stripped) = Right Nothing
  | otherwise = do
      afterPluginOpen <- requirePrefix "\\texssgenerated{" stripped
      let (plugin, pluginClosing) = Text.breakOn "}" afterPluginOpen
      afterPlugin <- requirePrefix "}" pluginClosing
      afterFragmentOpen <- requirePrefix "{" afterPlugin
      let (fragment, fragmentClosing) = Text.breakOn "}" afterFragmentOpen
      remainder <- requirePrefix "}" fragmentClosing
      unless (isPortableName plugin && isPortableName fragment) $
        Left "plugin and fragment must match [a-z0-9][a-z0-9_-]*"
      let trailing = Text.strip remainder
      unless (Text.null trailing || Text.isPrefixOf "%" trailing) $
        Left "generated fragments must use a standalone \\texssgenerated{plugin}{fragment} line"
      Right (Just $ PluginReference plugin fragment)
 where
  stripped = Text.strip line
  requirePrefix prefix value =
    maybe
      (Left "generated fragments must use a standalone \\texssgenerated{plugin}{fragment} line")
      Right
      (Text.stripPrefix prefix value)

resolvePlugin
  :: ProjectPaths
  -> Bundle
  -> Text
  -> IO (Either [Diagnostic] (FilePath, FilePath))
resolvePlugin paths bundle selectedId = do
  let relative = Text.unpack selectedId <> "/init.lua"
      localRoot = bundleDirectory bundle </> "extension"
      localDirectory = localRoot </> Text.unpack selectedId
      siteDirectory = projectPlugins paths </> Text.unpack selectedId
      localEntry = localDirectory </> "init.lua"
      siteEntry = siteDirectory </> "init.lua"
  localExists <- doesFileExist localEntry
  if localExists
    then resolve localRoot localDirectory relative
    else do
      siteExists <- doesFileExist siteEntry
      if siteExists
        then resolve (projectPlugins paths) siteDirectory relative
        else
          pure . Left $
            [ pluginDiagnostic
                bundle
                selectedId
                "plugin.not-found"
                "no bundle-local or site plugin directory contains init.lua"
            ]
 where
  resolve root directory relative = do
    entry <- resolveExistingUnder root relative
    pure $ either (Left . (: [])) (\path -> Right (directory, path)) entry

listPluginFiles :: FilePath -> IO (Either [Diagnostic] [FilePath])
listPluginFiles root = do
  result <- try @IOException $ do
    canonicalRoot <- canonicalizePath root
    walk canonicalRoot Set.empty root
  pure $
    case result of
      Left exception ->
        Left [diagnosticAt Error "plugin.directory-io" root (Text.pack $ show exception)]
      Right value -> value
 where
  walk canonicalRoot seen directory = do
    canonicalDirectory <- canonicalizePath directory
    if not (inside canonicalRoot canonicalDirectory)
      then pure $ Left [diagnosticAt Error "plugin.path-escape" directory "plugin directory escapes its root"]
      else
        if Set.member canonicalDirectory seen
          then pure $ Left [diagnosticAt Error "plugin.directory-cycle" directory "plugin directory contains a link cycle"]
          else do
            names <- sort <$> listDirectory directory
            values <- forM names $ \name -> do
              let path = directory </> name
              canonicalPath <- canonicalizePath path
              if not (inside canonicalRoot canonicalPath)
                then pure $ Left [diagnosticAt Error "plugin.path-escape" path "plugin file escapes its root"]
                else do
                  isDirectory <- doesDirectoryExist path
                  isFile <- doesFileExist path
                  if isDirectory
                    then walk canonicalRoot (Set.insert canonicalDirectory seen) path
                    else pure $ if isFile then Right [canonicalPath] else Right []
            let problems = concat [items | Left items <- values]
            pure $ if null problems then Right (concat [items | Right items <- values]) else Left problems

  inside canonicalRoot candidate =
    let relative = makeRelative canonicalRoot candidate
     in relative == "."
          || (not (isAbsolute relative) && not (".." `elem` splitDirectories relative))

inspectPlugin
  :: SiteIndex
  -> Bundle
  -> FilePath
  -> FilePath
  -> IO (Either [Diagnostic] (Bool, Maybe [Text]))
inspectPlugin siteIndex bundle directory entry = do
  operation <- try @PandocError . runIO $ do
    result <- runLua $ do
      setGlobals [PANDOC_SCRIPT_FILE entry]
      configurePluginEnvironment directory
      oldTop <- Lua.gettop
      loadPluginTable entry oldTop
      generateType <- Lua.getfield Lua.top "generate"
      Lua.pop 1
      unless (generateType == Lua.TypeFunction) $
        Lua.failLua "plugin must return a table containing generate(ctx)"
      analyzeType <- Lua.getfield Lua.top "analyze"
      Lua.pop 1
      unless (analyzeType `elem` [Lua.TypeFunction, Lua.TypeNil]) $
        Lua.failLua "plugin analyze field must be a function or nil"
      selectType <- Lua.getfield Lua.top "select"
      selected <-
        case selectType of
          Lua.TypeNil -> Lua.pop 1 >> pure Nothing
          Lua.TypeFunction -> do
            Lua.pushViaJSON (baseContext siteIndex bundle)
            Lua.callTrace 1 1
            Just <$> Lua.forcePeek (Lua.peekList Lua.peekText Lua.top `Lua.lastly` Lua.pop 1)
          _ -> Lua.pop 1 >> Lua.failLua "plugin select field must be a function or nil"
      when (selectType == Lua.TypeFunction && analyzeType /= Lua.TypeFunction) $
        Lua.failLua "plugin select(ctx) requires analyze(document, ctx)"
      Lua.settop oldTop
      pure (analyzeType == Lua.TypeFunction, selected)
    either throwError pure result
  pure (flattenPluginResult bundle entry "loading" operation)

runPluginGenerators
  :: SiteIndex
  -> PluginPlan
  -> [PluginAnalysis]
  -> Bundle
  -> IO (Either [Diagnostic] (Map Text PluginResult))
runPluginGenerators siteIndex plan analyses bundle = do
  generated <- traverse runOne (ownerPlugins plan $ bundleSlot bundle)
  let problems = concat [items | Left items <- generated]
  pure $
    if null problems
      then Right (Map.fromList [(pluginId plugin, result) | Right (plugin, result) <- generated])
      else Left problems
 where
  runOne plugin = do
    operation <- try @PandocError . runIO $ do
      result <- runLua $ do
        setGlobals [PANDOC_SCRIPT_FILE $ pluginEntryPath plugin]
        configurePluginEnvironment (pluginDirectory plugin)
        oldTop <- Lua.gettop
        loadPluginTable (pluginEntryPath plugin) oldTop
        Lua.getfield Lua.top "generate" >>= \case
          Lua.TypeFunction -> do
            Lua.pushViaJSON (generationContext siteIndex bundle plugin analyses)
            Lua.callTrace 1 1
            value <- Lua.forcePeek (PluginResult <$> Lua.peekMap Lua.peekText peekGeneratedContent Lua.top `Lua.lastly` Lua.pop 1)
            Lua.settop oldTop
            pure value
          _ -> Lua.pop 1 >> Lua.failLua "plugin must define generate(ctx)"
      either throwError pure result
    pure $ do
      result <- flattenPluginResult bundle (pluginEntryPath plugin) "generating" operation
      validated <- validatePluginResult (pluginEntryPath plugin) result
      Right (plugin, validated)

runPluginAnalyzers
  :: SiteIndex
  -> PluginPlan
  -> Bundle
  -> Pandoc
  -> IO (Either [Diagnostic] [PluginAnalysis])
runPluginAnalyzers siteIndex plan bundle document = do
  analyzed <- traverse runOne (interestedPlugins plan $ bundleSlot bundle)
  let problems = concat [items | Left items <- analyzed]
  pure $
    if null problems
      then Right (catMaybes [value | Right value <- analyzed])
      else Left problems
 where
  runOne plugin = do
    operation <- try @PandocError . runIO $ do
      result <- runLua $ do
        setGlobals [PANDOC_SCRIPT_FILE $ pluginEntryPath plugin, PANDOC_DOCUMENT document]
        configurePluginEnvironment (pluginDirectory plugin)
        oldTop <- Lua.gettop
        loadPluginTable (pluginEntryPath plugin) oldTop
        Lua.getfield Lua.top "analyze" >>= \case
          Lua.TypeFunction -> do
            _ <- Lua.getglobal "PANDOC_DOCUMENT"
            Lua.pushViaJSON (analysisContext siteIndex bundle plugin)
            Lua.callTrace 2 1
            valueType <- Lua.ltype Lua.top
            value <-
              if valueType == Lua.TypeNil
                then Lua.pop 1 >> pure Nothing
                else Just <$> Lua.forcePeek (Lua.peekViaJSON Lua.top `Lua.lastly` Lua.pop 1)
            Lua.settop oldTop
            pure value
          _ -> Lua.pop 1 >> Lua.failLua "selected plugin must define analyze(document, ctx)"
      either throwError pure result
    pure $ do
      value <- flattenPluginResult bundle (pluginEntryPath plugin) "analyzing" operation
      traverse (makeAnalysis plugin) value

  makeAnalysis plugin value =
    let analysis =
          PluginAnalysis
            { analysisOwner = pluginOwner plugin
            , analysisPlugin = pluginId plugin
            , analysisDocument = bundleSlot bundle
            , analysisValue = value
            }
     in if LazyByteString.length (encode value) <= fromIntegral maximumAnalysisBytes
          then Right analysis
          else
            Left
              [ diagnosticAt
                  Error
                  "plugin.analysis-too-large"
                  (pluginEntryPath plugin)
                  "analyze(document, ctx) result exceeds the 1 MiB encoded limit"
              ]

assembleGeneratedSource
  :: FilePath
  -> Map Text PluginResult
  -> Text
  -> Either [Diagnostic] AssembledSource
assembleGeneratedSource sourcePath results source = do
  replaced <- traverse replaceLine $ Text.splitOn "\n" source
  pure
    AssembledSource
      { assembledText = Text.intercalate "\n" (map fst replaced)
      , assembledPandocFragments = Map.unions (map snd replaced)
      }
 where
  replaceLine line =
    case parseReferenceLine line of
      Right Nothing -> Right (line, Map.empty)
      Left message -> Left [diagnosticAt Error "plugin.placeholder-invalid" sourcePath message]
      Right (Just reference) ->
        case Map.lookup (referencePlugin reference) results of
          Nothing ->
            Left [diagnosticAt Error "plugin.result-missing" sourcePath ("plugin was not executed: " <> referencePlugin reference)]
          Just result ->
            case Map.lookup (referenceFragment reference) (generatedFragments result) of
              Nothing ->
                Left
                  [ diagnosticAt
                      Error
                      "plugin.fragment-missing"
                      sourcePath
                      ( "plugin "
                          <> referencePlugin reference
                          <> " did not return fragment "
                          <> referenceFragment reference
                      )
                  ]
              Just (DeferredLaTeXBlock body) -> Right (body, Map.empty)
              Just (PandocBlocks blocks) ->
                let marker = pandocFragmentMarker reference
                 in Right ("\n" <> marker <> "\n", Map.singleton marker blocks)

pandocFragmentMarker :: PluginReference -> Text
pandocFragmentMarker reference =
  "texssgeneratedpandocblocks"
    <> Text.concatMap encodeCharacter (referencePlugin reference <> ":" <> referenceFragment reference)
 where
  encodeCharacter = Text.pack . (<> "z") . (`showHex` "") . ord

peekGeneratedContent :: Lua.LuaError error => Lua.Peeker error GeneratedContent
peekGeneratedContent index = do
  kind <- Lua.peekFieldRaw Lua.peekText "type" index
  case kind of
    "deferred_latex" -> DeferredLaTeXBlock <$> Lua.peekFieldRaw Lua.peekText "value" index
    "pandoc_blocks" ->
      PandocBlocks
        <$> Lua.peekFieldRaw
          (Lua.peekList $ Lua.safepeek @Block)
          "blocks"
          index
    _ -> Lua.failPeek (ByteString.pack "generated fragment type must come from tex2ss.latex or tex2ss.blocks")

validatePluginResult :: FilePath -> PluginResult -> Either [Diagnostic] PluginResult
validatePluginResult scriptPath result =
  case nameProblems <> rawProblems of
    [] -> Right result
    problems -> Left problems
 where
  nameProblems =
    [ diagnosticAt Error "plugin.fragment-name-invalid" scriptPath ("fragment name is not portable: " <> name)
    | name <- Map.keys (generatedFragments result)
    , not (isPortableName name)
    ]
  rawProblems =
    [ diagnosticAt
        Error
        "plugin.pandoc-blocks-raw"
        scriptPath
        ( "pandoc_blocks fragment "
            <> name
            <> " contains target-specific raw content: "
            <> kind
            <> "["
            <> format
            <> "] "
            <> Text.take 100 (Text.unwords $ Text.words body)
        )
    | (name, PandocBlocks blocks) <- Map.toAscList (generatedFragments result)
    , (kind, format, body) <- generatedRawNodes blocks
    ]

generatedRawNodes :: [Block] -> [(Text, Text, Text)]
generatedRawNodes blocks = query blockRaw blocks <> query inlineRaw blocks
 where
  blockRaw = \case
    RawBlock (Format format) body -> [("block", format, body)]
    _ -> []
  inlineRaw = \case
    RawInline (Format format) body -> [("inline", format, body)]
    _ -> []

configurePluginEnvironment :: Lua.LuaError error => FilePath -> Lua.LuaE error ()
configurePluginEnvironment directory = do
  status <- Lua.dostring tex2ssModule
  when (status /= Lua.OK) Lua.throwErrorAsException
  _ <- Lua.getglobal "package"
  _ <- Lua.getfield Lua.top "path"
  inherited <- Lua.forcePeek (Lua.peekText Lua.top)
  Lua.pop 1
  let root = Text.replace "\\" "/" (Text.pack directory)
      prefix = root <> "/?.lua;" <> root <> "/?/init.lua;"
  Lua.pushText (prefix <> inherited)
  Lua.setfield (Lua.nth 2) "path"
  Lua.pop 1

tex2ssModule :: ByteString.ByteString
tex2ssModule =
  ByteString.unlines
    [ "package.preload['tex2ss'] = function()"
    , "  return {"
    , "    latex = function(value)"
    , "      assert(type(value) == 'string', 'tex2ss.latex expects a string')"
    , "      return { type = 'deferred_latex', value = value }"
    , "    end,"
    , "    blocks = function(value)"
    , "      return { type = 'pandoc_blocks', blocks = value }"
    , "    end"
    , "  }"
    , "end"
    ]

loadPluginTable :: Lua.LuaError error => FilePath -> Lua.StackIndex -> Lua.LuaE error ()
loadPluginTable entry oldTop = do
  Lua.dofileTrace (Just entry) >>= \case
    Lua.OK -> pure ()
    _ -> Lua.throwErrorAsException
  newTop <- Lua.gettop
  unless (newTop == oldTop + 1) $
    Lua.failLua "plugin entry must return exactly one hook table"
  Lua.ltype Lua.top >>= \case
    Lua.TypeTable -> pure ()
    _ -> Lua.failLua "plugin entry must return a hook table"

baseContext :: SiteIndex -> Bundle -> Value
baseContext siteIndex bundle =
  object
    [ "owner" .= ownerPage siteIndex bundle
    , "site_index" .= object ["pages" .= Map.elems (sitePages siteIndex)]
    ]

generationContext :: SiteIndex -> Bundle -> ContentPlugin -> [PluginAnalysis] -> Value
generationContext siteIndex bundle plugin analyses =
  object
    [ "owner" .= ownerPage siteIndex bundle
    , "site_index" .= object ["pages" .= Map.elems (sitePages siteIndex)]
    , "analysis"
        .= [ object
              [ "document" .= analysisDocument value
              , "value" .= analysisValue value
              ]
           | value <- sortOn (renderSlot . analysisDocument) analyses
           , analysisOwner value == pluginOwner plugin
           , analysisPlugin value == pluginId plugin
           ]
    ]

analysisContext :: SiteIndex -> Bundle -> ContentPlugin -> Value
analysisContext siteIndex bundle plugin =
  object
    [ "owner" .= Map.lookup (pluginOwner plugin) (sitePages siteIndex)
    , "document" .= ownerPage siteIndex bundle
    , "site_index" .= object ["pages" .= Map.elems (sitePages siteIndex)]
    ]

ownerPage :: SiteIndex -> Bundle -> Maybe PageRef
ownerPage siteIndex bundle = Map.lookup (bundleSlot bundle) (sitePages siteIndex)

flattenPluginResult
  :: Bundle
  -> FilePath
  -> Text
  -> Either PandocError (Either PandocError value)
  -> Either [Diagnostic] value
flattenPluginResult bundle entry stage operation =
  case operation of
    Left problem -> Left [pluginFailure bundle entry stage problem]
    Right (Left problem) -> Left [pluginFailure bundle entry stage problem]
    Right (Right value) -> Right value

pluginFailure :: Bundle -> FilePath -> Text -> PandocError -> Diagnostic
pluginFailure bundle entry stage problem =
  diagnosticAt
    Error
    "plugin.failed"
    entry
    ( "while "
        <> stage
        <> " for "
        <> Text.pack (bundleIndexPath bundle)
        <> ": "
        <> renderError problem
    )

pluginDiagnostic :: Bundle -> Text -> Text -> Text -> Diagnostic
pluginDiagnostic bundle selectedId code message =
  diagnosticAt
    Error
    code
    (bundleIndexPath bundle)
    ("plugin " <> selectedId <> ": " <> message)

isStrictDescendant :: Slot -> Slot -> Bool
isStrictDescendant (Slot ancestor) (Slot candidate) =
  ancestor /= candidate && ancestor `isPrefixOf` candidate

maximumAnalysisBytes :: Int
maximumAnalysisBytes = 1024 * 1024
