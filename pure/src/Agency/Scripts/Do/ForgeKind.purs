module Agency.Scripts.Do.ForgeKind
  ( ForgeKind(..)
  ) where

import Prelude

-- | Remote forge families recognized by the workflow.
data ForgeKind = Github | Bitbucket | Unknown

derive instance eqForgeKind :: Eq ForgeKind
