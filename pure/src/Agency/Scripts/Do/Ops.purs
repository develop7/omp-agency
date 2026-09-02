module Agency.Scripts.Do.Ops
  ( ParseError
  , ResultsOp(..)
  , DriverOp(..)
  , SyncOp(..)
  , DoneOp(..)
  , NickelOp(..)
  , parseResultsOp
  , parseDriverOp
  , parseSyncOp
  , parseDoneOp
  , parseNickelOp
  , runResultsOp
  , runDriverOp
  , runSyncOp
  , runDoneOp
  , runNickelOp
  , renderDone
  , fmtDur
  ) where

import Prelude

import Data.Argonaut.Core (fromBoolean, fromString)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll, split, trim)
import Data.String.CodeUnits (drop, length, take)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)

import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs

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

-- | sync command algebra.
data SyncOp = Sync { noVcs :: Boolean, base :: Maybe String, stack :: Boolean }

-- | steps/done accepts no arguments.
data DoneOp = Done

-- | Nickel workflow command algebra.
data NickelOp = NickelCli | NickelCliSeed String

parseResultsOp :: Array String -> Either ParseError ResultsOp
parseResultsOp args =
  case Array.uncons args of
    Nothing -> Left (parseError 1 "Usage: do-results <init|step-start|step-end|step|set> ...")
    Just { head: command, tail: rest } -> case command of
      "init" -> Right ResultsInit
      "step-start" -> requiredOne "name required" ResultsStepStart rest
      "step-end" -> case Array.uncons rest of
        Nothing -> Left (parseError 1 "status required (passed|failed|skipped)")
        Just { head: status, tail: afterStatus } ->
          Right (ResultsStepEnd status (fromMaybe "" (Array.head afterStatus)) (Array.index afterStatus 1 >>= nonEmpty))
      "step" -> case takeFive rest of
        Nothing -> Left (parseError 1 "name, status, verification, startedAt, and completedAt are required")
        Just { name, status, verification, startedAt, completedAt, tail: after } ->
          Right (ResultsStep name status verification startedAt completedAt (Array.head after >>= nonEmpty))
      "set" -> case Array.uncons rest of
        Nothing -> Left (parseError 1 "field required")
        Just { head: field, tail: after } -> case Array.head after of
          Nothing -> Left (parseError 1 "value required")
          Just value -> Right (ResultsSet field value)
      _ -> Left (parseError 1 ("Unknown command: " <> command <> "\nUsage: do-results <init|step-start|step-end|step|set> ..."))
  where
  requiredOne message constructor values = case Array.head values of
    Just value -> Right (constructor value)
    Nothing -> Left (parseError 1 message)
  nonEmpty value = if value == "" then Nothing else Just value

takeFive :: Array String -> Maybe { name :: String, status :: String, verification :: String, startedAt :: String, completedAt :: String, tail :: Array String }
takeFive values = case Array.uncons values of
  Nothing -> Nothing
  Just { head: name, tail: afterName } -> case Array.uncons afterName of
    Nothing -> Nothing
    Just { head: status, tail: afterStatus } -> case Array.uncons afterStatus of
      Nothing -> Nothing
      Just { head: verification, tail: afterVerification } -> case Array.uncons afterVerification of
        Nothing -> Nothing
        Just { head: startedAt, tail: afterStarted } -> case Array.uncons afterStarted of
          Nothing -> Nothing
          Just { head: completedAt, tail } -> Just { name, status, verification, startedAt, completedAt, tail }

parseDriverOp :: Array String -> Either ParseError DriverOp
parseDriverOp args =
  case Array.uncons args of
    Nothing -> Left (parseError 1 "Usage: do-driver <init|start|end|skip|set|summary> ...")
    Just { head: command, tail: rest } -> case command of

      "init" -> parseDriverInit rest
      "start" -> requiredOne "step required" DriverStart rest
      "end" -> case Array.uncons rest of
        Nothing -> Left (parseError 1 "status required")
        Just { head: status, tail: after } -> Right (DriverEnd status (fromMaybe "" (Array.head after)) (Array.index after 1 >>= nonEmpty))
      "skip" -> case Array.uncons rest of
        Nothing -> Left (parseError 1 "step required")
        Just { head: step, tail: after } -> case Array.head after of
          Nothing -> Left (parseError 1 "reason required")
          Just reason -> Right (DriverSkip step reason)
      "set" -> case Array.uncons rest of
        Nothing -> Left (parseError 1 "field required")
        Just { head: field, tail: after } -> case Array.head after of
          Nothing -> Left (parseError 1 "value required")
          Just value -> Right (DriverSet field value)
      "summary" -> Right DriverSummary
      _ -> Left (parseError 1 ("Unknown command: " <> command <> "\nUsage: do-driver <init|start|end|skip|set|summary> ..."))
  where
  requiredOne message constructor values = case Array.head values of
    Just value -> Right (constructor value)
    Nothing -> Left (parseError 1 message)
  nonEmpty value = if value == "" then Nothing else Just value

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
      _ | startsWith "--from=" arg -> go after (state { from = drop 7 arg })
      _ | startsWith "--" arg -> Left (parseError 2 ("do-driver: unknown flag: " <> arg))
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
      "--base" -> case Array.uncons after of
        Nothing -> Left (parseError 2 "sync: --base requires a branch argument")
        Just { head: branch, tail } -> go tail (state { base = Just branch })
      _ | startsWith "--" arg -> Left (parseError 2 ("sync: unknown flag: " <> arg <> "\nUsage: sync <noVcs> [--base <branch> | --stack]"))
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
parseNickelOp args = case Array.uncons args of
  Nothing -> Left (parseError 2 "Usage: nickel-cli <cli|cli_seed> [args...]")
  Just { head: command, tail: rest } -> case command of
    "cli" -> Right NickelCli
    "cli_seed" -> Right (NickelCliSeed (fromMaybe "" (Array.head rest)))
    _ -> Left (parseError 2 ("nickel-cli: unknown field: " <> command))

parseError :: Int -> String -> ParseError
parseError code message = { code, message }

startsWith :: String -> String -> Boolean
startsWith prefix value = take (stringLength prefix) value == prefix

stringLength :: String -> Int
stringLength = length

nonEmptyText :: String -> Maybe String
nonEmptyText value = if value == "" then Nothing else Just value

printLine :: String -> Effect Unit
printLine value = Sys.stdoutWrite (value <> "\n")
runResultsOp :: ResultsOp -> Effect Int
runResultsOp operation = case operation of
  ResultsInit -> do
    timestamp <- Sys.nowIso
    State.writeState stateFile (State.initState timestamp)
    printLine ("init: startedAt=" <> timestamp)
    pure 0
  ResultsStepStart name -> do
    loaded <- loadState
    case loaded of
      Left error -> failText error
      Right state -> case state.pendingStep of
        Just pending -> failText ("do-results: pendingStep '" <> pending.name <> "' already active — call step-end before starting '" <> name <> "'")
        Nothing -> do
          timestamp <- Sys.nowIso
          State.writeState stateFile (State.startPending { name, startedAt: timestamp } state)
          printLine ("pending: " <> name)
          pure 0
  ResultsStepEnd status verification reason -> do
    loaded <- loadState
    case loaded of
      Left error -> failText error
      Right state -> case state.pendingStep of
        Nothing -> failText "do-results: no pendingStep — call step-start first"
        Just pending -> do
          completed <- Sys.nowIso
          let step = { name: pending.name, status, verification, startedAt: pending.startedAt, completedAt: completed, reason }
              updated = State.finishPending (State.appendStep step state)
          State.writeState stateFile updated
          printLine ("recorded: " <> pending.name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ", pending=none)")
          pure 0
  ResultsStep name status verification startedAt completedAt reason -> do
    loaded <- loadState
    case loaded of
      Left error -> failText error
      Right state -> do
        actualStart <- resolveNow startedAt
        actualEnd <- resolveNow completedAt
        let updated = State.appendStep { name, status, verification, startedAt: actualStart, completedAt: actualEnd, reason } state
        State.writeState stateFile updated
        printLine ("recorded: " <> name <> " " <> status <> " (steps=" <> show (Array.length updated.steps) <> ")")
        pure 0
  ResultsSet field value -> do
    loaded <- loadState
    case loaded of
      Left error -> failText error
      Right state -> do
        let json = case value of
              "true" -> fromBoolean true
              "false" -> fromBoolean false
              _ -> fromString value
        State.writeState stateFile (State.setField field json state)
        printLine ("set: " <> field <> "=" <> value)
        pure 0
  where
  stateFile = ".do-results.json"

runDriverOp :: DriverOp -> Effect Int
runDriverOp operation = case operation of
  DriverInit options -> do
    timestamp <- Sys.nowIso
    vcs <- Vcs.detectVcs
    let base = State.initState timestamp
        withFlags = State.setField "minimal" (fromBoolean options.minimal)
          (State.setField "noVcs" (fromBoolean options.noVcs)
            (State.setField "review" (fromBoolean options.review) base))
        withVcs = if Vcs.vcsName vcs == "unknown" then withFlags else State.setField "vcs" (fromString (Vcs.vcsName vcs)) withFlags
        withFrom = if options.from == "" then withVcs else State.setField "from" (fromString options.from) withVcs
        final = if options.task == "" then withFrom else State.setField "task" (fromString options.task) withFrom
    State.writeState ".do-results.json" final
    printLine ("init: review=" <> boolText options.review <> " noVcs=" <> boolText options.noVcs <> " minimal=" <> boolText options.minimal <> " from=" <> if options.from == "" then "default" else options.from <> " vcs=" <> Vcs.vcsName vcs)
    pure 0
  DriverStart step -> runResultsOp (ResultsStepStart step)
  DriverEnd status verification reason -> runResultsOp (ResultsStepEnd status verification reason)
  DriverSkip step reason -> do
    started <- runResultsOp (ResultsStepStart step)
    if started /= 0 then pure started else runResultsOp (ResultsStepEnd "skipped" "" (nonEmptyText reason))
  DriverSet field value -> runResultsOp (ResultsSet field value)
  DriverSummary -> runDoneOp Done

boolText :: Boolean -> String
boolText value = if value then "true" else "false"

runSyncOp :: SyncOp -> Effect Int
runSyncOp (Sync options) = do
  startedAt <- Sys.nowIso
  vcs <- Vcs.detectVcs
  fetched <- fetchQuiet vcs
  if fetched /= 0 then pure fetched
  else do
    refreshed <- refreshQuiet vcs
    if refreshed /= 0 then pure refreshed
    else do
      forwarded <- if options.noVcs then pure 0 else Vcs.runVcsOp Vcs.FastForwardIfSafe
      if forwarded /= 0 then pure forwarded
      else do
        if not options.noVcs then do
          dirtyCode <- Vcs.runVcsOp Vcs.Dirty
          if dirtyCode == 0 then
            Sys.stderrWrite "Dirty tree detected. Continuing will create a fresh branch on top of these changes. If you wanted the agent to extend your WIP in place without touching git, re-run with --no-vcs.\n"
          else pure unit
        else pure unit
        forge <- Forge.detectForge
        let supportsCreate = Forge.supports forge "pr-create"
            supportsComment = Forge.supports forge "pr-comment"
            supportsIssue = Forge.supports forge "issue-view"
            supportsChecks = Forge.supports forge "pr-checks"
        initial <- State.readState ".do-results.json"
        case initial of
          Left error -> failText ("sync: " <> error)
          Right maybeState -> do
            let state0 = fromMaybe (State.initState startedAt) maybeState
                state1 = putSyncFields vcs forge options.noVcs supportsCreate supportsComment supportsIssue supportsChecks state0
            branch <- Vcs.headRevisionValue vcs
            defaultRef <- Vcs.defaultBranchValue vcs
            baseResult <- resolveSyncBase (Sync options) defaultRef vcs
            case baseResult of
              Left error -> failWithCode 2 error
              Right base -> do
                let state2 = State.setField "base" (fromString base) state1
                    step = { name: "sync", status: "passed", verification: "fetch ok; vcs=" <> Vcs.vcsName vcs <> "; forge=" <> Forge.forgeName forge <> "; noVcs=" <> boolText options.noVcs <> "; base=" <> base, startedAt, completedAt: "", reason: Nothing }
                completed <- Sys.nowIso
                State.writeState ".do-results.json" (State.appendStep (step { completedAt = completed }) state2)
                Sys.stdoutWrite
                  ("vcs=" <> Vcs.vcsName vcs <> "\n"
                    <> "forge=" <> Forge.forgeName forge <> "\n"
                    <> "branch=" <> branch <> "\n"
                    <> "defaultBranch=" <> defaultRef <> "\n"
                    <> "base=" <> base <> "\n")
                pure 0
  where
  fetchQuiet vcs = case vcs of
    Vcs.Git -> quietCapture "git" [ "fetch", "origin" ]
    Vcs.Jj -> quietCapture "jj" [ "git", "fetch" ]
    Vcs.Unknown -> failText "vcs-op: no VCS detected"
  refreshQuiet vcs = case vcs of
    Vcs.Git -> quietCapture "git" [ "remote", "set-head", "origin", "--auto" ]
    _ -> pure 0

putSyncFields :: Vcs.VcsKind -> Forge.ForgeKind -> Boolean -> Boolean -> Boolean -> Boolean -> Boolean -> State.State -> State.State
putSyncFields vcs forge noVcs supportsCreate supportsComment supportsIssue supportsChecks state =
  State.setField "supportsPrChecks" (fromBoolean supportsChecks)
    (State.setField "supportsIssueView" (fromBoolean supportsIssue)
      (State.setField "supportsPrComment" (fromBoolean supportsComment)
        (State.setField "supportsPrCreate" (fromBoolean supportsCreate)
          (State.setField "noVcs" (fromBoolean noVcs)
            (State.setField "forge" (fromString (Forge.forgeName forge))
              (State.setField "vcs" (fromString (Vcs.vcsName vcs)) state))))))

resolveSyncBase :: SyncOp -> String -> Vcs.VcsKind -> Effect (Either String String)
resolveSyncBase (Sync options) defaultRef vcs = case options.base of
  Just requested -> pure (Right requested)
  Nothing | options.stack -> do
    current <- Vcs.currentBranchValue vcs
    if current /= "" && current /= defaultRef && current /= "HEAD" then pure (Right current)
    else pure (Left
      ("sync: --stack found no feature branch to stack onto\n"
        <> "       current branch is '" <> if current == "" then "<none>" else current <> "' (default is '" <> defaultRef <> "').\n"
        <> "       checkout the feature branch first, or pass --base <branch> explicitly."))
  Nothing -> pure (Right defaultRef)

quietCapture :: String -> Array String -> Effect Int
quietCapture command args = do
  result <- Sys.exec command args
  if result.stderr == "" then pure unit else Sys.stderrWrite result.stderr
  pure result.code

runDoneOp :: DoneOp -> Effect Int
runDoneOp Done = do
  loaded <- loadState
  case loaded of
    Left error -> if error == "do-results: .do-results.json not found"
      then failText "done: .do-results.json not found — cannot produce summary"
      else failText error
    Right state -> do
      let firstStarted = case Array.head state.steps of
            Just step -> step.startedAt
            Nothing -> state.startedAt
          lastCompleted = case Array.last state.steps of
            Just step -> step.completedAt
            Nothing -> state.startedAt
      totalStart <- Sys.isoToEpoch firstStarted
      totalEnd <- Sys.isoToEpoch lastCompleted
      let totalDuration = max 0 (totalEnd - totalStart)
      rendered <- renderDone state totalDuration
      Sys.stdoutWrite rendered
      pure 0

renderDone :: State.State -> Int -> Effect String
renderDone state totalDuration = do
  timed <- traverse timedStep state.steps
  let rows = map (renderTimedRow totalDuration) timed
      nonSkipped = Array.filter (\item -> item.step.status /= "skipped") timed
      durations = map (\item -> Tuple item.step item.seconds) nonSkipped
      slowest = slowestStep durations
      dominant = Array.mapMaybe (dominantName totalDuration) durations
      skipped = map (skippedName <<< _.step) (Array.filter (\item -> item.step.status == "skipped") timed)
      failed = map (_.step >>> _.name) (Array.filter (\item -> item.step.status == "failed") timed)
      table = "| Step | Status | Duration | Verification |\n"
        <> "|------|--------|----------|--------------|\n"
        <> joinWith "\n" rows
        <> (if Array.null rows then "" else "\n")
        <> "| **Total** | | **" <> fmtDur totalDuration <> "** | |\n\n"
      slowLine = case slowest of
        Nothing -> ""
        Just (Tuple name seconds) -> "**Slowest step**: `" <> name <> "` (" <> fmtDur seconds <> ")\n"
      slowestName = case slowest of
        Nothing -> ""
        Just (Tuple name _) -> name
      slowestSeconds = case slowest of
        Nothing -> 0
        Just (Tuple _ seconds) -> seconds
      facts = "\n<<<FACTS\n"
        <> "totalSeconds=" <> show totalDuration <> "\n"
        <> "slowestStep=" <> slowestName <> "\n"
        <> "slowestSeconds=" <> show slowestSeconds <> "\n"
        <> "dominantSteps=" <> joinWith "," dominant <> "\n"
        <> "skippedSteps=" <> joinWith "," skipped <> "\n"
        <> "failedSteps=" <> joinWith "," failed <> "\n"
        <> "FACTS\n"
  pure (table <> slowLine <> "\n" <> facts)

type TimedStep =
  { step :: State.Step
  , seconds :: Int
  }

timedStep :: State.Step -> Effect TimedStep
timedStep step = do
  started <- Sys.isoToEpoch step.startedAt
  completed <- Sys.isoToEpoch step.completedAt
  pure { step, seconds: max 0 (completed - started) }

renderTimedRow :: Int -> TimedStep -> String
renderTimedRow totalDuration item =
  let step = item.step
      seconds = item.seconds
      icon = case step.status of
        "passed" -> "✓"
        "failed" -> "✗"
        "skipped" -> "—"
        _ -> "?"
      bold = step.status /= "skipped" && totalDuration > 0 && (seconds * 100 `div` totalDuration) >= 30
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

runNickelOp :: NickelOp -> Effect Int
runNickelOp operation = do
  root <- Sys.cwd
  workflow <- Sys.realpath (root <> "/skills/do/workflow.ncl")
  let statePath = root <> "/.do-results.json"
      expression = case operation of
        NickelCli -> "let workflow = import \"" <> workflow <> "\" in\n  let state = workflow.normalize_state (import \"" <> statePath <> "\") in\n  workflow.cli state\n"
        NickelCliSeed from -> "let workflow = import \"" <> workflow <> "\" in\n  let state = workflow.normalize_state (import \"" <> statePath <> "\") in\n  workflow.cli_seed \"" <> from <> "\" state\n"
  Sys.execInheritInput "nickel" [ "eval", "--stdin-format", "nickel" ] expression

loadState :: Effect (Either String State.State)
loadState = do
  result <- State.readState ".do-results.json"
  pure case result of
    Left error -> Left ("do-results: " <> error)
    Right Nothing -> Left "do-results: .do-results.json not found"
    Right (Just state) -> Right state

resolveNow :: String -> Effect String
resolveNow value = if value == "now" then Sys.nowIso else pure value

failText :: String -> Effect Int
failText message = do
  Sys.stderrWrite (message <> "\n")
  pure 1

failWithCode :: Int -> String -> Effect Int
failWithCode code message = do
  Sys.stderrWrite (message <> "\n")
  pure code
