module Main (main) where

import qualified BuildSpec
import qualified ConfigSpec
import qualified DiscoverySpec
import qualified IncludeSpec
import qualified PandocSpec
import qualified PathsSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "tex2ss"
      [ BuildSpec.tests
      , ConfigSpec.tests
      , DiscoverySpec.tests
      , IncludeSpec.tests
      , PandocSpec.tests
      , PathsSpec.tests
      ]
