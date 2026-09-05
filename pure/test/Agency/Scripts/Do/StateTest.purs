module Agency.Scripts.Do.StateTest (run) where

import Prelude

import Data.Argonaut.Core (fromBoolean, toBoolean, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
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
  case Ops.parseDriverOp [ "start", "reserch" ] of
    Left error -> assert "unknown workflow step is rejected" (error.code == 2)
    Right _ -> assert "unknown workflow step is rejected" false
  case Ops.parseResultsOp [ "step-start", "reserch" ] of
    Left error -> assert "result steps are restricted to workflow steps" (error.code == 2)
    Right _ -> assert "result steps are restricted to workflow steps" false
  assert "string fields preserve literal true" (map toString (Ops.jsonValueFor "task" "true") == Right (Just "true"))
  assert "boolean fields decode literal true" (map toBoolean (Ops.jsonValueFor "review" "true") == Right (Just true))
  let terminal = State.finishWorkflow State.WorkflowCompleted (State.initState "2024-01-01T00:00:00Z")
  assert "terminal success makes the workflow idle" (terminal.active == State.ActiveIdle && terminal.status == State.WorkflowCompleted)
