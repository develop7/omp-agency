module Agency.Scripts.Do.Context
  ( WorkflowContext
  , stateCorruptError
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
  , stateRoot :: Maybe String
  , vcs :: VcsKind.VcsKind
  , forge :: ForgeKind.ForgeKind
  , base :: Maybe String
  , vcsOverride :: Maybe String
  , forgeOverride :: Maybe String
  , captureOutput :: Boolean
  }

-- | The shared corrupt-state error shape: which reader failed, the underlying
-- read error, and what to do about it. The subject names the actual store,
-- never a working-tree file that the current backend does not write.
stateCorruptError :: String -> String -> String -> String
stateCorruptError label error remedy = label <> ": workflow state store is corrupt or unreadable — " <> error <> "; " <> remedy
