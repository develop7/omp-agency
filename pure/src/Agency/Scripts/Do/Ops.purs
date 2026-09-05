module Agency.Scripts.Do.Ops
  ( ParseError
  , ResultsOp(..)
  , DriverOp(..)
  , SyncOp(..)
  , DoneOp(..)
  , NickelOp(..)
  , DoneRow
  , DoneSummary
  , parseResultsOp
  , parseDriverOp
  , parseSyncOp
  , parseDoneOp
  , parseNickelOp
  , resolveWorkflowContext
  , runResultsOp
  , runDriverOp
  , runSyncOp
  , runDoneOp
  , runNickelOp
  , computeDoneSummary
  , renderDoneMarkdown
  , renderFacts
  , renderDone
  , fmtDur
  , jsonValueFor
  , validInterval
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
import Agency.Scripts.Do.WorkflowVocabulary as Vocabulary
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Context as Context
import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs
import Data.Argonaut.Core (Json, fromBoolean, fromObject, fromString, jsonNull)
import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll, trim)
import Data.String.CodeUnits (drop)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Data.Int (floor)
import Foreign.Object as Obj
import Effect (Effect)

-- | Parse failures carry the legacy script's exit status and stderr text.
type ParseError =
  { code :: Int
  , message :: String
  }

-- | do-results command algebra.
data ResultsOp
  = ResultsInit
  | ResultsStepStart String
  | ResultsStepEnd String String (Maybe String)
  | ResultsStep String String String String String (Maybe String)
  | ResultsSet String String

-- | do-driver command algebra.
data DriverOp
  = DriverInit
      { review :: Boolean
      , noVcs :: Boolean
      , minimal :: Boolean
      , restart :: Boolean
      , from :: String
      , task :: String
      }
  | DriverStart String
  | DriverEnd String String (Maybe String)
  | DriverSkip String String
  | DriverSet String String
  | DriverSummary
-- | Parsed sync options. The parser enforces that noVcs, base, and stack
-- | combinations are valid; callers constructing this type directly bypass
-- | that boundary by design.
data SyncOp = Sync { noVcs :: Boolean, base :: Maybe String, stack :: Boolean }

-- | steps/done accepts no arguments.
data DoneOp = Done

-- | Nickel workflow command algebra.
data NickelOp = NickelCli | NickelCliSeed String

resultsCommandNames :: String
resultsCommandNames = "init|step-start|step-end|step|set"

resultsUsage :: String
resultsUsage = "Usage: do-results <" <> resultsCommandNames <> "> ..."

parseResultsOp :: Array String -> Either ParseError ResultsOp
parseResultsOp args =
  case Args.requiredNonEmpty args of
    Nothing -> Left (parseError 1 resultsUsage)
    Just { value: command, rest } -> case command of
      "init" -> Right ResultsInit
      "step-start" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "name required")
        Just { value: name } -> do
          validWorkflowStep name
          Right (ResultsStepStart name)
      "step-end" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "status required (passed|failed|skipped)")
        Just { value: status, rest: afterStatus } -> do
          validStepStatus status
          Right (ResultsStepEnd status (fromMaybe "" (Array.head afterStatus)) (Array.index afterStatus 1 >>= Args.nonEmpty))
      "step" -> case takeFive rest of
        Nothing -> Left (parseError 1 "name, status, verification, startedAt, and completedAt are required")
        Just { name, status, verification, startedAt, completedAt, tail: after } -> do
          validWorkflowStep name
          validStepStatus status
          Right (ResultsStep name status verification startedAt completedAt (Array.head after >>= Args.nonEmpty))
      "set" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "field required")
        Just { value: field, rest: after } -> case Args.requiredNonEmpty after of
          Nothing -> Left (parseError 1 "value required")
          Just { value } -> Right (ResultsSet field value)
      _ -> Left (parseError 1 ("Unknown command: " <> command <> "\n" <> resultsUsage))

takeFive :: Array String -> Maybe { name :: String, status :: String, verification :: String, startedAt :: String, completedAt :: String, tail :: Array String }
takeFive values = do
  name <- Args.requiredNonEmpty values
  status <- Args.requiredNonEmpty name.rest
  verification <- Array.uncons status.rest
  startedAt <- Args.requiredNonEmpty verification.tail
  completedAt <- Args.requiredNonEmpty startedAt.rest
  pure
    { name: name.value
    , status: status.value
    , verification: verification.head
    , startedAt: startedAt.value
    , completedAt: completedAt.value
    , tail: completedAt.rest
    }

parseDriverOp :: Array String -> Either ParseError DriverOp
parseDriverOp args =
  case Args.requiredNonEmpty args of
    Nothing -> Left (parseError 1 "Usage: do-driver <init|start|end|skip|set|summary> ...")
    Just { value: command, rest } -> case command of
      "init" -> parseDriverInit rest
      "start" -> requiredWorkflowStep "step required" DriverStart rest
      "end" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "status required (passed|failed|skipped)")
        Just { value: status, rest: after } -> do
          validStepStatus status
          Right (DriverEnd status (fromMaybe "" (Array.head after)) (Array.index after 1 >>= Args.nonEmpty))
      "skip" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "step required")
        Just { value: step, rest: after } -> do
          validWorkflowStep step
          case Args.requiredNonEmpty after of
            Nothing -> Left (parseError 1 "reason required")
            Just { value: reason } -> Right (DriverSkip step reason)
      "set" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "field required")
        Just { value: field, rest: after } -> case Args.requiredNonEmpty after of
          Nothing -> Left (parseError 1 "value required")
          Just { value } -> Right (DriverSet field value)
      "summary" -> Right DriverSummary
      _ -> Left (parseError 1 ("Unknown command: " <> command <> "\nUsage: do-driver <init|start|end|skip|set|summary> ..."))
  where
  requiredWorkflowStep message constructor values = case Args.requiredNonEmpty values of
    Just { value } -> do
      validWorkflowStep value
      Right (constructor value)
    Nothing -> Left (parseError 1 message)

parseDriverInit :: Array String -> Either ParseError DriverOp
parseDriverInit args = go args { review: false, noVcs: false, minimal: false, restart: false, from: "", task: "" }
  where
  go remaining state = case Array.uncons remaining of
    Nothing ->
      if state.review && state.from /= "" && state.from /= "default" then
        Left (parseError 2
          ("do-driver: --review is incompatible with --from=" <> state.from <> "\n"
            <> "         --from=" <> state.from <> " starts past research, where the plan-approval pause lives.\n"
            <> "         drop --review if the plan is already approved, or drop --from for a full workflow."))
      else Right (DriverInit state)
    Just { head: arg, tail: after } -> case arg of
      "--review" -> go after (state { review = true })
      "--no-vcs" -> go after (state { noVcs = true })
      "--minimal" -> go after (state { minimal = true })
      "--restart" -> go after (state { restart = true })
      "--base" -> Left (parseError 2 "do-driver: --base is a sync flag, not an init flag.\n         pass it to sync <true|false> --base <branch>, not to do-driver init.")
      "--stack" -> Left (parseError 2 "do-driver: --stack is a sync flag, not an init flag.\n         pass it to sync <true|false> --stack, not to do-driver init.")
      _ | Args.startsWith "--from=" arg -> case Args.nonEmpty (drop 7 arg) of
        Just from -> do
          validEntryPoint from
          go after (state { from = from })
        Nothing -> Left (parseError 2 "do-driver: --from requires a non-empty step")
      _ | Args.startsWith "--" arg -> Left (parseError 2 ("do-driver: unknown flag: " <> arg))
      _ | state.task /= "" -> Left (parseError 2 ("do-driver: multiple task arguments given (already have '" <> state.task <> "')"))
        | otherwise -> go after (state { task = arg })

parseSyncOp :: Array String -> Either ParseError SyncOp
parseSyncOp args = do
  parsed <- go args { noVcs: Nothing, base: Nothing, stack: false }
  case parsed.noVcs of
    Nothing -> Left (parseError 2 "sync: noVcs is required (true or false)\nUsage: sync <noVcs> [--base <branch> | --stack]")
    Just noVcs ->
      if parsed.base /= Nothing && parsed.stack then Left (parseError 2 "sync: --base and --stack are mutually exclusive")
      else if noVcs && (parsed.base /= Nothing || parsed.stack) then
        Left (parseError 2 "sync: --base/--stack are incompatible with --no-vcs\n       --no-vcs skips branch/commit/PR; the base has no effect.")
      else Right (Sync { noVcs, base: parsed.base, stack: parsed.stack })
  where
  go remaining state = case Array.uncons remaining of
    Nothing -> Right state
    Just { head: arg, tail: after } -> case arg of
      "--stack" ->
        if state.stack then Left (parseError 2 "sync: --stack may be passed only once")
        else go after (state { stack = true })
      "--base" -> case Args.requiredNonEmpty after of
        Nothing -> Left (parseError 2 "sync: --base requires a branch argument")
        Just { value: branch, rest } ->
          if state.base /= Nothing then Left (parseError 2 "sync: --base may be passed only once")
          else go rest (state { base = Just branch })
      _ | Args.startsWith "--" arg -> Left (parseError 2 ("sync: unknown flag: " <> arg <> "\nUsage: sync <noVcs> [--base <branch> | --stack]"))
      _ -> case parseBoolean arg of
        Nothing -> Left (parseError 2 ("sync: noVcs must be 'true' or 'false', got '" <> arg <> "'"))
        Just value -> case state.noVcs of
          Just _ -> Left (parseError 2 "sync: noVcs may be passed only once")
          Nothing -> go after (state { noVcs = Just value })

parseBoolean :: String -> Maybe Boolean
parseBoolean value = case value of
  "true" -> Just true
  "false" -> Just false
  _ -> Nothing
parseDoneOp :: Array String -> Either ParseError DoneOp
parseDoneOp args =
  if Array.null args then Right Done
  else Left (parseError 1 "done: this command accepts no arguments")

parseNickelOp :: Array String -> Either ParseError NickelOp
parseNickelOp args = case Args.requiredNonEmpty args of
  Nothing -> Left (parseError 2 "Usage: nickel-cli <cli|cli_seed> [args...]")
  Just { value: command, rest } -> case command of
    "cli" | Array.null rest -> Right NickelCli
    "cli" -> Left (parseError 2 "nickel-cli: cli accepts no arguments")
    "cli_seed" -> case Args.requiredNonEmpty rest of
      Nothing -> Left (parseError 2 "nickel-cli: cli_seed requires an entry point")
      Just { value: from, rest: after } -> do
        validEntryPoint from
        if Array.null after then Right (NickelCliSeed from)
        else Left (parseError 2 "nickel-cli: cli_seed accepts one entry point")
    _ -> Left (parseError 2 ("nickel-cli: unknown field: " <> command))

validEntryPoint :: String -> Either ParseError Unit
validEntryPoint entry =
  if Array.elem entry Vocabulary.entryPoints then Right unit
  else Left (parseError 2 ("do-driver: unknown --from entry point '" <> entry <> "' (allowed: " <> joinWith ", " Vocabulary.entryPoints <> ")"))

validWorkflowStep :: String -> Either ParseError Unit
validWorkflowStep step =
  if Array.elem step Vocabulary.workflowSteps then Right unit
  else Left (parseError 2 ("do-driver: unknown step '" <> step <> "' (steps: " <> joinWith ", " Vocabulary.workflowSteps <> ")"))

validStepStatus :: String -> Either ParseError Unit
validStepStatus status =
  if Array.elem status [ "passed", "failed", "skipped" ] then Right unit
  else Left (parseError 1 ("do-results: invalid status '" <> status <> "' (passed|failed|skipped)"))

parseError :: Int -> String -> ParseError
parseError code message = { code, message }

resolveWorkflowContext :: Boolean -> Effect (Either String WorkflowContext)
resolveWorkflowContext captureOutput = do
  root <- Sys.cwd
  vcsOverrideText <- Sys.getEnv "VCS_OVERRIDE"
  forgeOverrideText <- Sys.getEnv "FORGE_OVERRIDE"
  stateResult <- State.readState (root <> "/.do-results.json")
  case stateResult of
    Left error -> pure (Left ("workflow: .do-results.json is corrupt or unreadable — " <> error <> "; restore it or run do-driver init --restart"))
    Right state -> do
      jjPresent <- Sys.isDir (root <> "/.jj")
      gitPresent <- Sys.isDir (root <> "/.git")
      let stateVcs = state >>= Args.nonEmpty <<< State.stateGet "vcs"
          stateForge = state >>= Args.nonEmpty <<< State.stateGet "forge"
          vcsOverride = case stateVcs of
            Just _ -> Nothing
            Nothing -> Args.nonEmpty vcsOverrideText
          forgeOverride = case stateForge of
            Just _ -> Nothing
            Nothing -> Args.nonEmpty forgeOverrideText
          base = state >>= Args.nonEmpty <<< State.stateGet "base"
          vcs = Vcs.detectVcs vcsOverride stateVcs jjPresent gitPresent
          partial = { stateDir: root, vcs, forge: Forge.Unknown, base, vcsOverride, forgeOverride, captureOutput }
      remote <- Vcs.remoteUrlValue partial
      let forge = Forge.detectForge forgeOverride stateForge remote
      pure (Right (partial { forge = forge }))
runResultsOp :: WorkflowContext -> ResultsOp -> Effect Outcome.OpOutcome
runResultsOp context operation = case operation of
  ResultsInit -> do
    timestamp <- Sys.nowIso
    State.writeState (Context.statePath context) (State.initState timestamp)
    pure (Outcome.withStdout ("init: startedAt=" <> timestamp <> "\n"))
  ResultsStepStart name -> withLoadedState context \state -> case state.pendingStep of
    Just pending -> pure (failText ("do-results: pendingStep '" <> pending.name <> "' already active — call step-end before starting '" <> name <> "'"))
    Nothing -> do
      timestamp <- Sys.nowIso
      State.writeState (Context.statePath context) (State.startPending { name, startedAt: timestamp } state)
      pure (Outcome.withStdout ("pending: " <> name <> "\n"))
  ResultsStepEnd status verification reason -> withLoadedState context \state -> case state.pendingStep of
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
  ResultsStep name status verification startedAt completedAt reason -> withLoadedState context \state -> do
    actualStart <- resolveNow startedAt
    actualEnd <- resolveNow completedAt
    timing <- validInterval actualStart actualEnd
    case timing of
      Left error -> pure (failText error)
      Right _ -> do
        let updated = terminalize name status (State.appendStep { name, status: State.parseStepStatus status, verification, startedAt: actualStart, completedAt: actualEnd, reason } state)
        State.writeState (Context.statePath context) updated
        pure (Outcome.withStdout ("recorded: " <> name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ")\n"))
  ResultsSet field value -> withLoadedState context \state -> do
    let updated = do
          json <- jsonValueFor field value
          State.setField field json state
    case updated of
      Left error -> pure (failText error)
      Right final -> do
        State.writeState (Context.statePath context) final
        pure (Outcome.withStdout ("set: " <> field <> "=" <> value <> "\n"))

withLoadedState :: WorkflowContext -> (State.State -> Effect Outcome.OpOutcome) -> Effect Outcome.OpOutcome
withLoadedState context action = do
  loaded <- loadState context
  case loaded of
    Left error -> pure (failText error)
    Right state -> action state
runDriverOp :: WorkflowContext -> DriverOp -> Effect Outcome.OpOutcome
runDriverOp context operation = case operation of
  DriverInit options -> do
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
            pure (Outcome.withStdout ("init: review=" <> boolText options.review <> " noVcs=" <> boolText options.noVcs <> " minimal=" <> boolText options.minimal <> " from=" <> fromText <> " vcs=" <> Vcs.vcsName context.vcs <> "\n"))
  DriverStart step -> runResultsOp context (ResultsStepStart step)
  DriverEnd status verification reason -> runResultsOp context (ResultsStepEnd status verification reason)
  DriverSkip step reason -> do
    started <- runResultsOp context (ResultsStepStart step)
    if started.exit /= 0 then pure started
    else do
      ended <- runResultsOp context (ResultsStepEnd "skipped" "" (Args.nonEmpty reason))
      pure (Outcome.append started ended)
  DriverSet field value -> runResultsOp context (ResultsSet field value)
  DriverSummary -> runDoneOp context Done

boolText :: Boolean -> String
boolText value = if value then "true" else "false"

isActiveRun :: State.State -> Boolean
isActiveRun state =
  state.active == State.ActiveWorking || state.active == State.ActiveWaiting

terminalize :: String -> String -> State.State -> State.State
terminalize name status state =
  if name /= "done" then state
  else State.finishWorkflow (if status == "failed" then State.WorkflowFailed else State.WorkflowCompleted) state
-- | Validate exact UTC timestamps before recording a completed step.

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

putCapabilities :: Forge.ForgeKind -> State.State -> Either String State.State
putCapabilities forge state = do
  withCreate <- State.setField "supportsPrCreate" (fromBoolean (Forge.supports forge "pr-create")) state
  withComment <- State.setField "supportsPrComment" (fromBoolean (Forge.supports forge "pr-comment")) withCreate
  withIssue <- State.setField "supportsIssueView" (fromBoolean (Forge.supports forge "issue-view")) withComment
  State.setField "supportsPrChecks" (fromBoolean (Forge.supports forge "pr-checks")) withIssue
-- | Execute sync in named phases so each subprocess boundary has one failure
-- | path and the successful protocol retains the incumbent ordering.
runSyncOp :: WorkflowContext -> SyncOp -> Effect Outcome.OpOutcome
runSyncOp context operation@(Sync options) = do
  startedAt <- Sys.nowIso
  fetched <- fetchPhase context options.noVcs
  case fetched of
    Left outcome -> failSync context outcome
    Right phases -> do
      inspected <- if options.noVcs then pure Vcs.Clean else Vcs.inspectDirty context
      case inspected of
        Vcs.InspectionFailed outcome -> failSync context (Outcome.append (phaseOutput phases) outcome)
        _ -> do
          resolvedContext <- resolveContext context operation startedAt
          case resolvedContext of
            Left outcome -> failSync context outcome
            Right state1 -> do
              resolved <- basePhase context operation state1
              case resolved of
                Left outcome -> failSync context outcome
                Right base -> do
                  let dirtyWarning = case inspected of
                        Vcs.DirtyDetected ->
                          Outcome.failure 0 "Dirty tree detected. Continuing will create a fresh branch on top of these changes. If you wanted the agent to extend your WIP in place without touching git, re-run with --no-vcs.\n"
                        _ -> Outcome.success
                  protocol <- recordPhase context operation startedAt base
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
    Right (Just state) ->
      State.writeState (Context.statePath context) (State.finishWorkflow State.WorkflowFailed state)
    _ -> pure unit
  pure outcome


resolveContext :: WorkflowContext -> SyncOp -> String -> Effect (Either Outcome.OpOutcome State.State)
resolveContext context (Sync options) startedAt = do
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

basePhase :: WorkflowContext -> SyncOp -> State.State -> Effect (Either Outcome.OpOutcome SyncBase)
basePhase context operation state1 = do
  branchResult <- Vcs.headRevisionValue context
  defaultResult <- Vcs.defaultBranchValue context
  if branchResult.code /= 0 then pure (Left (vcsValueOutcome branchResult))
  else if defaultResult.code /= 0 then pure (Left (vcsValueOutcome defaultResult))
  else do
    baseResult <- resolveSyncBase operation defaultResult.value context
    case baseResult of
      Left error -> pure (Left (failWithCode 2 error))
      Right base -> case State.setField "base" (fromString base) state1 of
        Left error -> pure (Left (failText ("sync: " <> error)))
        Right state2 -> pure (Right { state: state2, branch: branchResult, defaultRef: defaultResult.value, base })

recordPhase :: WorkflowContext -> SyncOp -> String -> SyncBase -> Effect Outcome.OpOutcome
recordPhase context (Sync options) startedAt resolved = do
  completed <- Sys.nowIso
  let contextWithBase = context { base = Just resolved.base }
      fetchState = if options.noVcs then "fetch skipped" else "fetch ok"
      step =
        { name: "sync"
        , status: State.StepPassed
        , verification: fetchState <> "; vcs=" <> Vcs.vcsName context.vcs <> "; forge=" <> Forge.forgeName context.forge <> "; noVcs=" <> boolText options.noVcs <> "; base=" <> resolved.base
        , startedAt
        , completedAt: completed
        , reason: Nothing
        }
  State.writeState (Context.statePath context) (State.appendStep step resolved.state)
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
  putCapabilities context.forge withNoVcs
resolveSyncBase :: SyncOp -> String -> WorkflowContext -> Effect (Either String String)
resolveSyncBase (Sync options) defaultRef context = case options.base of
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

runDoneOp :: WorkflowContext -> DoneOp -> Effect Outcome.OpOutcome
runDoneOp context Done = do
  loaded <- loadState context
  case loaded of
    Left error -> pure (failText (if Args.startsWith "do-results: " error then "done: " <> drop 12 error else error))
    Right state -> do
      summary <- computeDoneSummary state
      case summary of
        Left error -> pure (failText ("done: " <> error))
        Right value -> pure (Outcome.withStdout (renderDoneMarkdown value <> renderFacts value))

-- | A row contains facts needed by both markdown and machine-readable output.
type DoneRow =
  { step :: State.Step
  , seconds :: Int
  }

-- | Computed done facts, independent from either output representation.
type DoneSummary =
  { rows :: Array DoneRow
  , pending :: Maybe { name :: String, seconds :: Int }
  , totalSeconds :: Int
  , slowest :: Maybe (Tuple String Int)
  , dominant :: Array String
  , skipped :: Array String
  , failed :: Array String
  }

-- | Compute all duration and status facts, failing on malformed timestamps.
computeDoneSummary :: State.State -> Effect (Either String DoneSummary)
computeDoneSummary state = do
  now <- Sys.nowIso
  let firstStarted = case Array.head state.steps of
        Just step -> step.startedAt
        Nothing -> case state.pendingStep of
          Just pending -> pending.startedAt
          Nothing -> state.startedAt
      lastCompleted = case state.pendingStep of
        Just _ -> now
        Nothing -> case Array.last state.steps of
          Just step -> step.completedAt
          Nothing -> state.startedAt
  totalStart <- Sys.isoToEpoch firstStarted
  totalEnd <- Sys.isoToEpoch lastCompleted
  timedResults <- traverse timedStep state.steps
  pendingResult <- traverse (timedPending now) state.pendingStep
  pure do
    started <- totalStart
    completed <- totalEnd
    timed <- traverse identity timedResults
    pending <- traverse identity pendingResult
    let totalDuration = max 0 (completed - started)
        nonSkipped = Array.filter (\item -> item.step.status /= State.StepSkipped) timed
        durations = map (\item -> Tuple item.step item.seconds) nonSkipped
        slowest = slowestStep durations
        dominant = Array.mapMaybe (dominantName totalDuration) durations
        skipped = map (skippedName <<< _.step) (Array.filter (\item -> item.step.status == State.StepSkipped) timed)
        failed = map (_.step >>> _.name) (Array.filter (\item -> item.step.status == State.StepFailed) timed)
    pure { rows: timed, pending, totalSeconds: totalDuration, slowest, dominant, skipped, failed }

-- | Render the human-facing markdown table and slowest-step line.
renderDoneMarkdown :: DoneSummary -> String
renderDoneMarkdown summary =
  let completedRows = map (renderTimedRow summary.totalSeconds) summary.rows
      pendingRows = case summary.pending of
        Nothing -> []
        Just pending -> [ "| " <> pending.name <> " | ⋯ | " <> fmtDur pending.seconds <> " | (in progress) |" ]
      rows = completedRows <> pendingRows
      table = "| Step | Status | Duration | Verification |\n"
        <> "|------|--------|----------|--------------|\n"
        <> joinWith "\n" rows
        <> (if Array.null rows then "" else "\n")
        <> "| **Total** | | **" <> fmtDur summary.totalSeconds <> "** | |\n\n"
      slowLine = case summary.slowest of
        Nothing -> ""
        Just (Tuple name seconds) -> "**Slowest step**: `" <> name <> "` (" <> fmtDur seconds <> ")\n"
  in table <> slowLine <> "\n"

-- | Render the machine-readable facts block for the same computed summary.
renderFacts :: DoneSummary -> String
renderFacts summary =
  let slowestName = case summary.slowest of
        Nothing -> ""
        Just (Tuple name _) -> name
      slowestSeconds = case summary.slowest of
        Nothing -> 0
        Just (Tuple _ seconds) -> seconds
      pendingName = case summary.pending of
        Nothing -> ""
        Just pending -> pending.name
  in "\n<<<FACTS\n"
    <> "totalSeconds=" <> show summary.totalSeconds <> "\n"
    <> "slowestStep=" <> slowestName <> "\n"
    <> "slowestSeconds=" <> show slowestSeconds <> "\n"
    <> "dominantSteps=" <> joinWith "," summary.dominant <> "\n"
    <> "skippedSteps=" <> joinWith "," summary.skipped <> "\n"
    <> "failedSteps=" <> joinWith "," summary.failed <> "\n"
    <> "pendingStep=" <> pendingName <> "\n"
    <> "FACTS\n"

-- | Compatibility wrapper for callers that supply an explicit total duration.
renderDone :: State.State -> Int -> Effect String
renderDone state totalDuration = do
  summary <- computeDoneSummary state
  pure case summary of
    Left error -> "done: " <> error <> "\n"
    Right value ->
      let overridden = value { totalSeconds = totalDuration }
      in renderDoneMarkdown overridden <> renderFacts overridden

timedStep :: State.Step -> Effect (Either String DoneRow)
timedStep step = do
  started <- Sys.isoToEpoch step.startedAt
  completed <- Sys.isoToEpoch step.completedAt
  pure do
    start <- started
    end <- completed
    pure { step, seconds: max 0 (end - start) }

timedPending :: String -> State.PendingStep -> Effect (Either String { name :: String, seconds :: Int })
timedPending now pending = do
  started <- Sys.isoToEpoch pending.startedAt
  ended <- Sys.isoToEpoch now
  pure do
    start <- started
    end <- ended
    pure { name: pending.name, seconds: max 0 (end - start) }

renderTimedRow :: Int -> DoneRow -> String
renderTimedRow totalDuration item =
  let step = item.step
      seconds = item.seconds
      icon = case step.status of
        State.StepPassed -> "✓"
        State.StepFailed -> "✗"
        State.StepSkipped -> "—"
        State.StepUnknown _ -> "?"
      bold = step.status /= State.StepSkipped && totalDuration > 0 && (seconds * 100 `div` totalDuration) >= 30
      durationText = if bold then "**" <> fmtDur seconds <> "**" else fmtDur seconds
      verification = escapeVerification step.verification
  in "| " <> step.name <> " | " <> icon <> " | " <> durationText <> " | " <> verification <> " |"

slowestStep :: Array (Tuple State.Step Int) -> Maybe (Tuple String Int)
slowestStep values = go values Nothing
  where
  go remaining best = case Array.uncons remaining of
    Nothing -> best
    Just { head: Tuple step seconds, tail } ->
      let next = case best of
            Nothing -> Just (Tuple step.name seconds)
            Just (Tuple name current) -> if seconds > current then Just (Tuple step.name seconds) else Just (Tuple name current)
      in go tail next

dominantName :: Int -> Tuple State.Step Int -> Maybe String
dominantName totalDuration (Tuple step seconds) =
  if totalDuration > 0 && (seconds * 100 `div` totalDuration) >= 30 then Just step.name else Nothing

skippedName :: State.Step -> String
skippedName step = step.name <> ":" <> fromMaybe "unspecified" step.reason

fmtDur :: Int -> String
fmtDur seconds = if seconds < 60 then show seconds <> "s" else show (seconds `div` 60) <> "m " <> show (seconds `mod` 60) <> "s"

escapeVerification :: String -> String
escapeVerification value = replaceAll (Pattern "|") (Replacement "\\|") (replaceAll (Pattern "\n") (Replacement " ") value)

-- | Run a workflow operation through the Node bridge, which always captures
-- | subprocess output and returns a JSON-encoded exit/stdout/stderr result.
-- | The context's captureOutput flag is intentionally ignored for this path:
-- | the bridge communicates over stdin/stdout and cannot inherit streams.
runNickelOp :: WorkflowContext -> NickelOp -> Effect Outcome.OpOutcome
runNickelOp context operation = do
  state <- State.readState (Context.statePath context)
  case state of
    Left error -> pure (failText ("nickel-cli: .do-results.json is corrupt or unreadable — " <> error <> "; restore it or run do-driver init --restart"))
    Right Nothing -> pure (failText "nickel-cli: no .do-results.json in the current directory — run do-driver init first (from the repository root)")
    Right (Just _) -> runNickelLoaded context operation
runNickelLoaded :: WorkflowContext -> NickelOp -> Effect Outcome.OpOutcome
runNickelLoaded context operation = do
  bundle <- Sys.bundleDir
  let bundleWorkflow = bundle <> "/../../skills/do/workflow.ncl"
      adjacentWorkflow = bundle <> "/../../../skills/do/workflow.ncl"
      cwdWorkflow = context.stateDir <> "/skills/do/workflow.ncl"
      bundleVocabulary = bundle <> "/../../skills/do/workflow-manifest.json"
      adjacentVocabulary = bundle <> "/../../../skills/do/workflow-manifest.json"
      cwdVocabulary = context.stateDir <> "/skills/do/workflow-manifest.json"
      bridge = bundle <> "/../../nickel-vm/scripts/cli-bridge.mjs"
  bundleExists <- Sys.exists bundleWorkflow
  adjacentExists <- Sys.exists adjacentWorkflow
  let workflowPath =
        if bundleExists then bundleWorkflow
        else if adjacentExists then adjacentWorkflow
        else cwdWorkflow
      vocabularyPath =
        if bundleExists then bundleVocabulary
        else if adjacentExists then adjacentVocabulary
        else cwdVocabulary
  workflow <- Sys.realpath workflowPath
  workflowSource <- Sys.readUtf8 workflow
  vocabularySource <- Sys.readUtf8 vocabularyPath
  stateSource <- Sys.readUtf8 (Context.statePath context)
  let operationName = case operation of
        NickelCli -> "cli"
        NickelCliSeed _ -> "cli_seed"
      seedJson = case operation of
        NickelCli -> jsonNull
        NickelCliSeed from -> fromString from
      request = Json.stringify
        (fromObject
          (Obj.fromFoldable
            [ Tuple "workflow_source" (fromString workflowSource)
            , Tuple "state_source" (fromString stateSource)
            , Tuple "operation" (fromString operationName)
            , Tuple "vocabulary_source" (fromString vocabularySource)
            , Tuple "seed" seedJson
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


loadState :: WorkflowContext -> Effect (Either String State.State)
loadState context = do
  result <- State.readState (Context.statePath context)
  pure case result of
    Left error -> Left ("do-results: .do-results.json is corrupt or unreadable — " <> error <> "; restore it or run do-results init --restart")
    Right Nothing -> Left "do-results: .do-results.json not found — run do-results init first"
    Right (Just state) -> Right state

resolveNow :: String -> Effect String
resolveNow value = if value == "now" then Sys.nowIso else pure value

jsonValueFor :: String -> String -> Either String Json
jsonValueFor field value
  | field == "steps" || field == "pendingStep" = jsonParser value
  | Array.elem field booleanFields = case value of
      "true" -> Right (fromBoolean true)
      "false" -> Right (fromBoolean false)
      _ -> Left ("do-results: field '" <> field <> "' must be true or false")
  | otherwise = Right (fromString value)

booleanFields :: Array String
booleanFields =
  [ "review", "noVcs", "minimal", "hasEvidence"
  , "supportsPrCreate", "supportsPrComment", "supportsIssueView", "supportsPrChecks"
  ]


vcsValueOutcome :: Vcs.VcsValue -> Outcome.OpOutcome
vcsValueOutcome = Vcs.renderValue

failText :: String -> Outcome.OpOutcome
failText message = Outcome.failure 1 (message <> "\n")

failWithCode :: Int -> String -> Outcome.OpOutcome
failWithCode code message = Outcome.failure code (message <> "\n")
