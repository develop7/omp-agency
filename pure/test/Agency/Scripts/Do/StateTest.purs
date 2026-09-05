module Agency.Scripts.Do.StateTest (run) where

import Prelude

import Data.Array as Array
import Data.Argonaut.Core (fromBoolean, toBoolean, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console as Console

import Agency.Scripts.Do.Ops as Ops
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
  let source = "{\"workflow\":\"do\",\"startedAt\":\"2024-01-01T00:00:00Z\",\"active\":\"working\",\"status\":\"running\",\"steps\":[],\"pendingStep\":null,\"customField\":{\"nested\":[true,2]},\"customText\":\"kept\"}"
  case State.parseState source of
    Left error -> do
      Console.error ("FAIL: parse state: " <> error)
      Sys.exit 1
    Right state -> do
      let encoded = State.stringifyState state
      assert "unknown object field survives stringify" (encoded == "{\"workflow\":\"do\",\"startedAt\":\"2024-01-01T00:00:00Z\",\"active\":\"working\",\"status\":\"running\",\"steps\":[],\"customField\":{\"nested\":[true,2]},\"customText\":\"kept\"}")
      case State.parseState encoded of
        Left error -> do
          Console.error ("FAIL: parse encoded state: " <> error)
          Sys.exit 1
        Right roundTripped -> do
          assert "unknown boolean/object value remains available" (State.stateGetJson "customField" roundTripped /= Nothing)
          case State.setField "newFlag" (fromBoolean true) roundTripped of
            Left error -> do
              Console.error ("FAIL: set unknown field: " <> error)
              Sys.exit 1
            Right withNewField -> do
              assert "set unknown field can be read as boolean" ((State.stateGetJson "newFlag" withNewField >>= toBoolean) == Just true)
              case jsonParser "[]" >>= \json -> State.setField "steps" json withNewField of
                Left error -> do
                  Console.error ("FAIL: set reserved steps: " <> error)
                  Sys.exit 1
                Right withSteps -> do
                  assert "reserved steps updates typed field" (State.stateGetJson "steps" withSteps /= Nothing)
                  case State.setField "steps" (fromBoolean true) withSteps of
                    Left _ -> pure unit
                    Right _ -> do
                      Console.error "FAIL: invalid reserved steps value was accepted"
                      Sys.exit 1
                  let reloaded = State.parseState (State.stringifyState withSteps)
                  case reloaded of
                    Left error -> do
                      Console.error ("FAIL: reload state after set: " <> error)
                      Sys.exit 1
                    Right finalState -> assert "set unknown field survives load/save" ((State.stateGetJson "newFlag" finalState >>= toBoolean) == Just true)
  case State.parseState "{\"active\":\"finished\"}" of
    Left error -> assert "unknown active status is rejected" (error == "state: invalid active 'finished'")
    Right _ -> assert "unknown active status is rejected" false
  case State.parseState "{\"status\":\"done\"}" of
    Left error -> assert "unknown workflow status is rejected" (error == "state: invalid status 'done'")
    Right _ -> assert "unknown workflow status is rejected" false
  case State.parseState "{\"steps\":[{\"name\":\"sync\",\"status\":\"bananas\",\"verification\":\"\",\"startedAt\":\"2024-01-01T00:00:00Z\",\"completedAt\":\"2024-01-01T00:00:00Z\"}]}" of
    Left error -> assert "unknown step status is rejected" (error == "state: invalid step status 'bananas'")
    Right _ -> assert "unknown step status is rejected" false
  case Ops.parseResultsOp [ "step", "sync", "bananas", "", "now", "now" ] of
    Left error -> assert "invalid step status is rejected at the command boundary" (error.code == 1)
    Right _ -> assert "invalid step status is rejected at the command boundary" false
  case Ops.parseDriverOp [ "init", "first", "second" ] of
    Left error -> assert "multiple task arguments are rejected" (error.code == 2)
    Right _ -> assert "multiple task arguments are rejected" false
  case Ops.parseDriverOp [ "init", "--from=followpu", "resume" ] of
    Left error -> assert "unknown entry point is rejected" (error.code == 2)
    Right _ -> assert "unknown entry point is rejected" false
  case Ops.parseNickelOp [ "cli_seed", "followpu" ] of
    Left error -> assert "nickel cli_seed rejects an unknown entry point" (error.code == 2)
    Right _ -> assert "nickel cli_seed rejects an unknown entry point" false
  case Ops.parseDriverOp [ "start", "reserch" ] of
    Left error -> assert "unknown workflow step is rejected" (error.code == 2)
    Right _ -> assert "unknown workflow step is rejected" false
  case Ops.parseResultsOp [ "step-start", "reserch" ] of
    Left error -> assert "result steps are restricted to workflow steps" (error.code == 2)
    Right _ -> assert "result steps are restricted to workflow steps" false
  assert "string fields preserve literal true" (map toString (Results.jsonValueFor "task" "true") == Right (Just "true"))
  assert "boolean fields decode literal true" (map toBoolean (Results.jsonValueFor "review" "true") == Right (Just true))
  let terminal = State.finishWorkflow State.WorkflowCompleted (State.initState "2024-01-01T00:00:00Z")
  assert "terminal success makes the workflow idle" (terminal.active == State.ActiveIdle && terminal.status == State.WorkflowCompleted)
  let firstStep =
        { name: "sync"
        , status: State.StepPassed
        , verification: "first recorded"
        , startedAt: "2024-01-01T00:00:00Z"
        , completedAt: "2024-01-01T00:00:00Z"
        , reason: Nothing
        }
      middleStep =
        { name: "research"
        , status: State.StepPassed
        , verification: "middle recorded"
        , startedAt: "2024-01-01T00:00:01Z"
        , completedAt: "2024-01-01T00:00:01Z"
        , reason: Nothing
        }
      lastStep =
        { name: "check"
        , status: State.StepPassed
        , verification: "last recorded"
        , startedAt: "2024-01-01T00:00:02Z"
        , completedAt: "2024-01-01T00:00:02Z"
        , reason: Nothing
        }
      nextStep =
        { name: "evidence"
        , status: State.StepPassed
        , verification: "new record"
        , startedAt: "2024-01-01T00:00:03Z"
        , completedAt: "2024-01-01T00:00:03Z"
        , reason: Nothing
        }
      oneBeforeLimit =
        (State.initState "2024-01-01T00:00:00Z")
          { steps = [ firstStep ] <> Array.replicate (State.maxPersistedSteps - 2) middleStep
          }
      fullHistory =
        oneBeforeLimit
          { steps = oneBeforeLimit.steps <> [ lastStep ]
          }
      overLimitHistory =
        fullHistory
          { steps = fullHistory.steps <> [ nextStep ]
          }
  case State.appendStep nextStep oneBeforeLimit of
    Left error -> do
      Console.error ("FAIL: append below limit: " <> error)
      Sys.exit 1
    Right updated ->
      assert
        ("append preserves ordered history at limit " <> show State.maxPersistedSteps)
        (map _.name updated.steps == map _.name (oneBeforeLimit.steps <> [ nextStep ]))
  case State.appendStep nextStep fullHistory of
    Left error ->
      assert
        ("append rejects history at limit " <> show State.maxPersistedSteps)
        (error == "state: step history limit (" <> show State.maxPersistedSteps <> ") reached")
    Right _ -> do
      Console.error "FAIL: append allowed an unbounded audit history"
      Sys.exit 1
  case State.parseState (State.stringifyState overLimitHistory) of
    Left error ->
      assert
        ("parse rejects history beyond limit " <> show State.maxPersistedSteps)
        (error == "state: step history limit (" <> show State.maxPersistedSteps <> ") exceeded")
    Right _ -> do
      Console.error "FAIL: parse accepted an over-limit audit history"
      Sys.exit 1
  case State.appendStep (nextStep { name = "not-a-step" }) State.emptyState of
    Left error -> assert "append rejects an unknown step name" (error == "state: unknown step 'not-a-step'")
    Right _ -> do
      Console.error "FAIL: append accepted an unknown step name"
      Sys.exit 1
  case State.appendStep (nextStep { status = State.StepUnknown "not-a-status" }) State.emptyState of
    Left error -> assert "append rejects an unknown step status" (error == "state: invalid step status 'not-a-status'")
    Right _ -> do
      Console.error "FAIL: append accepted an unknown step status"
      Sys.exit 1
