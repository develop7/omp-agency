module Agency.Scripts.Do.DoneTest (run) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..))
import Data.String.CodeUnits (contains)
import Effect (Effect)
import Effect.Console as Console

import Agency.Scripts.Do.DoneSummary as DoneSummary
import Agency.Scripts.Do.Results as Results
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys

assert :: String -> Boolean -> Effect Unit
assert label condition =
  if condition then pure unit
  else do
    Console.error ("FAIL: " <> label)
    Sys.exit 1

run :: Effect Unit
run = do
  assert "seconds duration format" (DoneSummary.fmtDur 12 == "12s")
  assert "minutes duration format" (DoneSummary.fmtDur 75 == "1m 15s")
  let state =
        (State.initState "2024-01-01T00:00:00Z")
          { steps =
              [ { name: "compile"
                , status: State.StepPassed
                , verification: "ok"
                , startedAt: "2024-01-01T00:00:00Z"
                , completedAt: "2024-01-01T00:00:08Z"
                , reason: Nothing
                }
              , { name: "slow-check"
                , status: State.StepPassed
                , verification: "all | good"
                , startedAt: "2024-01-01T00:00:08Z"
                , completedAt: "2024-01-01T00:00:20Z"
                , reason: Nothing
                }
              , { name: "optional"
                , status: State.StepSkipped
                , verification: "not run"
                , startedAt: "2024-01-01T00:00:20Z"
                , completedAt: "2024-01-01T00:00:20Z"
                , reason: Just "not needed"
                }
              ]
          }
  rendered <- DoneSummary.render state 20
  assert "markdown table header" (contains (Pattern "| Step | Status | Duration | Verification |") rendered)
  assert "dominant step duration is bold" (contains (Pattern "| slow-check | ✓ | **12s** | all \\| good |") rendered)
  assert "facts include total" (contains (Pattern "totalSeconds=20") rendered)
  badSummary <- DoneSummary.compute (state { steps = map (\step -> step { startedAt = "not-a-date" }) state.steps })
  case badSummary of
    Left error -> assert "malformed timestamp is reported" (contains (Pattern "not-a-date") error)
    Right _ -> assert "malformed timestamp is rejected" false
  inverted <- Results.validInterval "2024-01-01T00:00:01Z" "2024-01-01T00:00:00Z"
  case inverted of
    Left error -> assert "inverted timestamps are rejected before recording" (contains (Pattern "precedes") error)
    Right _ -> assert "inverted timestamps are rejected before recording" false
  let goodCi = "local=passed remote=none head=abc123"
  case Results.ciVerification "ci" "passed" goodCi of
    Right _ -> assert "ci accepts structured facts" true
    Left error -> do
      Console.error ("FAIL: ci accepts structured facts: " <> error)
      Sys.exit 1
  case Results.ciVerification "ci" "passed" "local=passed remote=none" of
    Left error -> assert "ci without head is rejected" (contains (Pattern "head=") error)
    Right _ -> assert "ci without head is rejected" false
  case Results.ciVerification "ci" "passed" "remote=none head=abc123" of
    Left error -> assert "ci without local is rejected" (contains (Pattern "local=") error)
    Right _ -> assert "ci without local is rejected" false
  case Results.ciVerification "ci" "passed" "local=green remote=none head=abc123" of
    Left error -> assert "ci invalid local value is rejected" (contains (Pattern "'local'") error)
    Right _ -> assert "ci invalid local value is rejected" false
  case Results.ciVerification "ci" "passed" "local=passed remote=maybe head=abc123" of
    Left error -> assert "ci invalid remote value is rejected" (contains (Pattern "'remote'") error)
    Right _ -> assert "ci invalid remote value is rejected" false
  case Results.ciVerification "ci" "passed" "CI passed" of
    Left error -> assert "ci prose-only verification is rejected" (contains (Pattern "structured facts") error)
    Right _ -> assert "ci prose-only verification is rejected" false
  case Results.ciVerification "research" "passed" "current" of
    Right _ -> assert "non-ci steps keep free-form verification" true
    Left _ -> assert "non-ci steps keep free-form verification" false
  case Results.ciVerification "ci" "passed" "remote=passed head=abc123 local=not-run" of
    Right _ -> assert "ci accepts facts in any order" true
    Left error -> do
      Console.error ("FAIL: ci accepts facts in any order: " <> error)
      Sys.exit 1
  case Results.ciVerification "ci" "skipped" "local=not-run remote=unavailable head=" of
    Right _ -> assert "ci skip semantics accept an empty head" true
    Left error -> do
      Console.error ("FAIL: ci skip semantics accept an empty head: " <> error)
      Sys.exit 1
  case Results.ciVerification "ci" "passed" "local=not-run remote=unavailable head=" of
    Left error -> assert "empty head on a passed record is rejected" (contains (Pattern "'head'") error)
    Right _ -> assert "empty head on a passed record is rejected" false
  case Results.ciVerification "ci" "skipped" "local=not-run remote=none head=" of
    Left error -> assert "empty head outside skip semantics is rejected" (contains (Pattern "'head'") error)
    Right _ -> assert "empty head outside skip semantics is rejected" false
  case Results.ciVerification "ci" "passed" "local=passed remote=none head=abc123 local=failed" of
    Left error -> assert "ci duplicate keys are rejected" (contains (Pattern "duplicate") error)
    Right _ -> assert "ci duplicate keys are rejected" false
  pendingRendered <- DoneSummary.render (state { pendingStep = Just { name: "ci", startedAt: "2024-01-01T00:00:20Z" } }) 20
  assert "pending step has an in-progress row" (contains (Pattern "| ci | ⋯ |") pendingRendered)
  assert "facts name the pending step" (contains (Pattern "pendingStep=ci") pendingRendered)
