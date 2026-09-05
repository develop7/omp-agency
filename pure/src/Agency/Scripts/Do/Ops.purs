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
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Context as Context
import Agency.Scripts.Do.DoneSummary as DoneReport
import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.NickelRuntime as NickelRuntime
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Results as Results
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sync as SyncWorkflow
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs
import Agency.Scripts.Do.WorkflowVocabulary as Vocabulary
import Data.Argonaut.Core (Json)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.String.CodeUnits (drop)
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
-- | Dispatch parsed result commands under one exclusive state transition.
runResultsOp :: WorkflowContext -> ResultsOp -> Effect Outcome.OpOutcome
runResultsOp context operation =
  withMutationLock context
    ( case operation of
        ResultsInit -> Results.runInit context
        ResultsStepStart name -> Results.runStepStart context name
        ResultsStepEnd status verification reason -> Results.runStepEnd context status verification reason
        ResultsStep name status verification startedAt completedAt reason ->
          Results.runStep context name status verification startedAt completedAt reason
        ResultsSet field value -> Results.runSet context field value
    )

-- | Dispatch driver lifecycle commands; reporting does not mutate state.
runDriverOp :: WorkflowContext -> DriverOp -> Effect Outcome.OpOutcome
runDriverOp context operation = case operation of
  DriverInit options -> withMutationLock context (Results.runDriverInit context options)
  DriverStart step -> withMutationLock context (Results.runStepStart context step)
  DriverEnd status verification reason -> withMutationLock context (Results.runStepEnd context status verification reason)
  DriverSkip step reason -> withMutationLock context (Results.runDriverSkip context step reason)
  DriverSet field value -> withMutationLock context (Results.runSet context field value)
  DriverSummary -> DoneReport.run context

-- | Delegate the ordered sync transaction under the same exclusive lock.
runSyncOp :: WorkflowContext -> SyncOp -> Effect Outcome.OpOutcome
runSyncOp context (Sync options) = withMutationLock context (SyncWorkflow.run context options)

withMutationLock :: WorkflowContext -> Effect Outcome.OpOutcome -> Effect Outcome.OpOutcome
withMutationLock context action = do
  result <- State.withStateLock (Context.statePath context) action
  pure case result of
    Left error -> Outcome.failure 1 (error <> "\n")
    Right outcome -> outcome


-- | Delegate done reporting and rendering.
runDoneOp :: WorkflowContext -> DoneOp -> Effect Outcome.OpOutcome
runDoneOp context Done = DoneReport.run context

type DoneRow = DoneReport.DoneRow

type DoneSummary = DoneReport.DoneSummary

computeDoneSummary :: State.State -> Effect (Either String DoneSummary)
computeDoneSummary = DoneReport.compute

renderDoneMarkdown :: DoneSummary -> String
renderDoneMarkdown = DoneReport.renderMarkdown

renderFacts :: DoneSummary -> String
renderFacts = DoneReport.renderFacts

renderDone :: State.State -> Int -> Effect String
renderDone = DoneReport.render

fmtDur :: Int -> String
fmtDur = DoneReport.fmtDur

-- | Forward the parsed Nickel request to the shared Node adapter.
runNickelOp :: WorkflowContext -> NickelOp -> Effect Outcome.OpOutcome
runNickelOp context operation = case operation of
  NickelCli -> NickelRuntime.run context Nothing
  NickelCliSeed from -> NickelRuntime.run context (Just from)

validInterval :: String -> String -> Effect (Either String Unit)
validInterval = Results.validInterval

jsonValueFor :: String -> String -> Either String Json
jsonValueFor = Results.jsonValueFor
