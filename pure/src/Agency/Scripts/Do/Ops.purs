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
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll, trim)
import Data.String.CodeUnits (drop)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
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
      "step-start" -> requiredOne "name required" ResultsStepStart rest
      "step-end" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "status required (passed|failed|skipped)")
        Just { value: status, rest: afterStatus } ->
          Right (ResultsStepEnd status (fromMaybe "" (Array.head afterStatus)) (Array.index afterStatus 1 >>= Args.nonEmpty))
      "step" -> case takeFive rest of
        Nothing -> Left (parseError 1 "name, status, verification, startedAt, and completedAt are required")
        Just { name, status, verification, startedAt, completedAt, tail: after } ->
          Right (ResultsStep name status verification startedAt completedAt (Array.head after >>= Args.nonEmpty))
      "set" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "field required")
        Just { value: field, rest: after } -> case Args.requiredNonEmpty after of
          Nothing -> Left (parseError 1 "value required")
          Just { value } -> Right (ResultsSet field value)
      _ -> Left (parseError 1 ("Unknown command: " <> command <> "\n" <> resultsUsage))
  where
  requiredOne message constructor values = case Args.requiredNonEmpty values of
    Just { value } -> Right (constructor value)
    Nothing -> Left (parseError 1 message)

takeFive :: Array String -> Maybe { name :: String, status :: String, verification :: String, startedAt :: String, completedAt :: String, tail :: Array String }
takeFive values = do
  name <- Args.requiredNonEmpty values
  status <- Args.requiredNonEmpty name.rest
  verification <- Args.requiredNonEmpty status.rest
  startedAt <- Args.requiredNonEmpty verification.rest
  completedAt <- Args.requiredNonEmpty startedAt.rest
  pure
    { name: name.value
    , status: status.value
    , verification: verification.value
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
      "start" -> requiredOne "step required" DriverStart rest
      "end" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "status required")
        Just { value: status, rest: after } -> Right (DriverEnd status (fromMaybe "" (Array.head after)) (Array.index after 1 >>= Args.nonEmpty))
      "skip" -> case Args.requiredNonEmpty rest of
        Nothing -> Left (parseError 1 "step required")
        Just { value: step, rest: after } -> case Args.requiredNonEmpty after of
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
  requiredOne message constructor values = case Args.requiredNonEmpty values of
    Just { value } -> Right (constructor value)
    Nothing -> Left (parseError 1 message)

parseDriverInit :: Array String -> Either ParseError DriverOp
parseDriverInit args = go args { review: false, noVcs: false, minimal: false, from: "", task: "" }
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
      "--base" -> Left (parseError 2 "do-driver: --base is a sync flag, not an init flag.\n         pass it to 'bash scripts/steps/sync', not to 'do-driver init'.")
      "--stack" -> Left (parseError 2 "do-driver: --stack is a sync flag, not an init flag.\n         pass it to 'bash scripts/steps/sync', not to 'do-driver init'.")
      _ | Args.startsWith "--from=" arg -> case Args.nonEmpty (drop 7 arg) of
        Just from -> go after (state { from = from })
        Nothing -> Left (parseError 2 "do-driver: --from requires a non-empty step")
      _ | Args.startsWith "--" arg -> Left (parseError 2 ("do-driver: unknown flag: " <> arg))
      _ -> go after (state { task = arg })

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
      "--stack" -> go after (state { stack = true })
      "--base" -> case Args.requiredNonEmpty after of
        Nothing -> Left (parseError 2 "sync: --base requires a branch argument")
        Just { value: branch, rest } -> go rest (state { base = Just branch })
      _ | Args.startsWith "--" arg -> Left (parseError 2 ("sync: unknown flag: " <> arg <> "\nUsage: sync <noVcs> [--base <branch> | --stack]"))
      _ -> case parseBoolean arg of
        Nothing -> Left (parseError 2 ("sync: noVcs must be 'true' or 'false', got '" <> arg <> "'"))
        Just value -> go after (state { noVcs = Just value })

parseBoolean :: String -> Maybe Boolean
parseBoolean value = case value of
  "true" -> Just true
  "false" -> Just false
  _ -> Nothing

parseDoneOp :: Array String -> Either ParseError DoneOp
parseDoneOp _ = Right Done

parseNickelOp :: Array String -> Either ParseError NickelOp
parseNickelOp args = case Args.requiredNonEmpty args of
  Nothing -> Left (parseError 2 "Usage: nickel-cli <cli|cli_seed> [args...]")
  Just { value: command, rest } -> case command of
    "cli" -> Right NickelCli
    "cli_seed" -> Right (NickelCliSeed (fromMaybe "" (Array.head rest)))
    _ -> Left (parseError 2 ("nickel-cli: unknown field: " <> command))

parseError :: Int -> String -> ParseError
parseError code message = { code, message }

-- | Resolve all process/state/filesystem inputs once for one adapter request.
-- | A present but unreadable state file is a hard error; only ENOENT is absent.
resolveWorkflowContext :: Boolean -> Effect (Either String WorkflowContext)
resolveWorkflowContext captureOutput = do
  root <- Sys.cwd
  vcsOverrideText <- Sys.getEnv "VCS_OVERRIDE"
  forgeOverrideText <- Sys.getEnv "FORGE_OVERRIDE"
  stateResult <- State.readState (root <> "/.do-results.json")
  case stateResult of
    Left error -> pure (Left ("vcs-op: .do-results.json unreadable: " <> error))
    Right state -> do
      jjPresent <- Sys.isDir (root <> "/.jj")
      gitPresent <- Sys.isDir (root <> "/.git")
      let override = Args.nonEmpty vcsOverrideText
          forgeOverride = Args.nonEmpty forgeOverrideText
          stateVcs = state >>= Args.nonEmpty <<< State.stateGet "vcs"
          stateForge = state >>= Args.nonEmpty <<< State.stateGet "forge"
          base = state >>= Args.nonEmpty <<< State.stateGet "base"
          vcs = Vcs.detectVcs override stateVcs jjPresent gitPresent
          partial = { stateDir: root, vcs, forge: Forge.Unknown, base, vcsOverride: override, forgeOverride, captureOutput }
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
      let step = { name: pending.name, status: State.parseStepStatus status, verification, startedAt: pending.startedAt, completedAt: completed, reason }
          updated = State.finishPending (State.appendStep step state)
      State.writeState (Context.statePath context) updated
      pure (Outcome.withStdout ("recorded: " <> pending.name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ", pending=none)\n"))
  ResultsStep name status verification startedAt completedAt reason -> withLoadedState context \state -> do
    actualStart <- resolveNow startedAt
    actualEnd <- resolveNow completedAt
    let updated = State.appendStep { name, status: State.parseStepStatus status, verification, startedAt: actualStart, completedAt: actualEnd, reason } state
    State.writeState (Context.statePath context) updated
    pure (Outcome.withStdout ("recorded: " <> name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ")\n"))
  ResultsSet field value -> withLoadedState context \state -> do
    let updated = do
          json <- jsonValueFor field value
          State.setField field json state
    case updated of
      Left _ -> pure (invalidSet field)
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
    timestamp <- Sys.nowIso
    let base = State.initState timestamp
        initialized = do
          withNoVcs <- State.setField "noVcs" (fromBoolean options.noVcs) base
          withReview <- State.setField "review" (fromBoolean options.review) withNoVcs
          withMinimal <- State.setField "minimal" (fromBoolean options.minimal) withReview
          withVcs <- if Vcs.vcsName context.vcs == "unknown" then Right withMinimal else State.setField "vcs" (fromString (Vcs.vcsName context.vcs)) withMinimal
          withFrom <- if options.from == "" then Right withVcs else State.setField "from" (fromString options.from) withVcs
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
-- | Execute sync in named phases so each subprocess boundary has one failure
-- | path and the successful protocol retains the incumbent ordering.
runSyncOp :: WorkflowContext -> SyncOp -> Effect Outcome.OpOutcome
runSyncOp context operation@(Sync options) = do
  startedAt <- Sys.nowIso
  fetched <- fetchPhase context options.noVcs
  case fetched of
    Left outcome -> pure outcome
    Right phases -> do
      inspected <- if options.noVcs then pure Vcs.Clean else Vcs.inspectDirty context
      case inspected of
        Vcs.InspectionFailed outcome -> pure (Outcome.append (phaseOutput phases) outcome)
        _ -> do
          resolvedContext <- resolveContext context operation startedAt
          case resolvedContext of
            Left outcome -> pure outcome
            Right state1 -> do
              resolved <- basePhase context operation state1
              case resolved of
                Left outcome -> pure outcome
                Right base -> do
                  let dirtyWarning = case inspected of
                        Vcs.DirtyDetected ->
                          -- Exit 0 carries the incumbent's warning on stderr;
                          -- DirtyState keeps an inspection failure distinct.
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
fetchPhase context noVcs = do
  fetched <- Vcs.fetchValue context
  let quietFetch = quietResult fetched
  if fetched.exit /= 0 then pure (Left quietFetch)
  else do
    refreshed <- Vcs.refreshDefaultBranchValue context
    let quietRefresh = quietResult refreshed
    if refreshed.exit /= 0 then pure (Left (Outcome.append quietFetch quietRefresh))
    else do
      forwarded <- if noVcs then pure Outcome.success else Vcs.runVcsOp context Vcs.FastForwardIfSafe
      if forwarded.exit /= 0 then pure (Left (Outcome.append (Outcome.append quietFetch quietRefresh) forwarded))
      else pure (Right { quietFetch, quietRefresh, forwarded })

phaseOutput :: FetchPhase -> Outcome.OpOutcome
phaseOutput phase = Outcome.append (Outcome.append phase.quietFetch phase.quietRefresh) phase.forwarded


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
  defaultRef <- Vcs.defaultBranchValue context
  if branchResult.code /= 0 then pure (Left (vcsValueOutcome branchResult))
  else do
    baseResult <- resolveSyncBase operation defaultRef context
    case baseResult of
      Left error -> pure (Left (failWithCode 2 error))
      Right base -> case State.setField "base" (fromString base) state1 of
        Left error -> pure (Left (failText ("sync: " <> error)))
        Right state2 -> pure (Right { state: state2, branch: branchResult, defaultRef, base })

recordPhase :: WorkflowContext -> SyncOp -> String -> SyncBase -> Effect Outcome.OpOutcome
recordPhase context (Sync options) startedAt resolved = do
  completed <- Sys.nowIso
  let contextWithBase = context { base = Just resolved.base }
      step =
        { name: "sync"
        , status: State.StepPassed
        , verification: "fetch ok; vcs=" <> Vcs.vcsName context.vcs <> "; forge=" <> Forge.forgeName context.forge <> "; noVcs=" <> boolText options.noVcs <> "; base=" <> resolved.base
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
  withCreate <- State.setField "supportsPrCreate" (fromBoolean (Forge.supports context.forge "pr-create")) withNoVcs
  withComment <- State.setField "supportsPrComment" (fromBoolean (Forge.supports context.forge "pr-comment")) withCreate
  withIssue <- State.setField "supportsIssueView" (fromBoolean (Forge.supports context.forge "issue-view")) withComment
  State.setField "supportsPrChecks" (fromBoolean (Forge.supports context.forge "pr-checks")) withIssue

resolveSyncBase :: SyncOp -> String -> WorkflowContext -> Effect (Either String String)
resolveSyncBase (Sync options) defaultRef context = case options.base of
  Just requested -> pure (Right requested)
  Nothing | options.stack -> do
    current <- Vcs.currentBranchValue context
    if current.code /= 0 then pure (Left (if current.stderr == "" then "sync: unable to resolve current branch" else trim current.stderr))
    else if current.value /= "" && current.value /= defaultRef && current.value /= "HEAD" then pure (Right current.value)
    else pure (Left
      ("sync: --stack found no feature branch to stack onto\n"
        <> "       current branch is '" <> if current.value == "" then "<none>" else current.value <> "' (default is '" <> defaultRef <> "').\n"
        <> "       checkout the feature branch first, or pass --base <branch> explicitly."))
  Nothing -> pure (Right defaultRef)

runDoneOp :: WorkflowContext -> DoneOp -> Effect Outcome.OpOutcome
runDoneOp context Done = do
  loaded <- loadState context
  case loaded of
    Left error -> pure (if error == "do-results: .do-results.json not found" then failText "done: .do-results.json not found — cannot produce summary" else failText error)
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
  , totalSeconds :: Int
  , slowest :: Maybe (Tuple String Int)
  , dominant :: Array String
  , skipped :: Array String
  , failed :: Array String
  }

-- | Compute all duration and status facts, failing on malformed timestamps.
computeDoneSummary :: State.State -> Effect (Either String DoneSummary)
computeDoneSummary state = do
  let firstStarted = case Array.head state.steps of
        Just step -> step.startedAt
        Nothing -> state.startedAt
      lastCompleted = case Array.last state.steps of
        Just step -> step.completedAt
        Nothing -> state.startedAt
  totalStart <- Sys.isoToEpoch firstStarted
  totalEnd <- Sys.isoToEpoch lastCompleted
  timedResults <- traverse timedStep state.steps
  pure do
    started <- totalStart
    completed <- totalEnd
    timed <- traverse identity timedResults
    let totalDuration = max 0 (completed - started)
        nonSkipped = Array.filter (\item -> item.step.status /= State.StepSkipped) timed
        durations = map (\item -> Tuple item.step item.seconds) nonSkipped
        slowest = slowestStep durations
        dominant = Array.mapMaybe (dominantName totalDuration) durations
        skipped = map (skippedName <<< _.step) (Array.filter (\item -> item.step.status == State.StepSkipped) timed)
        failed = map (_.step >>> _.name) (Array.filter (\item -> item.step.status == State.StepFailed) timed)
    pure { rows: timed, totalSeconds: totalDuration, slowest, dominant, skipped, failed }

-- | Render the human-facing markdown table and slowest-step line.
renderDoneMarkdown :: DoneSummary -> String
renderDoneMarkdown summary =
  let rows = map (renderTimedRow summary.totalSeconds) summary.rows
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
  in "\n<<<FACTS\n"
    <> "totalSeconds=" <> show summary.totalSeconds <> "\n"
    <> "slowestStep=" <> slowestName <> "\n"
    <> "slowestSeconds=" <> show slowestSeconds <> "\n"
    <> "dominantSteps=" <> joinWith "," summary.dominant <> "\n"
    <> "skippedSteps=" <> joinWith "," summary.skipped <> "\n"
    <> "failedSteps=" <> joinWith "," summary.failed <> "\n"
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

runNickelOp :: WorkflowContext -> NickelOp -> Effect Outcome.OpOutcome
runNickelOp context operation = do
  bundle <- Sys.bundleDir
  let bundleWorkflow = bundle <> "/../../../skills/do/workflow.ncl"
      adjacentWorkflow = bundle <> "/../../skills/do/workflow.ncl"
      cwdWorkflow = context.stateDir <> "/skills/do/workflow.ncl"
  bundleExists <- Sys.exists bundleWorkflow
  adjacentExists <- Sys.exists adjacentWorkflow
  let workflowPath =
        if bundleExists then bundleWorkflow
        else if adjacentExists then adjacentWorkflow
        else cwdWorkflow
  workflow <- Sys.realpath workflowPath
  let statePath = Context.statePath context
      expression = case operation of
        NickelCli -> "let workflow = import \"" <> workflow <> "\" in\n  let state = workflow.normalize_state (import \"" <> statePath <> "\") in\n  workflow.cli state\n"
        NickelCliSeed from -> "let workflow = import \"" <> workflow <> "\" in\n  let state = workflow.normalize_state (import \"" <> statePath <> "\") in\n  workflow.cli_seed \"" <> from <> "\" state\n"
  if context.captureOutput then do
    result <- Sys.execInput Binaries.nickel [ "eval", "--stdin-format", "nickel" ] expression
    pure (Outcome.captured result)
  else do
    result <- Sys.execInheritInput Binaries.nickel [ "eval", "--stdin-format", "nickel" ] expression
    pure case result.error of
      Just error -> Outcome.failure 1 ("nickel-cli: nickel failed to spawn: " <> error <> "\n")
      Nothing -> Outcome.passthrough result.code

loadState :: WorkflowContext -> Effect (Either String State.State)
loadState context = do
  result <- State.readState (Context.statePath context)
  pure case result of
    Left error -> Left ("do-results: " <> error)
    Right Nothing -> Left "do-results: .do-results.json not found"
    Right (Just state) -> Right state

resolveNow :: String -> Effect String
resolveNow value = if value == "now" then Sys.nowIso else pure value

jsonValueFor :: String -> String -> Either String Json
jsonValueFor field value
  | field == "steps" || field == "pendingStep" = jsonParser value
  | otherwise = Right case value of
      "true" -> fromBoolean true
      "false" -> fromBoolean false
      _ -> fromString value

invalidSet :: String -> Outcome.OpOutcome
invalidSet field = failText ("do-results: invalid value for '" <> field <> "'")

vcsValueOutcome :: Vcs.VcsValue -> Outcome.OpOutcome
vcsValueOutcome = Vcs.renderValue

failText :: String -> Outcome.OpOutcome
failText message = Outcome.failure 1 (message <> "\n")

failWithCode :: Int -> String -> Outcome.OpOutcome
failWithCode code message = Outcome.failure code (message <> "\n")
