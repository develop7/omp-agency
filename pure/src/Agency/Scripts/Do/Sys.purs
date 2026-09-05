-- | Sys: the small Node capability surface used by the agency-do core.
-- | Standard filesystem, process, and child-process behavior comes from the
-- | typed node-* packages; only clock formatting and bundle location need FFI.
module Agency.Scripts.Do.Sys
  ( ExecResult
  , InheritResult
  , exec
  , execInput
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
  , bundleDir
  , isoToEpoch
  , isCanonicalIso
  , uniqueTempPath
  ) where
import Prelude

import Data.Array as Array
import Data.DateTime.Instant as Instant
import Data.Either (Either(..))
import Data.Int (floor)
import Data.JSDate as JSDate
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toMaybe)
import Data.Time.Duration (Milliseconds(..))
import Effect (Effect)
import Effect.Exception (try)
import Node.Buffer as Buffer
import Node.ChildProcess.Types (inherit, pipe)
import Node.Encoding (Encoding(..))
import Node.FS.Stats as Stats
import Node.FS.Sync as FSSync
import Node.Process as Process
import Node.Stream as Stream
import Node.UnsafeChildProcess.Unsafe as Child
import Node.Errors.SystemError as SystemError

-- | Captured output and the exit status of a synchronous child process.
type ExecResult =
  { code :: Int
  , stdout :: String
  , stderr :: String
  }

-- | Status and spawn diagnostics for a child whose streams are inherited.
type InheritResult =
  { code :: Int
  , error :: Maybe String
  }

-- | Run a command with UTF-8 captured output. A missing executable is a
-- | normal command failure, represented as status 1 and its system message.
exec :: String -> Array String -> Effect ExecResult
exec command args = do
  result <- Child.spawnSync' command args
    { encoding: "utf8"
    , maxBuffer: 64.0 * 1024.0 * 1024.0
    }
  let stdout = Child.unsafeSOBToString result.stdout
      stderr = Child.unsafeSOBToString result.stderr
      code = fromMaybe 1 (toMaybe result.status)
  case toMaybe result.error of
    Nothing -> pure { code, stdout, stderr }
    Just error -> pure
      { code: 1
      , stdout
      , stderr: if stderr == "" then SystemError.message error else stderr
      }

-- | Run a command with supplied text on stdin and captured output.
execInput :: String -> Array String -> String -> Effect ExecResult
execInput command args input = do
  inputBuffer <- Buffer.fromString input UTF8
  result <- Child.spawnSync' command args
    { input: inputBuffer
    , encoding: "utf8"
    , maxBuffer: 64.0 * 1024.0 * 1024.0
    }
  let stdout = Child.unsafeSOBToString result.stdout
      stderr = Child.unsafeSOBToString result.stderr
      code = fromMaybe 1 (toMaybe result.status)
  case toMaybe result.error of
    Nothing -> pure { code, stdout, stderr }
    Just error -> pure
      { code: 1
      , stdout
      , stderr: if stderr == "" then SystemError.message error else stderr
      }

-- | Run a command with all child streams inherited. A spawn failure is
-- | returned separately because Node does not write it to inherited stderr.
execInherit :: String -> Array String -> Effect InheritResult
execInherit command args = do
  result <- Child.spawnSync' command args
    { stdio: [ inherit, inherit, inherit ] }
  pure
    { code: fromMaybe 1 (toMaybe result.status)
    , error: SystemError.message <$> toMaybe result.error
    }

-- | Run a command with supplied text on stdin and inherited output streams.
execInheritInput :: String -> Array String -> String -> Effect InheritResult
execInheritInput command args input = do
  inputBuffer <- Buffer.fromString input UTF8
  result <- Child.spawnSync' command args
    { input: inputBuffer
    , stdio: [ pipe, inherit, inherit ]
    }
  pure
    { code: fromMaybe 1 (toMaybe result.status)
    , error: SystemError.message <$> toMaybe result.error
    }

readUtf8 :: String -> Effect String
readUtf8 = FSSync.readTextFile UTF8

writeUtf8 :: String -> String -> Effect Unit
writeUtf8 path value = FSSync.writeTextFile UTF8 path value

rename :: String -> String -> Effect Unit
rename = FSSync.rename

exists :: String -> Effect Boolean
exists = FSSync.exists

-- | Missing or unreadable paths are not directories. Detection deliberately
-- | treats those paths as absent so the VCS precedence can continue.
isDir :: String -> Effect Boolean
isDir path = do
  result <- try (FSSync.stat path)
  pure case result of
    Left _ -> false
    Right stats -> Stats.isDirectory stats

-- | Format current time exactly as the legacy shell protocol requires.
foreign import nowIso :: Effect String

getEnv :: String -> Effect String
getEnv key = fromMaybe "" <$> Process.lookupEnv key

argv :: Effect (Array String)
argv = Array.drop 2 <$> Process.argv
exit :: Int -> Effect Unit
exit code = Process.exit' code

cwd :: Effect String
cwd = Process.cwd

stdoutWrite :: String -> Effect Unit
stdoutWrite value = do
  _ <- Stream.writeString Process.stdout UTF8 value
  pure unit

stderrWrite :: String -> Effect Unit
stderrWrite value = do
  _ <- Stream.writeString Process.stderr UTF8 value
  pure unit

realpath :: String -> Effect String
realpath = FSSync.realpath

-- | Directory containing the executing bundle, independent of process cwd.
foreign import bundleDir :: Effect String

-- | Produce a same-directory private staging name for an atomic rename.
foreign import uniqueTempPath :: String -> Effect String

-- | Convert an exact UTC-second ISO timestamp to epoch seconds.
isoToEpoch :: String -> Effect (Either String Int)
isoToEpoch value =
  if not (isCanonicalIso value) then pure (Left ("invalid timestamp '" <> value <> "'"))
  else do
    parsed <- JSDate.parse value
    pure case JSDate.toInstant parsed of
      Nothing -> Left ("invalid timestamp '" <> value <> "'")
      Just instant ->
        let Milliseconds milliseconds = Instant.unInstant instant
        in Right (floor (milliseconds / 1000.0))

foreign import isCanonicalIso :: String -> Boolean
