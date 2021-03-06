module Reporting.Warning where

import qualified AST.Module as Module

import qualified Reporting.Annotation as A

import qualified Reporting.Warning.CheckMatch as CheckMatch


data Warning
    = UnusedImport Module.Name
    | MissingTypeAnnotation String
    | MatchWarning CheckMatch.Warning

-- TO STRING

toString :: A.Located Warning -> String
toString (A.A region warning) =
  case warning of
    _ -> error "Warning.toString" region


-- TO JSON

toJson :: A.Located Warning -> String
toJson (A.A region warning) =
  case warning of
    _ -> error "Warning.toJson" region

