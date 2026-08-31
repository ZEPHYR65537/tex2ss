{-# LANGUAGE OverloadedStrings #-}

module PathsSpec (tests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Tex2ss.Paths (validateRelativePath, validateSlot)
import Tex2ss.Types (Slot (..))

tests :: TestTree
tests =
  testGroup
    "paths"
    [ testCase "accepts portable slot segments" $
        validateSlot "posts/hello-world" @?= Right (Slot ["posts", "hello-world"])
    , testCase "rejects uppercase and traversal" $ do
        assertBool "uppercase should fail" (either (const True) (const False) $ validateSlot "Posts")
        assertBool "traversal should fail" (either (const True) (const False) $ validateSlot "posts/../secret")
    , testCase "rejects parent paths" $
        assertBool "parent path should fail" (either (const True) (const False) $ validateRelativePath "../secret")
    ]
