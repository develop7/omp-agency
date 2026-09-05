module Agency.Scripts.Do.Args
  ( RequiredArg
  , requiredNonEmpty
  , nonEmpty
  , startsWith
  ) where
import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String.CodeUnits (length, take)

-- | A required command-line value and the arguments that follow it.
type RequiredArg =
  { value :: String
  , rest :: Array String
  }

-- | Read one argument and reject both a missing and an empty value.
requiredNonEmpty :: Array String -> Maybe RequiredArg
requiredNonEmpty values = case Array.uncons values of
  Just { head: value, tail: rest } | value /= "" -> Just { value, rest }
  _ -> Nothing

-- | Keep only non-empty environment or optional argument values.
nonEmpty :: String -> Maybe String
nonEmpty value = if value == "" then Nothing else Just value

-- | Test a string prefix using the strings package's code-unit primitives.
startsWith :: String -> String -> Boolean
startsWith prefix value = take (length prefix) value == prefix


