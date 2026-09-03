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
runForge request = runParsed request.captureOutput (parseMessageError (Forge.parseForgeOp request.args)) Forge.runForgeOp

runWorkflow :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runWorkflow request =
  if Array.head request.args == Just "cli" && Array.length request.args > 1 then
    pure (failureResult 1 "workflow: from is only valid with cli_seed")
  else
    runParsed request.captureOutput (Ops.parseNickelOp request.args) Ops.runNickelOp

runAgencyDriver :: { tool :: String, args :: Array String, captureOutput :: Boolean } -> Effect ToolResult
runAgencyDriver request = case Array.uncons request.args of
  -- The tool contract is {op, args}: op selects the subcommand and args
  -- carries only its operands. Re-add the op for the legacy results and
  -- driver parsers; sync consumes only its operands.
  Nothing -> pure (failureResult 1 agencyDriverUsage)
  Just { head: operation, tail: operands } -> case operation of
    "sync" -> dispatchWith Ops.parseSyncOp Ops.runSyncOp operands
    _ | Array.elem operation resultsOperationNames -> dispatchResults operation operands
      | Array.elem operation driverOperationNames -> dispatchDriver operation operands
      | otherwise -> pure (failureResult 1 agencyDriverUsage)
  where
  dispatchResults operation operands =
    dispatchWith Ops.parseResultsOp Ops.runResultsOp (Array.cons operation operands)
  dispatchDriver operation operands =
    dispatchWith Ops.parseDriverOp Ops.runDriverOp (Array.cons operation operands)
  dispatchWith :: forall op. (Array String -> Either Ops.ParseError op) -> (Context.WorkflowContext -> op -> Effect Outcome.OpOutcome) -> Array String -> Effect ToolResult
  dispatchWith parser runner args = runParsed request.captureOutput (parser args) runner

resultsOperationNames :: Array String
resultsOperationNames = ["step-start", "step-end", "step"]

driverOperationNames :: Array String
driverOperationNames = ["init", "start", "end", "skip", "set", "summary"]

agencyDriverUsage :: String
agencyDriverUsage = "agency_driver: operation required (init|start|end|skip|set|summary|sync|step-start|step-end|step)"

parseVcsRead :: Array String -> Either String Vcs.VcsOp
parseVcsRead args = case Vcs.parseVcsOp args of
  Left message -> Left message
  Right Vcs.Fetch -> Left "vcs_read: fetch updates remote-tracking refs; use agency_driver sync instead"
  Right operation -> if isReadOperation operation then Right operation else Left "vcs_read: mutating operation rejected; use vcs_write instead"

parseVcsWrite :: Array String -> Either String Vcs.VcsOp
parseVcsWrite args = case Vcs.parseVcsOp args of
  Left message -> Left message
  Right operation -> if isWriteOperation operation then Right operation else Left "vcs_write: read-only operation rejected; use vcs_read instead"

isReadOperation :: Vcs.VcsOp -> Boolean
isReadOperation operation = case operation of
  Vcs.Detect -> true
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
  Vcs.Fetch -> false
  Vcs.Branch _ -> false
  Vcs.Commit _ _ -> false
  Vcs.Push _ -> false
  Vcs.FixCommit _ _ -> false
  Vcs.RefreshDefaultBranch -> false
  Vcs.FastForwardIfSafe -> false

isWriteOperation :: Vcs.VcsOp -> Boolean
isWriteOperation operation = case operation of
  Vcs.Detect -> false
  Vcs.Fetch -> false
  Vcs.RemoteUrl -> false
  Vcs.HeadRevision -> false
  Vcs.HeadCommitSha -> false
  Vcs.DefaultBranch -> false
  Vcs.CurrentBranch -> false
  Vcs.Base -> false
  Vcs.Dirty -> false
  Vcs.DiffRange _ -> false
  Vcs.DiffNames _ -> false
  Vcs.DiffStat _ -> false
  Vcs.NewFiles _ -> false
  Vcs.LogRange _ -> false
  Vcs.LogHead -> false
  Vcs.Branch _ -> true
  Vcs.Commit _ _ -> true
  Vcs.Push _ -> true
  Vcs.FixCommit _ _ -> true
  Vcs.RefreshDefaultBranch -> false
  Vcs.FastForwardIfSafe -> false

runParsed :: forall a. Boolean -> Either Ops.ParseError a -> (Context.WorkflowContext -> a -> Effect Outcome.OpOutcome) -> Effect ToolResult
runParsed captureOutput parsed runner = case parsed of
  Left error -> pure (failureResult error.code error.message)
  Right operation -> runOperation captureOutput runner operation
parseMessageError :: forall a. Either String a -> Either Ops.ParseError a
parseMessageError parsed = case parsed of
  Left message -> Left (messageParseError message)
  Right operation -> Right operation

messageParseError :: String -> Ops.ParseError
messageParseError message = { code: 1, message }
 

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
