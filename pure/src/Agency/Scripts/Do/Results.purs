module Agency.Scripts.Do.Results
  ( runInit
  , runStepStart
  , runStepEnd
  , runStep
  , runSet
  , runDriverInit
  , runDriverSkip
  , validInterval
  , loadState
  , jsonValueFor
  , putCapabilities
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Context as Context
import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs
import Data.Argonaut.Core (Json, fromBoolean, fromString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)

runInit :: WorkflowContext -> Effect Outcome.OpOutcome
runInit context = do
  timestamp <- Sys.nowIso
  State.writeState (Context.statePath context) (State.initState timestamp)
  pure (Outcome.withStdout ("init: startedAt=" <> timestamp <> "\n"))

runStepStart :: WorkflowContext -> String -> Effect Outcome.OpOutcome
runStepStart context name = withLoadedState context \state -> case state.pendingStep of
  Just pending -> pure (failText ("do-results: pendingStep '" <> pending.name <> "' already active — call step-end before starting '" <> name <> "'"))
  Nothing -> do
    timestamp <- Sys.nowIso
    State.writeState (Context.statePath context) (State.startPending { name, startedAt: timestamp } state)
    pure (Outcome.withStdout ("pending: " <> name <> "\n"))

runStepEnd :: WorkflowContext -> String -> String -> Maybe String -> Effect Outcome.OpOutcome
runStepEnd context status verification reason = withLoadedState context \state -> case state.pendingStep of
  Nothing -> pure (failText "do-results: no pendingStep — call step-start first")
  Just pending -> do
    completed <- Sys.nowIso
    timing <- validInterval pending.startedAt completed
    case timing of
      Left error -> pure (failText error)
      Right _ -> do
        let step = { name: pending.name, status: State.parseStepStatus status, verification, startedAt: pending.startedAt, completedAt: completed, reason }
            updated = terminalize pending.name status (State.finishPending (State.appendStep step state))
        State.writeState (Context.statePath context) updated
        pure (Outcome.withStdout ("recorded: " <> pending.name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ", pending=none)\n"))

runStep :: WorkflowContext -> String -> String -> String -> String -> String -> Maybe String -> Effect Outcome.OpOutcome
runStep context name status verification startedAt completedAt reason = withLoadedState context \state -> do
  actualStart <- resolveNow startedAt
  actualEnd <- resolveNow completedAt
  timing <- validInterval actualStart actualEnd
  case timing of
    Left error -> pure (failText error)
    Right _ -> do
      let updated = terminalize name status (State.appendStep { name, status: State.parseStepStatus status, verification, startedAt: actualStart, completedAt: actualEnd, reason } state)
      State.writeState (Context.statePath context) updated
      pure (Outcome.withStdout ("recorded: " <> name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ")\n"))

runSet :: WorkflowContext -> String -> String -> Effect Outcome.OpOutcome
runSet context field value = withLoadedState context \state -> do
  let updated = do
        json <- jsonValueFor field value
        State.setField field json state
  case updated of
    Left error -> pure (failText error)
    Right final -> do
      State.writeState (Context.statePath context) final
      pure (Outcome.withStdout ("set: " <> field <> "=" <> value <> "\n"))

runDriverInit :: WorkflowContext -> { review :: Boolean, noVcs :: Boolean, minimal :: Boolean, restart :: Boolean, from :: String, task :: String } -> Effect Outcome.OpOutcome
runDriverInit context options = do
  existing <- State.readState (Context.statePath context)
  case existing of
    Left error -> pure (failText ("do-driver: .do-results.json is corrupt or unreadable — " <> error <> "; restore it or run init --restart"))
    Right (Just state) | isActiveRun state && not options.restart ->
      pure (failWithCode 2 ("do-driver: a /do run is already active (task: '" <> State.stateGet "task" state <> "', steps: " <> show (Array.length state.steps) <> ") — finish it or run init --restart to discard it"))
    _ -> do
      timestamp <- Sys.nowIso
      let base = State.initState timestamp
          initialized = do
            withNoVcs <- State.setField "noVcs" (fromBoolean options.noVcs) base
            withReview <- State.setField "review" (fromBoolean options.review) withNoVcs
            withMinimal <- State.setField "minimal" (fromBoolean options.minimal) withReview
            withVcs <- if Vcs.vcsName context.vcs == "unknown" then Right withMinimal else State.setField "vcs" (fromString (Vcs.vcsName context.vcs)) withMinimal
            withForge <- State.setField "forge" (fromString (Forge.forgeName context.forge)) withVcs
            withCapabilities <- putCapabilities context.forge withForge
            withFrom <- if options.from == "" then Right withCapabilities else State.setField "from" (fromString options.from) withCapabilities
            if options.task == "" then Right withFrom else State.setField "task" (fromString options.task) withFrom
      case initialized of
        Left error -> pure (failText error)
        Right final -> do
          State.writeState (Context.statePath context) final
          let fromText = if options.from == "" then "default" else options.from
          pure (Outcome.withStdout ("init: review=" <> show options.review <> " noVcs=" <> show options.noVcs <> " minimal=" <> show options.minimal <> " from=" <> fromText <> " vcs=" <> Vcs.vcsName context.vcs <> "\n"))

runDriverSkip :: WorkflowContext -> String -> String -> Effect Outcome.OpOutcome
runDriverSkip context step reason = do
  started <- runStepStart context step
  if started.exit /= 0 then pure started
  else do
    ended <- runStepEnd context "skipped" "" (Args.nonEmpty reason)
    pure (Outcome.append started ended)

validInterval :: String -> String -> Effect (Either String Unit)
validInterval startedAt completedAt = do
  started <- Sys.isoToEpoch startedAt
  completed <- Sys.isoToEpoch completedAt
  pure case started, completed of
    Left error, _ -> Left ("do-results: " <> error)
    _, Left error -> Left ("do-results: " <> error)
    Right start, Right end ->
      if end < start then
        Left ("do-results: completedAt '" <> completedAt <> "' precedes startedAt '" <> startedAt <> "'")
      else Right unit

jsonValueFor :: String -> String -> Either String Json
jsonValueFor field value
  | field == "steps" || field == "pendingStep" = jsonParser value
  | Array.elem field booleanFields = case value of
      "true" -> Right (fromBoolean true)
      "false" -> Right (fromBoolean false)
      _ -> Left ("do-results: field '" <> field <> "' must be true or false")
  | otherwise = Right (fromString value)

putCapabilities :: Forge.ForgeKind -> State.State -> Either String State.State
putCapabilities forge state = do
  withCreate <- State.setField "supportsPrCreate" (fromBoolean (Forge.supports forge "pr-create")) state
  withComment <- State.setField "supportsPrComment" (fromBoolean (Forge.supports forge "pr-comment")) withCreate
  withIssue <- State.setField "supportsIssueView" (fromBoolean (Forge.supports forge "issue-view")) withComment
  State.setField "supportsPrChecks" (fromBoolean (Forge.supports forge "pr-checks")) withIssue

withLoadedState :: WorkflowContext -> (State.State -> Effect Outcome.OpOutcome) -> Effect Outcome.OpOutcome
withLoadedState context action = do
  loaded <- loadState context
  case loaded of
    Left error -> pure (failText error)
    Right state -> action state

loadState :: WorkflowContext -> Effect (Either String State.State)
loadState context = do
  result <- State.readState (Context.statePath context)
  pure case result of
    Left error -> Left ("do-results: .do-results.json is corrupt or unreadable — " <> error <> "; restore it or run do-results init --restart")
    Right Nothing -> Left "do-results: .do-results.json not found — run do-results init first"
    Right (Just state) -> Right state

resolveNow :: String -> Effect String
resolveNow value = if value == "now" then Sys.nowIso else pure value

terminalize :: String -> String -> State.State -> State.State
terminalize name status state =
  if name /= "done" then state
  else State.finishWorkflow (if status == "failed" then State.WorkflowFailed else State.WorkflowCompleted) state

isActiveRun :: State.State -> Boolean
isActiveRun state =
  state.active == State.ActiveWorking || state.active == State.ActiveWaiting

booleanFields :: Array String
booleanFields =
  [ "review", "noVcs", "minimal", "hasEvidence"
  , "supportsPrCreate", "supportsPrComment", "supportsIssueView", "supportsPrChecks"
  ]

failText :: String -> Outcome.OpOutcome
failText message = Outcome.failure 1 (message <> "\n")

failWithCode :: Int -> String -> Outcome.OpOutcome
failWithCode code message = Outcome.failure code (message <> "\n")
