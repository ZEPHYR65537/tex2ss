{-# LANGUAGE OverloadedStrings #-}

module Tex2ss.Diagnostics
  ( Diagnostic (..)
  , Severity (..)
  , diagnostic
  , diagnosticAt
  , hasErrors
  , renderDiagnostic
  , renderDiagnostics
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

data Severity = Error | Warning
  deriving stock (Eq, Ord, Show)

data Diagnostic = Diagnostic
  { diagnosticSeverity :: Severity
  , diagnosticCode :: Text
  , diagnosticPath :: Maybe FilePath
  , diagnosticMessage :: Text
  , diagnosticHint :: Maybe Text
  }
  deriving stock (Eq, Show)

diagnostic :: Severity -> Text -> Text -> Diagnostic
diagnostic severity code message =
  Diagnostic severity code Nothing message Nothing

diagnosticAt :: Severity -> Text -> FilePath -> Text -> Diagnostic
diagnosticAt severity code path message =
  Diagnostic severity code (Just path) message Nothing

hasErrors :: [Diagnostic] -> Bool
hasErrors = any ((== Error) . diagnosticSeverity)

renderDiagnostic :: Diagnostic -> Text
renderDiagnostic item =
  Text.concat
    [ severityText (diagnosticSeverity item)
    , "["
    , diagnosticCode item
    , "]"
    , maybe "" (\path -> " " <> Text.pack path <> ":") (diagnosticPath item)
    , " "
    , diagnosticMessage item
    , maybe "" ("\n  hint: " <>) (diagnosticHint item)
    ]
 where
  severityText Error = "error"
  severityText Warning = "warning"

renderDiagnostics :: [Diagnostic] -> Text
renderDiagnostics = Text.unlines . map renderDiagnostic
