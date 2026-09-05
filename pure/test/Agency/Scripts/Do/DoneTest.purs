module Agency.Scripts.Do.DoneTest (run) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..))
import Data.String.CodeUnits (contains)
import Effect (Effect)
import Effect.Console as Console

import Agency.Scripts.Do.Ops as Ops
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
  assert "seconds duration format" (Ops.fmtDur 12 == "12s")
  assert "minutes duration format" (Ops.fmtDur 75 == "1m 15s")
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
  rendered <- Ops.renderDone state 20
  assert "markdown table header" (contains (Pattern "| Step | Status | Duration | Verification |") rendered)
  assert "dominant step duration is bold" (contains (Pattern "| slow-check | ✓ | **12s** | all \\| good |") rendered)
  assert "facts include total" (contains (Pattern "totalSeconds=20") rendered)
  badSummary <- Ops.computeDoneSummary (state { steps = map (\step -> step { startedAt = "not-a-date" }) state.steps })
  case badSummary of
    Left error -> assert "malformed timestamp is reported" (contains (Pattern "not-a-date") error)
    Right _ -> assert "malformed timestamp is rejected" false
  inverted <- Ops.validInterval "2024-01-01T00:00:01Z" "2024-01-01T00:00:00Z"
  case inverted of
    Left error -> assert "inverted timestamps are rejected before recording" (contains (Pattern "precedes") error)
    Right _ -> assert "inverted timestamps are rejected before recording" false
  pendingRendered <- Ops.renderDone (state { pendingStep = Just { name: "ci", startedAt: "2024-01-01T00:00:20Z" } }) 20
  assert "pending step has an in-progress row" (contains (Pattern "| ci | ⋯ |") pendingRendered)
  assert "facts name the pending step" (contains (Pattern "pendingStep=ci") pendingRendered)
