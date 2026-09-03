module Agency.Scripts.Do.Outcome
  ( OpOutput(..)
  , OpOutcome
  , success
  , withStdout
  , captured
  , failure
  , passthrough
  , append
  ) where

import Prelude

import Agency.Scripts.Do.Sys as Sys

-- | Captured output is rendered by the adapter; passthrough output has already
-- | been connected to the adapter's streams by its child process.
data OpOutput
  = Captured
      { stdout :: String
      , stderr :: String
      , stderrFirst :: Boolean
      }
  | Passthrough

-- | Result returned by a core operation. The output sum keeps inherited
-- | streams and adapter-rendered streams mutually exclusive.
type OpOutcome =
  { exit :: Int
  , output :: OpOutput
  }

-- | A successful operation with no output.
success :: OpOutcome
success = { exit: 0, output: Captured { stdout: "", stderr: "", stderrFirst: false } }

-- | A successful operation with adapter-rendered standard output.
withStdout :: String -> OpOutcome
withStdout stdout = { exit: 0, output: Captured { stdout, stderr: "", stderrFirst: false } }

-- | Convert captured subprocess output into an adapter-rendered outcome.
captured :: Sys.ExecResult -> OpOutcome
captured result =
  { exit: result.code
  , output: Captured
      { stdout: result.stdout
      , stderr: result.stderr
      , stderrFirst: false
      }
  }

-- | A failure whose message belongs on stderr.
failure :: Int -> String -> OpOutcome
failure code message =
  { exit: code
  , output: Captured { stdout: "", stderr: message, stderrFirst: true }
  }

-- | A child process has inherited the adapter's streams and already rendered.
passthrough :: Int -> OpOutcome
passthrough code = { exit: code, output: Passthrough }

-- | Concatenate sequential outcomes while retaining stream ordering metadata.
append :: OpOutcome -> OpOutcome -> OpOutcome
append first second =
  { exit: if first.exit /= 0 then first.exit else second.exit
  , output: appendOutput first.output second.output
  }

appendOutput :: OpOutput -> OpOutput -> OpOutput
appendOutput first second = case first, second of
  Passthrough, Passthrough -> Passthrough
  Captured firstValue, Captured secondValue ->
    Captured
      { stdout: firstValue.stdout <> secondValue.stdout
      , stderr: firstValue.stderr <> secondValue.stderr
      , stderrFirst: firstValue.stderrFirst || (firstValue.stdout == "" && secondValue.stderrFirst)
      }
  Captured firstValue, Passthrough -> Captured firstValue
  Passthrough, Captured secondValue -> Captured secondValue
