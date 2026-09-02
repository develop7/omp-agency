module Agency.Scripts.Do.VcsKind
  ( VcsKind(..)
  ) where

import Prelude

-- | VCS implementations understood by the workflow.
data VcsKind = Git | Jj | Unknown

derive instance eqVcsKind :: Eq VcsKind
