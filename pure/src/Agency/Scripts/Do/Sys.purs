-- | Sys: injected Node capability surface. One FFI module owns every
-- | effect the agency-do core performs (subprocess, fs, time, env, path,
-- | argv, exit). Both front ends (OMP tool adapter, CLI test adapter)
-- | consume the compiled core through this seam only.
module Agency.Scripts.Do.Sys
  ( ExecResult(..)
  , exec
  , execInherit
  , execInheritInput
  , readUtf8
  , writeUtf8
  , rename
  , exists
  , isDir
  , nowIso
  , getEnv
  , argv
  , exit
  , cwd
  , stdoutWrite
  , stderrWrite
  , realpath
  , isoToEpoch
) where

import Prelude

import Effect (Effect)

type ExecResult =
  { code :: Int
  , stdout :: String
  , stderr :: String
  }

foreign import execImpl ∷ String → Array String → Effect ExecResult

exec ∷ String → Array String → Effect ExecResult
exec = execImpl

foreign import execInherit ∷ String → Array String → Effect Int

foreign import execInheritInput ∷ String → Array String → String → Effect Int

foreign import readUtf8 ∷ String → Effect String

foreign import writeUtf8 ∷ String → String → Effect Unit

foreign import rename ∷ String → String → Effect Unit

foreign import existsImpl ∷ String → Effect Boolean

exists ∷ String → Effect Boolean
exists = existsImpl

foreign import isDir ∷ String → Effect Boolean

foreign import nowIso ∷ Effect String

foreign import getEnv ∷ String → Effect String

foreign import argv ∷ Effect (Array String)

foreign import exit ∷ Int → Effect Unit

foreign import cwd ∷ Effect String

foreign import stdoutWrite ∷ String → Effect Unit

foreign import stderrWrite ∷ String → Effect Unit

foreign import isoToEpoch ∷ String → Effect Int
foreign import realpath ∷ String → Effect String