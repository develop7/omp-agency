module Agency.Scripts.Do.Context
  ( WorkflowContext
  , stateCorruptError
  , stateFile
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

-- | The workflow state file's name, owned here so every construction site
-- agrees on which artifact is state rather than repo work.
stateFile :: String
stateFile = ".do-results.json"

-- | The shared corrupt-state error shape: which reader failed, the underlying
-- read error, and what to do about it.
stateCorruptError :: String -> String -> String -> String
stateCorruptError label error remedy = label <> ": " <> stateFile <> " is corrupt or unreadable — " <> error <> "; " <> remedy

-- | Resolve the state file below the run's working directory.
statePath :: WorkflowContext -> String
statePath context = context.stateDir <> "/" <> stateFile
