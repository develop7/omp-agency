module Agency.Scripts.Do.Api
  ( runTool
  ) where

import Prelude

import Agency.Scripts.Do.Context as Context
import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Ops as Ops
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Vcs as Vcs
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)

type ToolResult =
  { exit :: Int
  , stdout :: String
  , stderr :: String
  }

-- | Run one model-facing tool through the same parsers and runners as the CLI.
-- | The adapter chooses whether pass-through subprocesses inherit or capture
-- | their streams through the request's captureOutput flag.
runTool :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runTool request = case request.tool of
  "vcs_read" -> runVcsRead request
  "vcs_write" -> runVcsWrite request
  "forge" -> runForge request
  "workflow" -> runWorkflow request
  "agency_driver" -> runAgencyDriver request
  _ -> pure (failureResult 1 ("agency: unknown tool '" <> request.tool <> "'"))

runVcsRead :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runVcsRead request = case parseVcsRead request.args of
  Left message -> pure (failureResult 1 message)
  Right operation -> runOperation request.captureOutput Vcs.runVcsOp operation

runVcsWrite :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runVcsWrite request = case parseVcsWrite request.args of
  Left message -> pure (failureResult 1 message)
  Right operation -> runOperation request.captureOutput Vcs.runVcsOp operation

runForge :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runForge request = runMessageParsed request.captureOutput (Forge.parseForgeOp request.args) Forge.runForgeOp

runWorkflow :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runWorkflow request =
  if Array.head request.args == Just "cli" && Array.length request.args > 1 then
    pure (failureResult 1 "workflow: from is only valid with cli_seed")
  else
    runParsed request.captureOutput (Ops.parseNickelOp request.args) Ops.runNickelOp

runAgencyDriver :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runAgencyDriver request = case Array.head request.args of
  Just "sync" -> runParsed request.captureOutput (Ops.parseSyncOp request.args) Ops.runSyncOp
  Just "step-start" -> runParsed request.captureOutput (Ops.parseResultsOp request.args) Ops.runResultsOp
  Just "step-end" -> runParsed request.captureOutput (Ops.parseResultsOp request.args) Ops.runResultsOp
  Just "step" -> runParsed request.captureOutput (Ops.parseResultsOp request.args) Ops.runResultsOp
  Just "init" -> runParsed request.captureOutput (Ops.parseDriverOp request.args) Ops.runDriverOp
  Just "start" -> runParsed request.captureOutput (Ops.parseDriverOp request.args) Ops.runDriverOp
  Just "end" -> runParsed request.captureOutput (Ops.parseDriverOp request.args) Ops.runDriverOp
  Just "skip" -> runParsed request.captureOutput (Ops.parseDriverOp request.args) Ops.runDriverOp
  Just "set" -> runParsed request.captureOutput (Ops.parseDriverOp request.args) Ops.runDriverOp
  Just "summary" -> runParsed request.captureOutput (Ops.parseDriverOp request.args) Ops.runDriverOp
  _ -> pure (failureResult 1 "agency_driver: operation required (init|start|end|skip|set|summary|sync|step-start|step-end|step)")

parseVcsRead :: Array String -> Either String Vcs.VcsOp
parseVcsRead args = case Vcs.parseVcsOp args of
  Left message -> Left message
  Right operation -> if isReadOperation operation then Right operation else Left "vcs_read: mutating operation rejected; use vcs_write instead"

parseVcsWrite :: Array String -> Either String Vcs.VcsOp
parseVcsWrite args = case Vcs.parseVcsOp args of
  Left message -> Left message
  Right operation -> if isWriteOperation operation then Right operation else Left "vcs_write: read-only operation rejected; use vcs_read instead"

isReadOperation :: Vcs.VcsOp -> Boolean
isReadOperation operation = case operation of
  Vcs.Detect -> true
  Vcs.Fetch -> true
  Vcs.RemoteUrl -> true
  Vcs.HeadRevision -> true
  Vcs.HeadCommitSha -> true
  Vcs.DefaultBranch -> true
  Vcs.CurrentBranch -> true
  Vcs.Base -> true
  Vcs.Dirty -> true
  Vcs.DiffRange _ -> true
  Vcs.DiffNames _ -> true
  Vcs.DiffStat _ -> true
  Vcs.NewFiles _ -> true
  Vcs.LogRange _ -> true
  Vcs.LogHead -> true
  _ -> false

isWriteOperation :: Vcs.VcsOp -> Boolean
isWriteOperation operation = case operation of
  Vcs.Branch _ -> true
  Vcs.Commit _ _ -> true
  Vcs.Push _ -> true
  Vcs.FixCommit _ _ -> true
  _ -> false

runParsed :: forall a. Boolean -> Either Ops.ParseError a -> (Context.WorkflowContext -> a -> Effect Outcome.OpOutcome) -> Effect ToolResult
runParsed captureOutput parsed runner = case parsed of
  Left error -> pure (failureResult error.code error.message)
  Right operation -> runOperation captureOutput runner operation
 
runMessageParsed :: forall a. Boolean -> Either String a -> (Context.WorkflowContext -> a -> Effect Outcome.OpOutcome) -> Effect ToolResult
runMessageParsed captureOutput parsed runner = case parsed of
  Left message -> pure (failureResult 1 message)
  Right operation -> runOperation captureOutput runner operation

runOperation :: forall a. Boolean -> (Context.WorkflowContext -> a -> Effect Outcome.OpOutcome) -> a -> Effect ToolResult
runOperation captureOutput runner operation = do
  resolved <- Ops.resolveWorkflowContext captureOutput
  case resolved of
    Left message -> pure (failureResult 1 message)
    Right context -> outcomeResult <$> runner context operation

outcomeResult :: Outcome.OpOutcome -> ToolResult
outcomeResult outcome = case outcome.output of
  Outcome.Captured output ->
    { exit: outcome.exit
    , stdout: output.stdout
    , stderr: output.stderr
    }
  Outcome.Passthrough ->
    { exit: outcome.exit
    , stdout: ""
    , stderr: ""
    }

failureResult :: Int -> String -> ToolResult
failureResult exit message =
  { exit
  , stdout: ""
  , stderr: message <> "\n"
  }
