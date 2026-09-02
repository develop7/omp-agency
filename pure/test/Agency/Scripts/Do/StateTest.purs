module Agency.Scripts.Do.StateTest (run) where

import Prelude

import Data.Argonaut.Core (fromBoolean, toBoolean)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console as Console

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
          let withNewField = State.setField "newFlag" (fromBoolean true) roundTripped
          assert "set unknown field can be read as boolean" ((State.stateGetJson "newFlag" withNewField >>= toBoolean) == Just true)
          let reloaded = State.parseState (State.stringifyState withNewField)
          case reloaded of
            Left error -> do
              Console.error ("FAIL: reload state after set: " <> error)
              Sys.exit 1
            Right finalState -> assert "set unknown field survives load/save" ((State.stateGetJson "newFlag" finalState >>= toBoolean) == Just true)
