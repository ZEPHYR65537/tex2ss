module Main (main) where

import qualified BuildSpec
import qualified ConfigSpec
import qualified DiscoverySpec
import qualified DeploySpec
import qualified IncludeSpec
import qualified PandocSpec
import qualified PathsSpec
import qualified PdfSpec
import qualified PluginSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "tex2ss"
      [ BuildSpec.tests
      , ConfigSpec.tests
      , DeploySpec.tests
      , DiscoverySpec.tests
      , IncludeSpec.tests
      , PandocSpec.tests
      , PathsSpec.tests
      , PdfSpec.tests
      , PluginSpec.tests
      ]
