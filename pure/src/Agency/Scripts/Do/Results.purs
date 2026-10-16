module Agency.Scripts.Do.Results
  ( runInit
  , runStepStart
  , runStepEnd
  , runStep
  , runJobStart
  , runJobEnd
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
import Data.Argonaut.Core (Json, fromBoolean, fromString, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
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

-- | Unfinished jobs block every path that records the step as complete —
-- | step-end and the corrective `step` record alike — so neither can yield
-- | while the step's jobs are still open; the terminal `done` step watches
-- | every job (see below), other steps only their own. The first argument
-- | names the operation being blocked so the message reports what the
-- | caller actually invoked (`"step-end"` from `runStepEnd` and
-- | `runDriverSkip`, whose step-end half is what refuses, `"step"` from
-- | `runStep`); every caller otherwise surfaces this one message verbatim.
unfinishedJobBlocker :: String -> String -> State.State -> Maybe String
unfinishedJobBlocker operation stepName state =
  let
    -- `done` is the global yield: recording it lets `terminalize` mark the
    -- whole run complete, so it must consider ALL unfinished jobs, not only
    -- `done`-owned ones — the same predicate `DoneSummary.run` uses. Any
    -- other step blocks only on the jobs it owns.
    open = State.unfinishedJobs state
    blocking =
      if stepName == "done" then open
      else Array.filter (\job -> job.step == stepName) open
  in if Array.null blocking then Nothing
    else
      Just
        ( "do-results: unfinished job(s) block " <> operation <> " for '" <> stepName <> "': "
            <> joinWith ", " (map (\job -> "'" <> job.id <> "'") blocking)
            <> " — resolve with job-end first (non-completed outcomes require a verification reason)"
        )

runStepEnd :: WorkflowContext -> String -> String -> Maybe String -> Effect Outcome.OpOutcome
runStepEnd context status verification reason = withLoadedState context \state -> case state.pendingStep of
  Nothing -> pure (failText "do-results: no pendingStep — call step-start first")
  Just pending -> case unfinishedJobBlocker "step-end" pending.name state of
    Just blocker -> pure (failText blocker)
    Nothing -> do
      completed <- Sys.nowIso
      timing <- validInterval pending.startedAt completed
      let step = { name: pending.name, status: State.parseStepStatus status, verification, startedAt: pending.startedAt, completedAt: completed, reason }
      case timing >>= \_ -> State.appendStep step state of
        Left error -> pure (failText error)
        Right appended -> do
          let updated = terminalize pending.name status (State.finishPending appended)
          State.writeState (Context.statePath context) updated
          pure (Outcome.withStdout ("recorded: " <> pending.name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ", pending=none)\n"))

runStep :: WorkflowContext -> String -> String -> String -> String -> String -> Maybe String -> Effect Outcome.OpOutcome
runStep context name status verification startedAt completedAt reason = withLoadedState context \state ->
  case unfinishedJobBlocker "step" name state of
    Just blocker -> pure (failText blocker)
    Nothing -> do
      actualStart <- resolveNow startedAt
      actualEnd <- resolveNow completedAt
      timing <- validInterval actualStart actualEnd
      case timing of
        Left error -> pure (failText error)
        Right _ -> do
          let step = { name, status: State.parseStepStatus status, verification, startedAt: actualStart, completedAt: actualEnd, reason }
          case State.appendStep step state of
            Left error -> pure (failText error)
            Right appended -> do
              let updated = terminalize name status appended
              State.writeState (Context.statePath context) updated
              pure (Outcome.withStdout ("recorded: " <> name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ")\n"))

-- | Append a worker-owned job under a fresh id with a driver-computed
-- | startedAt and optional deadline (startedAt + budgetMinutes). Callers
-- | supply no timestamps, so the ledger's time fields stay trustworthy.
runJobStart :: WorkflowContext -> { id :: String, name :: String, step :: String, budgetMinutes :: Maybe Int } -> Effect Outcome.OpOutcome
runJobStart context input = withLoadedState context \state -> do
  started <- Sys.nowIso
  deadline <- deadlineAfter started input.budgetMinutes
  case deadline of
    Left error -> pure (failText ("do-driver: " <> error))
    Right limit -> do
      let job =
            { id: input.id
            , name: input.name
            , step: input.step
            , startedAt: started
            , deadline: limit
            , finished: Nothing
            }
          deadlineText = case limit of
            Nothing -> ""
            Just value -> " deadline=" <> value
      case State.appendJob job state of
        Left error -> pure (failText error)
        Right appended -> do
          State.writeState (Context.statePath context) appended
          pure (Outcome.withStdout ("job-start: " <> input.id <> " step=" <> input.step <> deadlineText <> "\n"))

-- | A job's deadline is driver-computed as startedAt + budgetMinutes and is
-- | persisted in the same canonical UTC format as every other timestamp.
deadlineAfter :: String -> Maybe Int -> Effect (Either String (Maybe String))
deadlineAfter started budget = case budget of
  Nothing -> pure (Right Nothing)
  Just minutes -> do
    startedEpoch <- Sys.isoToEpoch started
    pure case startedEpoch of
      Left error -> Left error
      Right epoch -> Right (Just (Sys.formatEpochIso (epoch + minutes * 60)))

-- | Resolve the named unfinished job with the parsed outcome. The reason
-- | requirement for non-completed outcomes is enforced inside
-- | `State.resolveJob`, so every path that ends a job carries it; the
-- | finish timestamp is driver-computed here.
runJobEnd :: WorkflowContext -> { id :: String, outcome :: State.JobOutcome, verification :: Maybe String } -> Effect Outcome.OpOutcome
runJobEnd context input = withLoadedState context \state -> do
  completed <- Sys.nowIso
  case State.resolveJob input.id input.outcome input.verification completed state of
    Left error -> pure (failText error)
    Right resolved -> do
      State.writeState (Context.statePath context) resolved
      -- A rolled-back finish was clamped up to the job's start inside
      -- `resolveJob`; surface that loudly so a clock problem is visible
      -- instead of silently rewriting the recorded duration.
      let clamped = case Array.find (\job -> not (State.jobFinished job) && job.id == input.id) state.jobs of
            Just job -> State.finishNeedsClamp job completed
            Nothing -> false
          clampNote = if clamped then " (clock rollback: finish clamped to start)" else ""
      pure (Outcome.withStdout ("job-end: " <> input.id <> " " <> State.renderJobOutcome input.outcome <> clampNote <> "\n"))

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
    Left error | not options.restart -> pure (failText ("do-driver: .do-results.json is corrupt or unreadable — " <> error <> "; restore it or run init --restart"))
    Right (Just state) | isActiveRun state && not options.restart ->
      pure (failWithCode 2 ("do-driver: a /do run is already active (task: '" <> State.stateGet "task" state <> "', steps: " <> show (Array.length state.steps) <> ") — finish it or run init --restart to discard it"))
    _ -> do
      timestamp <- Sys.nowIso
      -- --restart keeps unfinished worker jobs so a recovered run resumes the
      -- same liveness ledger; a plain init discards them with everything else
      -- from the prior run.
      let carriedJobs = case existing of
            Right (Just prior) | options.restart -> State.unfinishedJobs prior
            _ -> []
          base = (State.initState timestamp) { jobs = carriedJobs }
          vcsDetected = Vcs.vcsName context.vcs /= "unknown"
          isDefaultEntry = options.from == "" || options.from == "default"
          -- A prior base is inherited only when it names a ref. Absent, empty,
          -- or non-string values (hand-corrupted state) stay unset deliberately:
          -- the run proceeds and the missing-base diagnostic names the remedy
          -- rather than failing init over state it can continue without.
          priorBase = case existing of
            Right (Just prior) -> State.stateGetJson "base" prior >>= toString >>= Args.nonEmpty
            _ -> Nothing
          initialized = do
            withNoVcs <- State.setField "noVcs" (fromBoolean options.noVcs) base
            withReview <- State.setField "review" (fromBoolean options.review) withNoVcs
            withMinimal <- State.setField "minimal" (fromBoolean options.minimal) withReview
            withVcs <- if not vcsDetected then Right withMinimal else State.setField "vcs" (fromString (Vcs.vcsName context.vcs)) withMinimal
            withForge <- State.setField "forge" (fromString (Forge.forgeName context.forge)) withVcs
            withCapabilities <- putCapabilities context.forge withForge
            -- Runs that never persist a base (their entry point starts past
            -- sync) carry the prior run's resolved base forward so downstream
            -- VCS ops can protect the trunk (#87). The no-vcs sentinel names
            -- no ref and stays behind with --no-vcs runs.
            withBase <-
              if options.noVcs || not vcsDetected || isDefaultEntry then Right withCapabilities
              else case priorBase of
                Just prior | prior /= State.noVcsBaseValue -> State.setField "base" (fromString prior) withCapabilities
                _ -> Right withCapabilities
            withFrom <- if options.from == "" then Right withBase else State.setField "from" (fromString options.from) withBase
            if options.task == "" then Right withFrom else State.setField "task" (fromString options.task) withFrom
      case initialized of
        Left error -> pure (failText error)
        Right final -> do
          State.writeState (Context.statePath context) final
          let fromText = if isDefaultEntry then "default" else options.from
              -- A recovered run must see its pending work at once: when
              -- --restart carried jobs, name them on the init line's tail.
              carriedText =
                if Array.null carriedJobs then ""
                else
                  "carried unfinished job(s): "
                    <> joinWith ", " (map (\job -> "'" <> job.id <> "'") carriedJobs)
                    <> "\n"
          pure (Outcome.withStdout ("init: review=" <> show options.review <> " noVcs=" <> show options.noVcs <> " minimal=" <> show options.minimal <> " from=" <> fromText <> " vcs=" <> Vcs.vcsName context.vcs <> "\n" <> carriedText))

-- | `skip` is `step-start` + `step-end` under one lock, so its job guard
-- | must run against the state loaded BEFORE the first half writes: a
-- | refusal raised only inside `runStepEnd` would leave the `pendingStep`
-- | that `runStepStart` already persisted behind a failing skip, breaking
-- | the guard-must-not-mutate invariant on the composite operation.
runDriverSkip :: WorkflowContext -> String -> String -> Effect Outcome.OpOutcome
runDriverSkip context step reason = withLoadedState context \state -> case unfinishedJobBlocker "step-end" step state of
  Just blocker -> pure (failText blocker)
  Nothing -> do
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
  , "requireRemote"
  ]

failText :: String -> Outcome.OpOutcome
failText message = Outcome.failure 1 (message <> "\n")

failWithCode :: Int -> String -> Outcome.OpOutcome
failWithCode code message = Outcome.failure code (message <> "\n")
