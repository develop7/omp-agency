-- | Executable names used by the workflow's process boundary.
-- | Keeping these names in one module leaves one indirection point for future
-- | path overrides, instrumentation, or test fakes.
module Agency.Scripts.Do.Binaries
  ( git
  , jj
  , gh
  , nickel
  ) where


-- | Git executable name.
git :: String
git = "git"

-- | Jujutsu executable name.
jj :: String
jj = "jj"

-- | GitHub CLI executable name.
gh :: String
gh = "gh"

-- | Nickel executable name.
nickel :: String
nickel = "nickel"
