module Agency.Scripts.Do.StateTest (run) where

import Prelude

import Data.Array as Array
import Data.Argonaut.Core (fromArray, fromBoolean, fromString, toBoolean, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), joinWith)
import Data.String.CodeUnits (contains)
import Effect (Effect)
import Effect.Exception (try)
import Effect.Console as Console

import Agency.Scripts.Do.ForgeKind as ForgeKind
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Ops as Ops
import Agency.Scripts.Do.Results as Results
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.VcsKind as VcsKind
import Node.Errors.SystemError as SystemError
import Node.FS.Sync as FSSync
import Unsafe.Coerce (unsafeCoerce)

assert :: String -> Boolean -> Effect Unit
assert label condition =
  if condition then pure unit
  else do
    Console.error ("FAIL: " <> label)
    Sys.exit 1

run :: Effect Unit
run = do
  let source = "{\"workflow\":\"do\",\"startedAt\":\"2024-01-01T00:00:00Z\",\"active\":\"working\",\"status\":\"running\",\"steps\":[],\"pendingStep\":null,\"customField\":{\"nested\":[true,2]},\"customText\":\"kept\"}"
  case State.parseState source of
    Left error -> do
      Console.error ("FAIL: parse state: " <> error)
      Sys.exit 1
    Right state -> do
      let encoded = State.stringifyState state
      assert "unknown object field survives stringify" (encoded == "{\"workflow\":\"do\",\"startedAt\":\"2024-01-01T00:00:00Z\",\"active\":\"working\",\"status\":\"running\",\"steps\":[],\"customField\":{\"nested\":[true,2]},\"customText\":\"kept\"}")
      case State.parseState encoded of
        Left error -> do
          Console.error ("FAIL: parse encoded state: " <> error)
          Sys.exit 1
        Right roundTripped -> do
          assert "unknown boolean/object value remains available" (State.stateGetJson "customField" roundTripped /= Nothing)
          case State.setField "newFlag" (fromBoolean true) roundTripped of
            Left error -> do
              Console.error ("FAIL: set unknown field: " <> error)
              Sys.exit 1
            Right withNewField -> do
              assert "set unknown field can be read as boolean" ((State.stateGetJson "newFlag" withNewField >>= toBoolean) == Just true)
              case jsonParser "[]" >>= \json -> State.setField "steps" json withNewField of
                Left error -> do
                  Console.error ("FAIL: set reserved steps: " <> error)
                  Sys.exit 1
                Right withSteps -> do
                  assert "reserved steps updates typed field" (State.stateGetJson "steps" withSteps /= Nothing)
                  case State.setField "steps" (fromBoolean true) withSteps of
                    Left _ -> pure unit
                    Right _ -> do
                      Console.error "FAIL: invalid reserved steps value was accepted"
                      Sys.exit 1
                  let reloaded = State.parseState (State.stringifyState withSteps)
                  case reloaded of
                    Left error -> do
                      Console.error ("FAIL: reload state after set: " <> error)
                      Sys.exit 1
                    Right finalState -> assert "set unknown field survives load/save" ((State.stateGetJson "newFlag" finalState >>= toBoolean) == Just true)
  cwd <- Sys.cwd
  writeFailureDirectory <- Sys.uniqueTempPath (cwd <> "/.state-write-failure")
  let writeFailurePath = writeFailureDirectory <> "/.do-results.json"
      rmOptions = { force: true, maxRetries: 0, recursive: true, retryDelay: 0 }
  FSSync.mkdir writeFailureDirectory
  FSSync.mkdir writeFailurePath
  writeFailure <- try (State.writeState writeFailurePath State.emptyState)
  writeFailureEntries <- FSSync.readdir writeFailureDirectory
  FSSync.rm' writeFailureDirectory rmOptions
  case writeFailure of
    Left error -> do
      assert "write state preserves the rename failure" (SystemError.code (unsafeCoerce error) == "EISDIR")
      assert "write state removes its temporary file after rename failure" (writeFailureEntries == [ ".do-results.json" ])
    Right _ -> assert "write state rejects a directory destination" false
  case State.parseState "{\"active\":\"finished\"}" of
    Left error -> assert "unknown active status is rejected" (error == "state: invalid active 'finished'")
    Right _ -> assert "unknown active status is rejected" false
  case State.parseState "{\"status\":\"done\"}" of
    Left error -> assert "unknown workflow status is rejected" (error == "state: invalid status 'done'")
    Right _ -> assert "unknown workflow status is rejected" false
  case State.parseState "{\"steps\":[{\"name\":\"sync\",\"status\":\"bananas\",\"verification\":\"\",\"startedAt\":\"2024-01-01T00:00:00Z\",\"completedAt\":\"2024-01-01T00:00:00Z\"}]}" of
    Left error -> assert "unknown step status is rejected" (error == "state: invalid step status 'bananas'")
    Right _ -> assert "unknown step status is rejected" false
  case Ops.parseResultsOp [ "step", "sync", "bananas", "", "now", "now" ] of
    Left error -> assert "invalid step status is rejected at the command boundary" (error.code == 1)
    Right _ -> assert "invalid step status is rejected at the command boundary" false
  case Ops.parseDriverOp [ "init", "first", "second" ] of
    Left error -> assert "multiple task arguments are rejected" (error.code == 2)
    Right _ -> assert "multiple task arguments are rejected" false
  case Ops.parseDriverOp [ "init", "--from=followpu", "resume" ] of
    Left error -> assert "unknown entry point is rejected" (error.code == 2)
    Right _ -> assert "unknown entry point is rejected" false
  case Ops.parseNickelOp [ "cli_seed", "followpu" ] of
    Left error -> assert "nickel cli_seed rejects an unknown entry point" (error.code == 2)
    Right _ -> assert "nickel cli_seed rejects an unknown entry point" false
  case Ops.parseDriverOp [ "start", "reserch" ] of
    Left error -> assert "unknown workflow step is rejected" (error.code == 2)
    Right _ -> assert "unknown workflow step is rejected" false
  case Ops.parseResultsOp [ "step-start", "reserch" ] of
    Left error -> assert "result steps are restricted to workflow steps" (error.code == 2)
    Right _ -> assert "result steps are restricted to workflow steps" false
  assert "string fields preserve literal true" (map toString (Results.jsonValueFor "task" "true") == Right (Just "true"))
  assert "boolean fields decode literal true" (map toBoolean (Results.jsonValueFor "review" "true") == Right (Just true))
  let terminal = State.finishWorkflow State.WorkflowCompleted (State.initState "2024-01-01T00:00:00Z")
  assert "terminal success makes the workflow idle" (terminal.active == State.ActiveIdle && terminal.status == State.WorkflowCompleted)
  let firstStep =
        { name: "sync"
        , status: State.StepPassed
        , verification: "first recorded"
        , startedAt: "2024-01-01T00:00:00Z"
        , completedAt: "2024-01-01T00:00:00Z"
        , reason: Nothing
        }
      middleStep =
        { name: "research"
        , status: State.StepPassed
        , verification: "middle recorded"
        , startedAt: "2024-01-01T00:00:01Z"
        , completedAt: "2024-01-01T00:00:01Z"
        , reason: Nothing
        }
      lastStep =
        { name: "check"
        , status: State.StepPassed
        , verification: "last recorded"
        , startedAt: "2024-01-01T00:00:02Z"
        , completedAt: "2024-01-01T00:00:02Z"
        , reason: Nothing
        }
      nextStep =
        { name: "evidence"
        , status: State.StepPassed
        , verification: "new record"
        , startedAt: "2024-01-01T00:00:03Z"
        , completedAt: "2024-01-01T00:00:03Z"
        , reason: Nothing
        }
      oneBeforeLimit =
        (State.initState "2024-01-01T00:00:00Z")
          { steps = [ firstStep ] <> Array.replicate (State.maxPersistedSteps - 2) middleStep
          }
      fullHistory =
        oneBeforeLimit
          { steps = oneBeforeLimit.steps <> [ lastStep ]
          }
      overLimitHistory =
        fullHistory
          { steps = fullHistory.steps <> [ nextStep ]
          }
  case State.appendStep nextStep oneBeforeLimit of
    Left error -> do
      Console.error ("FAIL: append below limit: " <> error)
      Sys.exit 1
    Right updated ->
      assert
        ("append preserves ordered history at limit " <> show State.maxPersistedSteps)
        (map _.name updated.steps == map _.name (oneBeforeLimit.steps <> [ nextStep ]))
  case State.appendStep nextStep fullHistory of
    Left error ->
      assert
        ("append rejects history at limit " <> show State.maxPersistedSteps)
        (error == "state: step history limit (" <> show State.maxPersistedSteps <> ") reached")
    Right _ -> do
      Console.error "FAIL: append allowed an unbounded audit history"
      Sys.exit 1
  case State.parseState (State.stringifyState overLimitHistory) of
    Left error ->
      assert
        ("parse rejects history beyond limit " <> show State.maxPersistedSteps)
        (error == "state: step history limit (" <> show State.maxPersistedSteps <> ") exceeded")
    Right _ -> do
      Console.error "FAIL: parse accepted an over-limit audit history"
      Sys.exit 1
  case State.appendStep (nextStep { name = "not-a-step" }) State.emptyState of
    Left error -> assert "append rejects an unknown step name" (error == "state: unknown step 'not-a-step'")
    Right _ -> do
      Console.error "FAIL: append accepted an unknown step name"
      Sys.exit 1
  case State.appendStep (nextStep { status = State.StepUnknown "not-a-status" }) State.emptyState of
    Left error -> assert "append rejects an unknown step status" (error == "state: invalid step status 'not-a-status'")
    Right _ -> do
      Console.error "FAIL: append accepted an unknown step status"
      Sys.exit 1
  lockDirectory <- Sys.uniqueTempPath (cwd <> "/.state-lock")
  let lockStatePath = lockDirectory <> "/.do-results.json"
      lockPath = lockStatePath <> ".lock"
      lockContext =
        { stateDir: lockDirectory
        , vcs: VcsKind.Unknown
        , forge: ForgeKind.Unknown
        , base: Nothing
        , vcsOverride: Nothing
        , forgeOverride: Nothing
        , captureOutput: true
        }
  FSSync.mkdir lockDirectory
  case State.setField "task" (fromString "original") State.emptyState of
    Left error -> do
      Console.error ("FAIL: prepare locked state: " <> error)
      Sys.exit 1
    Right original -> do
      State.writeState lockStatePath original
      FSSync.mkdir lockPath
      blocked <- Ops.runResultsOp lockContext (Ops.ResultsSet "task" "replacement")
      unchanged <- State.readState lockStatePath
      lockRemains <- FSSync.exists lockPath
      FSSync.rmdir lockPath
      normalRelease <- State.withStateLock lockStatePath (pure "done")
      releasedAfterSuccess <- FSSync.exists lockPath
      failedRelease <- try (State.withStateLock lockStatePath (FSSync.rmdir (lockDirectory <> "/missing")))
      releasedAfterFailure <- FSSync.exists lockPath
      FSSync.rm' lockDirectory rmOptions
      let conflict = "state: lock '" <> lockPath <> "' already exists; another state mutation is running, or it is stale after a crash — remove the lock explicitly after confirming no mutation is active\n"
      case blocked.output of
        Outcome.Captured output ->
          assert "locked mutation fails with a stale-lock recovery instruction" (blocked.exit == 1 && output.stderr == conflict)
        Outcome.Passthrough -> assert "locked mutation reports a captured conflict" false
      case unchanged of
        Right (Just state) -> assert "locked mutation leaves persisted state unchanged" (State.stateGet "task" state == "original" && lockRemains)
        _ -> assert "locked mutation leaves persisted state unchanged" false
      assert "state lock releases after a successful action" (normalRelease == Right "done" && not releasedAfterSuccess)
      case failedRelease of
        Left _ -> assert "state lock releases after a failing action" (not releasedAfterFailure)
        Right _ -> assert "state lock rethrows a failing action" false
  let fullJob =
        { id: "police-pass1"
        , name: "Pass 1 structure review"
        , step: "police"
        , startedAt: "2026-10-16T12:00:00Z"
        , deadline: Just "2026-10-16T12:10:00Z"
        , finished: Just
            { finishedAt: "2026-10-16T12:07:41Z"
            , outcome: State.JobCompleted
            , verification: Just "reviewed 12 files"
            }
        }
      openJob =
        fullJob
          { id = "police-pass2"
          , name = "Pass 2 detail review"
          , finished = Nothing
          }
      ledgerState = (State.initState "2026-10-16T12:00:00Z") { jobs = [ fullJob, openJob ] }
  assert
    "job entries survive stringify with driver-owned fields"
    ( contains
        ( Pattern
            "\"jobs\":[{\"id\":\"police-pass1\",\"name\":\"Pass 1 structure review\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"deadline\":\"2026-10-16T12:10:00Z\",\"finishedAt\":\"2026-10-16T12:07:41Z\",\"outcome\":\"completed\",\"verification\":\"reviewed 12 files\"}"
        )
        (State.stringifyState ledgerState)
    )
  case State.parseState (State.stringifyState ledgerState) of
    Left error -> do
      Console.error ("FAIL: parse job ledger: " <> error)
      Sys.exit 1
    Right roundTripped -> assert "job ledger round-trips" (roundTripped.jobs == ledgerState.jobs)
  assert "empty job ledger stays absent" (not (contains (Pattern "\"jobs\"") (State.stringifyState State.emptyState)))
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\"}]}" of
    Left error -> do
      Console.error ("FAIL: minimal job parse: " <> error)
      Sys.exit 1
    Right parsed -> assert "minimal unfinished job parses" (map _.finished parsed.jobs == [ Nothing ])
  case State.parseState "{\"jobs\":[{\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\"}]}" of
    Left error -> assert "job id is required" (error == "state: field 'id' must be a string")
    Right _ -> assert "job id is required" false
  case State.parseState "{\"jobs\":[{\"id\":\"\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\"}]}" of
    Left error -> assert "empty job id is rejected" (error == "state: job id must be non-empty")
    Right _ -> assert "empty job id is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\"}]}" of
    Left error -> assert "empty job name is rejected" (error == "state: job name must be non-empty")
    Right _ -> assert "empty job name is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"reserch\",\"startedAt\":\"2026-10-16T12:00:00Z\"}]}" of
    Left error -> assert "job step must come from the workflow vocabulary" (error == "state: unknown step 'reserch'")
    Right _ -> assert "job step must come from the workflow vocabulary" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"finishedAt\":\"2026-10-16T12:01:00Z\"}]}" of
    Left error -> assert "finishedAt without outcome is rejected" (error == "state: job 'a' must record finishedAt and outcome together")
    Right _ -> assert "finishedAt without outcome is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"outcome\":\"completed\"}]}" of
    Left error -> assert "outcome without finishedAt is rejected" (error == "state: job 'a' must record finishedAt and outcome together")
    Right _ -> assert "outcome without finishedAt is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"verification\":\"orphan reason\"}]}" of
    Left error -> assert "verification without a finished job is rejected" (error == "state: job 'a' verification requires a finished job")
    Right _ -> assert "verification without a finished job is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:05:00Z\",\"finishedAt\":\"2026-10-16T12:01:00Z\",\"outcome\":\"completed\"}]}" of
    Left error ->
      assert
        "a finish before the start is rejected"
        (error == "state: job 'a' finishedAt '2026-10-16T12:01:00Z' precedes startedAt '2026-10-16T12:05:00Z'")
    Right _ -> assert "a finish before the start is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"finishedAt\":\"whenever\",\"outcome\":\"completed\"}]}" of
    Left error -> assert "an unparsable finish timestamp is rejected" (error == "state: invalid timestamp 'whenever'")
    Right _ -> assert "an unparsable finish timestamp is rejected" false
  case State.parseState "{\"jobs\":[{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"finishedAt\":\"2026-10-16T12:01:00Z\",\"outcome\":\"bananas\"}]}" of
    Left error -> assert "unknown job outcome is rejected" (error == "state: invalid job outcome 'bananas'")
    Right _ -> assert "unknown job outcome is rejected" false
  let jobEntry index =
        "{\"id\":\"job" <> show index <> "\",\"name\":\"Job " <> show index
          <> "\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"finishedAt\":\"2026-10-16T12:01:00Z\",\"outcome\":\"completed\"}"
      jobsJson indexes = "{\"jobs\":[" <> joinWith "," (map jobEntry indexes) <> "]}"
  case State.parseState (jobsJson (Array.range 0 31)) of
    Left error -> do
      Console.error ("FAIL: ledger at limit: " <> error)
      Sys.exit 1
    Right atLimit -> assert "ledger accepts up to the limit" (Array.length atLimit.jobs == State.maxPersistedJobs)
  case State.parseState (jobsJson (Array.range 0 32)) of
    Left error -> assert "parse rejects a ledger beyond the limit" (error == "state: job ledger limit (32) exceeded")
    Right _ -> assert "parse rejects a ledger beyond the limit" false
  let minimalJob = "{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\"}"
      finishedJob = "{\"id\":\"a\",\"name\":\"A\",\"step\":\"police\",\"startedAt\":\"2026-10-16T12:00:00Z\",\"finishedAt\":\"2026-10-16T12:01:00Z\",\"outcome\":\"completed\"}"
  case State.parseState ("{\"jobs\":[" <> minimalJob <> "," <> minimalJob <> "]}") of
    Left error -> assert "duplicate unfinished job ids are rejected at parse" (error == "state: duplicate unfinished job id 'a'")
    Right _ -> assert "duplicate unfinished job ids are rejected at parse" false
  case State.parseState ("{\"jobs\":[" <> finishedJob <> "," <> finishedJob <> "]}") of
    Left error -> do
      Console.error ("FAIL: finished jobs may share an id: " <> error)
      Sys.exit 1
    Right shared -> assert "finished jobs may share an id" (Array.length shared.jobs == 2)
  case State.setField "jobs" (fromArray []) State.emptyState of
    Left error -> assert "set rejects a structured jobs value" (error == "state: field 'jobs' is read-only — use job-start and job-end")
    Right _ -> assert "set rejects a structured jobs value" false
  case State.setField "jobs" (fromString "implement") State.emptyState of
    Left error -> assert "set rejects a string jobs value" (error == "state: field 'jobs' is read-only — use job-start and job-end")
    Right _ -> assert "set rejects a string jobs value" false
  case Results.jsonValueFor "jobs" "implement" >>= \json -> State.setField "jobs" json State.emptyState of
    Left error -> assert "string jobs values are rejected read-only at setField" (error == "state: field 'jobs' is read-only — use job-start and job-end")
    Right _ -> assert "string jobs values are rejected read-only at setField" false
  case Results.jsonValueFor "jobs" "[]" of
    Left error -> do
      Console.error ("FAIL: jobs structured value parses: " <> error)
      Sys.exit 1
    Right _ -> assert "jobs structured values reach the reserved-field guard" true
  case State.appendJob openJob State.emptyState of
    Left error -> do
      Console.error ("FAIL: append open job: " <> error)
      Sys.exit 1
    Right withOpen -> do
      assert "job appends to the ledger" (Array.length withOpen.jobs == 1)
      case State.appendJob openJob withOpen of
        Left error -> assert "duplicate unfinished job start is rejected" (error == "state: job 'police-pass2' already running")
        Right _ -> assert "duplicate unfinished job start is rejected" false
      case State.appendJob (openJob { id = "police-pass3" }) withOpen of
        Left error -> do
          Console.error ("FAIL: append distinct job: " <> error)
          Sys.exit 1
        Right two -> do
          assert "distinct ids append" (Array.length two.jobs == 2)
          let finishedFiller =
                openJob
                  { id = "done-filler"
                  , finished = Just
                      { finishedAt: "2026-10-16T12:05:00Z"
                      , outcome: State.JobCompleted
                      , verification: Nothing
                      }
                  }
              atLimit = two { jobs = two.jobs <> Array.replicate (State.maxPersistedJobs - Array.length two.jobs) finishedFiller }
          assert "limit fixture reaches the bound" (Array.length atLimit.jobs == State.maxPersistedJobs)
          case State.appendJob (openJob { id = "one-too-many" }) atLimit of
            Left error -> assert "append rejects a full ledger" (error == "state: job ledger limit (32) reached")
            Right _ -> assert "append rejects a full ledger" false
      case State.resolveJob "ghost" State.JobFailed Nothing "2026-10-16T12:05:00Z" withOpen of
        Left error -> assert "ending an unknown job is rejected" (error == "state: no unfinished job 'ghost'")
        Right _ -> assert "ending an unknown job is rejected" false
      case State.resolveJob "police-pass2" State.JobEscalated (Just "escalated to owner") "2026-10-16T12:05:00Z" withOpen of
        Left error -> do
          Console.error ("FAIL: resolve open job: " <> error)
          Sys.exit 1
        Right resolved -> do
          case Array.head resolved.jobs of
            Just ended -> case ended.finished of
              Just finish ->
                assert
                  "resolve records the finish pair with verification"
                  ( finish.finishedAt == "2026-10-16T12:05:00Z"
                      && finish.outcome == State.JobEscalated
                      && finish.verification == Just "escalated to owner"
                  )
              Nothing -> assert "resolve records the finish pair with verification" false
            Nothing -> assert "resolve records the finish pair with verification" false
          case State.resolveJob "police-pass2" State.JobCompleted Nothing "2026-10-16T12:06:00Z" resolved of
            Left error -> assert "finished job cannot end twice" (error == "state: no unfinished job 'police-pass2'")
            Right _ -> assert "finished job cannot end twice" false
  case Ops.parseDriverOp [ "job-start", "p1", "Pass 1", "police" ] of
    Left error -> do
      Console.error ("FAIL: job-start rejected: " <> error.message)
      Sys.exit 1
    Right (Ops.DriverJobStart options) ->
      assert "job-start parses without a budget" (options.id == "p1" && options.name == "Pass 1" && options.step == "police" && options.budgetMinutes == Nothing)
    Right _ -> assert "job-start parses without a budget" false
  case Ops.parseDriverOp [ "job-start", "p1", "Pass 1", "police", "10" ] of
    Left error -> do
      Console.error ("FAIL: job-start budget rejected: " <> error.message)
      Sys.exit 1
    Right (Ops.DriverJobStart options) -> assert "budgetMinutes parses" (options.budgetMinutes == Just 10)
    Right _ -> assert "budgetMinutes parses" false
  let budgetCase text = case Ops.parseDriverOp [ "job-start", "p1", "Pass", "police", text ] of
        Left error -> assert ("budgetMinutes rejects " <> text) (error.message == "job-start: budgetMinutes must be an integer between 1 and 120")
        Right _ -> assert ("budgetMinutes rejects " <> text) false
  budgetCase "0"
  budgetCase "121"
  budgetCase "12.5"
  budgetCase "abc"
  case Ops.parseDriverOp [ "job-start", "", "Pass", "police" ] of
    Left error -> assert "job-start requires an id" (error.message == "id required")
    Right _ -> assert "job-start requires an id" false
  case Ops.parseDriverOp [ "job-start", "p1", "", "police" ] of
    Left error -> assert "job-start requires a name" (error.message == "name required")
    Right _ -> assert "job-start requires a name" false
  case Ops.parseDriverOp [ "job-start", "p1", "Pass", "reserch" ] of
    Left error -> assert "job-start validates the step vocabulary" (error.code == 2)
    Right _ -> assert "job-start validates the step vocabulary" false
  case Ops.parseDriverOp [ "job-end", "p1", "completed" ] of
    Left error -> do
      Console.error ("FAIL: job-end rejected: " <> error.message)
      Sys.exit 1
    Right (Ops.DriverJobEnd options) ->
      assert "job-end parses a bare outcome" (options.id == "p1" && options.outcome == State.JobCompleted && options.verification == Nothing)
    Right _ -> assert "job-end parses a bare outcome" false
  case Ops.parseDriverOp [ "job-end", "p1", "escalated", "specs verified" ] of
    Left error -> do
      Console.error ("FAIL: job-end verification rejected: " <> error.message)
      Sys.exit 1
    Right (Ops.DriverJobEnd options) ->
      assert "job-end keeps the verification" (options.outcome == State.JobEscalated && options.verification == Just "specs verified")
    Right _ -> assert "job-end keeps the verification" false
  case Ops.parseDriverOp [ "job-end", "p1", "cancelled" ] of
    Right (Ops.DriverJobEnd options) -> assert "job-end accepts cancelled" (options.outcome == State.JobCancelled)
    _ -> assert "job-end accepts cancelled" false
  case Ops.parseDriverOp [ "job-end", "p1", "failed" ] of
    Right (Ops.DriverJobEnd options) -> assert "job-end accepts failed" (options.outcome == State.JobFailed)
    _ -> assert "job-end accepts failed" false
  case Ops.parseDriverOp [ "job-end", "p1", "finished" ] of
    Left error -> assert "job-end validates the outcome" (error.message == "do-driver: invalid outcome 'finished' (completed|failed|cancelled|escalated)")
    Right _ -> assert "job-end validates the outcome" false
  case Ops.parseDriverOp [ "job-end", "p1" ] of
    Left error -> assert "job-end requires an outcome" (error.message == "outcome required (completed|failed|cancelled|escalated)")
    Right _ -> assert "job-end requires an outcome" false
