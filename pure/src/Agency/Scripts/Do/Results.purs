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
  , ciVerification
  , putCapabilities
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
import Agency.Scripts.Do.Binaries as Binaries
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Context as Context
import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs
import Data.Argonaut.Core (Json, fromBoolean, fromString)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Array (cons) as Array
import Data.Array as Array
import Data.String (Pattern(..), drop, indexOf, split, take, trim)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
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
  Just pending -> case ciVerification pending.name status verification of
    Left error -> pure (failText error)
    Right _ -> do
      completed <- Sys.nowIso
      timing <- validInterval pending.startedAt completed
      let step = { name: pending.name, status: State.parseStepStatus status, verification, startedAt: pending.startedAt, completedAt: completed, reason }
      case timing >>= \_ -> State.appendStep step state of
        Left error -> pure (failText error)
        Right appended -> do
          let updated = terminalize pending.name status (State.finishPending appended)
          State.writeState (Context.statePath context) updated
          pure (Outcome.withStdout ("recorded: " <> pending.name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ", pending=none)\n"))

-- | The ci step records local and remote CI coverage as separate structured
-- | facts (issue #60). A ci step-end verification string must carry
-- | `local=<passed|failed|not-run>`, `remote=<passed|failed|pending|none|
-- | unavailable>`, and `head=<sha>` — whitespace-separated, any order. `local`
-- | is the local CI command's outcome; `remote` is the forge PR-check outcome
-- | (`none` when the PR reports no checks, `unavailable` when PR checks cannot
-- | be consulted, e.g. unsupported forge or no PR); `head` is the commit SHA
-- | the remote checks were observed against. A successful local command never
-- | implies a remote check; the two facts travel separately.
-- |
-- | The one empty-`head` exception is skipped-semantics —
-- | `local=not-run remote=unavailable` — emitted when the step is skipped and
-- | no VCS revision exists to attribute; it is accepted only for a `skipped`
-- | status. A recorded pass or fail with an empty head is exactly the
-- | ambiguity issue #60 is about, so it stays rejected.
ciVerification :: String -> String -> String -> Either String Unit
ciVerification name status verification
  | name /= "ci" = Right unit
  | otherwise = do
      fields <- parseFields verification
      local <- enumField "local" [ "passed", "failed", "not-run" ] fields
      remote <- enumField "remote" [ "passed", "failed", "pending", "none", "unavailable" ] fields
      headField local remote fields
  where
  parseFields value =
    let fields = Array.mapMaybe splitField (split (Pattern " ") value)
    in if Array.null fields
      then Left missingSpec
      else case duplicateKey fields of
        Just key -> Left ("do-results: ci verification has duplicate '" <> key <> "=' — " <> specText)
        Nothing -> Right fields
  splitField value = case indexOf (Pattern "=") value of
    Just index | index > 0 -> Just (Tuple (take index value) (drop (index + 1) value))
    _ -> Nothing
  duplicateKey fields = case Array.findMap (\(Tuple k _) -> if seenDuplicate fields k then Just k else Nothing) fields of
    Just key -> Just key
    Nothing -> Nothing
  seenDuplicate fields key = (Array.length (Array.filter (\(Tuple k _) -> k == key) fields)) > 1
  enumField key allowed fields = case Array.find (\(Tuple k _) -> k == key) fields of
    Nothing -> Left ("do-results: ci verification is missing '" <> key <> "=' — " <> specText)
    Just (Tuple _ value) | Array.elem value allowed -> Right value
    Just (Tuple _ value) -> Left ("do-results: ci verification has invalid '" <> key <> "' value '" <> value <> "' — " <> specText)
  headField local remote fields = case Array.find (\(Tuple k _) -> k == "head") fields of
    Just (Tuple _ sha) | sha /= "" -> Right unit
    Just (Tuple _ "") | status == "skipped" && skippedSemantics -> Right unit
    Just (Tuple _ value) -> Left ("do-results: ci verification has invalid 'head' value '" <> value <> "' — " <> specText)
    Nothing -> Left ("do-results: ci verification is missing 'head=' — " <> specText)
    where
    skippedSemantics = local == "not-run" && remote == "unavailable"
  specText = "expected `local=<passed|failed|not-run> remote=<passed|failed|pending|none|unavailable> head=<sha>`"
  missingSpec = "do-results: ci requires structured facts in the verification string — " <> specText

runStep :: WorkflowContext -> String -> String -> String -> String -> String -> Maybe String -> Effect Outcome.OpOutcome
runStep context name status verification startedAt completedAt reason = withLoadedState context \state ->
  case ciVerification name status verification of
    Left error -> pure (failText error)
    Right _ -> do
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
    facts <- ciSkipVerification context step
    ended <- case facts of
      Just structured -> runStepEnd context "skipped" structured (Args.nonEmpty reason)
      Nothing -> runStepEnd context "skipped" "" (Args.nonEmpty reason)
    pure (Outcome.append started ended)

-- | A skipped ci step still records the structured facts: the local command
-- | was not run and no PR check can be consulted for the current head. The
-- | head SHA is best-effort: when the VCS query fails (or no VCS exists) the
-- | record keeps the documented empty-`head` skip form so the skip still
-- | round-trips; the gate accepts an empty head only for these not-run/
-- | unavailable facts, so this failure is never confusable with a recorded
-- | pass or fail.
ciSkipVerification :: WorkflowContext -> String -> Effect (Maybe String)
ciSkipVerification context step
  | step /= "ci" = pure Nothing
  | otherwise = do
      let { command, args } = Vcs.headShaCommand context.vcs
      shaResult <- if command == "" then pure { code: 1, stdout: "", stderr: "" } else Sys.exec command args
      let sha = if shaResult.code == 0 then trim shaResult.stdout else ""
      pure (Just ("local=not-run remote=unavailable head=" <> sha))

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
