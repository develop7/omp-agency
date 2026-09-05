module Agency.Scripts.Do.NickelRuntime
  ( run
  ) where

import Prelude

import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Sys as Sys
import Data.Argonaut.Core (Json, fromObject, fromString, jsonNull)
import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Int (floor)
import Data.Tuple (Tuple(..))
import Foreign.Object as Obj
import Effect (Effect)

-- | Forward a workflow request to the Node adapter, which owns workflow asset
-- | and state discovery and returns a JSON-encoded exit/stdout/stderr result.
-- | The context's captureOutput flag is intentionally ignored: the bridge
-- | communicates over stdin/stdout.
run :: WorkflowContext -> Maybe String -> Effect Outcome.OpOutcome
run context seed = do
  bundle <- Sys.bundleDir
  let bridge = bundle <> "/../../nickel-vm/scripts/cli-bridge.mjs"
      operation = case seed of
        Nothing -> "cli"
        Just _ -> "cli_seed"
      seedJson = case seed of
        Nothing -> jsonNull
        Just from -> fromString from
      request = Json.stringify
        (fromObject
          (Obj.fromFoldable
            [ Tuple "operation" (fromString operation)
            , Tuple "seed" seedJson
            , Tuple "cwd" (fromString context.stateDir)
            ]))
  result <- Sys.execInput "node" [ bridge ] request
  pure (bridgeOutcome result)

bridgeOutcome :: Sys.ExecResult -> Outcome.OpOutcome
bridgeOutcome result =
  if result.code /= 0 then Outcome.captured result
  else case jsonParser result.stdout >>= decodeBridge of
    Left error -> Outcome.failure 1 ("nickel-cli: invalid bridge response: " <> error <> "\n")
    Right value ->
      { exit: value.exit
      , output: Outcome.Captured { stdout: value.stdout, stderr: value.stderr, stderrFirst: false }
      }

decodeBridge :: Json -> Either String { exit :: Int, stdout :: String, stderr :: String }
decodeBridge json = do
  object <- case Json.toObject json of
    Nothing -> Left "response must be an object"
    Just value -> Right value
  exit <- case Obj.lookup "exit" object >>= Json.toNumber of
    Nothing -> Left "response exit must be a number"
    Just value -> Right (floor value)
  stdout <- requiredJsonString "stdout" object
  stderr <- requiredJsonString "stderr" object
  pure { exit, stdout, stderr }

requiredJsonString :: String -> Obj.Object Json -> Either String String
requiredJsonString field object = case Obj.lookup field object >>= Json.toString of
  Nothing -> Left ("response " <> field <> " must be a string")
  Just value -> Right value
