module Agency.Scripts.Do.Sync
  ( run
  ) where

import Prelude

import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Context as Context
import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Results as Results
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs
import Data.Argonaut.Core (fromBoolean, fromString)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (trim)
import Effect (Effect)
import Effect.Exception (try)
import Node.Errors.SystemError as SystemError
import Unsafe.Coerce (unsafeCoerce)

run :: WorkflowContext -> { noVcs :: Boolean, base :: Maybe String, stack :: Boolean } -> Effect Outcome.OpOutcome
run context options = do
  startedAt <- Sys.nowIso
  fetched <- fetchPhase context options.noVcs
  case fetched of
    Left outcome -> failSync context outcome
    Right phases -> do
      inspected <- if options.noVcs then pure Vcs.Clean else Vcs.inspectDirty context
      case inspected of
        Vcs.InspectionFailed outcome -> failSync context (Outcome.append (phaseOutput phases) outcome)
        _ -> do
          resolvedContext <- resolveContext context options startedAt
          case resolvedContext of
            Left outcome -> failSync context outcome
            Right state1 -> do
              resolved <- basePhase context options state1
              case resolved of
                Left outcome -> failSync context outcome
                Right base -> do
                  let dirtyWarning = case inspected of
                        Vcs.DirtyDetected ->
                          Outcome.failure 0 "Dirty tree detected. Continuing will create a fresh branch on top of these changes. If you wanted the agent to extend your WIP in place without touching git, re-run with --no-vcs.\n"
                        _ -> Outcome.success
                  protocol <- recordPhase context options startedAt base
                  pure (Outcome.append (Outcome.append (phaseOutput phases) dirtyWarning) protocol)

type FetchPhase =
  { quietFetch :: Outcome.OpOutcome
  , quietRefresh :: Outcome.OpOutcome
  , forwarded :: Outcome.OpOutcome
  }

fetchPhase :: WorkflowContext -> Boolean -> Effect (Either Outcome.OpOutcome FetchPhase)
fetchPhase context noVcs =
  if noVcs then pure (Right { quietFetch: Outcome.success, quietRefresh: Outcome.success, forwarded: Outcome.success })
  else do
    fetched <- Vcs.fetchValue context
    let quietFetch = quietResult fetched
    if fetched.exit /= 0 then pure (Left quietFetch)
    else do
      refreshed <- Vcs.refreshDefaultBranchValue context
      let quietRefresh = quietResult refreshed
      if refreshed.exit /= 0 then pure (Left (Outcome.append quietFetch quietRefresh))
      else do
        forwarded <- Vcs.runVcsOp context Vcs.FastForwardIfSafe
        if forwarded.exit /= 0 then pure (Left (Outcome.append (Outcome.append quietFetch quietRefresh) forwarded))
        else pure (Right { quietFetch, quietRefresh, forwarded })

phaseOutput :: FetchPhase -> Outcome.OpOutcome
phaseOutput phase = Outcome.append (Outcome.append phase.quietFetch phase.quietRefresh) phase.forwarded

failSync :: WorkflowContext -> Outcome.OpOutcome -> Effect Outcome.OpOutcome
failSync context outcome = do
  existing <- State.readState (Context.statePath context)
  case existing of
    Left error ->
      pure (Outcome.append outcome (failText ("sync: unable to read state while recording failure: " <> error)))
    Right Nothing ->
      -- Sync can fail before it creates state, leaving nothing to mark failed.
      pure outcome
    Right (Just state) -> do
      written <- try (State.writeState (Context.statePath context) (State.finishWorkflow State.WorkflowFailed state))
      pure case written of
        Left error ->
          Outcome.append outcome (failText ("sync: unable to mark workflow as failed: " <> SystemError.message (unsafeCoerce error)))
        Right _ -> outcome

resolveContext :: WorkflowContext -> { noVcs :: Boolean, base :: Maybe String, stack :: Boolean } -> String -> Effect (Either Outcome.OpOutcome State.State)
resolveContext context options startedAt = do
  initial <- State.readState (Context.statePath context)
  case initial of
    Left error -> pure (Left (failText ("sync: " <> error)))
    Right maybeState ->
      let state0 = fromMaybe (State.initState startedAt) maybeState
      in case putSyncFields context options.noVcs state0 of
        Left error -> pure (Left (failText ("sync: " <> error)))
        Right state1 -> pure (Right state1)

type SyncBase =
  { state :: State.State
  , branch :: Vcs.VcsValue
  , defaultRef :: String
  , base :: String
  }

basePhase :: WorkflowContext -> { noVcs :: Boolean, base :: Maybe String, stack :: Boolean } -> State.State -> Effect (Either Outcome.OpOutcome SyncBase)
basePhase context options state1 = do
  branchResult <- Vcs.headRevisionValue context
  defaultResult <- Vcs.defaultBranchValue context
  if branchResult.code /= 0 then pure (Left (Vcs.renderValue branchResult))
  else if defaultResult.code /= 0 then pure (Left (Vcs.renderValue defaultResult))
  else do
    baseResult <- resolveSyncBase options defaultResult.value context
    case baseResult of
      Left error -> pure (Left (failWithCode 2 error))
      Right base -> case State.setField "base" (fromString base) state1 of
        Left error -> pure (Left (failText ("sync: " <> error)))
        Right state2 -> pure (Right { state: state2, branch: branchResult, defaultRef: defaultResult.value, base })

recordPhase :: WorkflowContext -> { noVcs :: Boolean, base :: Maybe String, stack :: Boolean } -> String -> SyncBase -> Effect Outcome.OpOutcome
recordPhase context options startedAt resolved = do
  completed <- Sys.nowIso
  let contextWithBase = context { base = Just resolved.base }
      fetchState = if options.noVcs then "fetch skipped" else "fetch ok"
      step =
        { name: "sync"
        , status: State.StepPassed
        , verification: fetchState <> "; vcs=" <> Vcs.vcsName context.vcs <> "; forge=" <> Forge.forgeName context.forge <> "; noVcs=" <> show options.noVcs <> "; base=" <> resolved.base
        , startedAt
        , completedAt: completed
        , reason: Nothing
        }
  case State.appendStep step resolved.state of
    Left error -> pure (failText error)
    Right updated -> do
      State.writeState (Context.statePath context) updated
      pure (Outcome.withStdout
        ( "vcs=" <> Vcs.vcsName contextWithBase.vcs <> "\n"
          <> "forge=" <> Forge.forgeName contextWithBase.forge <> "\n"
          <> "branch=" <> resolved.branch.value <> "\n"
          <> "defaultBranch=" <> resolved.defaultRef <> "\n"
          <> "base=" <> resolved.base <> "\n"
        ))

quietResult :: Outcome.OpOutcome -> Outcome.OpOutcome
quietResult result = case result.output of
  Outcome.Passthrough -> result
  Outcome.Captured output ->
    { exit: result.exit
    , output: Outcome.Captured
        { stdout: ""
        , stderr: output.stderr
        , stderrFirst: output.stderr /= ""
        }
    }

putSyncFields :: WorkflowContext -> Boolean -> State.State -> Either String State.State
putSyncFields context noVcs state = do
  withVcs <- State.setField "vcs" (fromString (Vcs.vcsName context.vcs)) state
  withForge <- State.setField "forge" (fromString (Forge.forgeName context.forge)) withVcs
  withNoVcs <- State.setField "noVcs" (fromBoolean noVcs) withForge
  Results.putCapabilities context.forge withNoVcs

resolveSyncBase :: { noVcs :: Boolean, base :: Maybe String, stack :: Boolean } -> String -> WorkflowContext -> Effect (Either String String)
resolveSyncBase options defaultRef context = case options.base of
  Just requested -> do
    valid <- Vcs.validateBase context requested
    pure case valid of
      Left error -> Left ("sync: invalid --base '" <> requested <> "': " <> error)
      Right _ -> Right requested
  Nothing | options.stack -> do
    current <- Vcs.currentBranchValue context
    if current.code /= 0 then pure (Left (if current.stderr == "" then "sync: unable to resolve current branch" else trim current.stderr))
    else if current.value == "" || current.value == defaultRef || current.value == "HEAD" then pure (noFeatureBranch current.value defaultRef)
    else do
      atDefault <- Vcs.currentAtDefault context defaultRef
      pure case atDefault of
        Left error -> Left ("sync: unable to compare current branch with default: " <> error)
        Right true -> noFeatureBranch current.value defaultRef
        Right false -> Right current.value
  Nothing -> pure (Right defaultRef)

noFeatureBranch :: String -> String -> Either String String
noFeatureBranch current defaultRef =
  Left
    ("sync: --stack found no feature branch to stack onto\n"
      <> "       current branch is '" <> if current == "" then "<none>" else current <> "' (default is '" <> defaultRef <> "').\n"
      <> "       checkout the feature branch first, or pass --base <branch> explicitly.")

failText :: String -> Outcome.OpOutcome
failText message = Outcome.failure 1 (message <> "\n")

failWithCode :: Int -> String -> Outcome.OpOutcome
failWithCode code message = Outcome.failure code (message <> "\n")
