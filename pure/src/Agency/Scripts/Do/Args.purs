module Agency.Scripts.Do.Args
  ( RequiredArg
  , requiredNonEmpty
  , nonEmpty
  , startsWith
  , entryPoints
  , workflowSteps
  , isEntryPoint
  , isWorkflowStep
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

-- | Closed workflow entry points accepted by --from and cli_seed.
entryPoints :: Array String
entryPoints = [ "default", "followup", "post-implement", "polish", "ci-only" ]

-- | Closed step vocabulary persisted by the driver and result recorder.
workflowSteps :: Array String
workflowSteps =
  [ "sync", "research", "plan-approval", "branch", "implement", "check"
  , "docs", "fmt", "commit", "hickey-lowy", "police", "test", "create-pr"
  , "ci", "evidence", "done"
  ]

-- | Whether a value is a supported workflow re-entry point.
isEntryPoint :: String -> Boolean
isEntryPoint value = Array.elem value entryPoints

-- | Whether a value is a workflow step that may be recorded.
isWorkflowStep :: String -> Boolean
isWorkflowStep value = Array.elem value workflowSteps
