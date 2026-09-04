module Agency.Scripts.Do.Context
  ( WorkflowContext
  , statePath
  ) where

import Prelude

import Data.Maybe (Maybe)

import Agency.Scripts.Do.ForgeKind as ForgeKind
import Agency.Scripts.Do.VcsKind as VcsKind
-- | Immutable capabilities and resolved inputs shared by one workflow run.
-- | Resolution happens in the adapter; providers only consume this value.
-- | captureOutput controls subprocess providers; the Nickel bridge always
-- | captures its subprocess output because it communicates over stdin/stdout.
type WorkflowContext =
  { stateDir :: String
  , vcs :: VcsKind.VcsKind
  , forge :: ForgeKind.ForgeKind
  , base :: Maybe String
  , vcsOverride :: Maybe String
  , forgeOverride :: Maybe String
  , captureOutput :: Boolean
  }

-- | Resolve the state file below the run's working directory.
statePath :: WorkflowContext -> String
statePath context = context.stateDir <> "/.do-results.json"
