module Agency.Scripts.Do.State
  ( PendingStep
  , ActiveStatus(..)
  , WorkflowStatus(..)
  , StepStatus(..)
  , Step
  , JobOutcome(..)
  , FinishedJob
  , Job
  , State
  , parseActiveStatus
  , renderActiveStatus
  , parseWorkflowStatus
  , renderWorkflowStatus
  , parseStepStatus
  , renderStepStatus
  , parseJobOutcome
  , renderJobOutcome
  , allJobOutcomes
  , jobOutcomeNames
  , emptyState
  , initState
  , noVcsBaseValue
  , parseState
  , stringifyState
  , readState
  , withStateLock
  , writeState
  , stateGet
  , stateGetJson
  , setField
  , maxPersistedSteps
  , maxPersistedJobs
  , appendStep
  , jobFinished
  , unfinishedJobs
  , jobStalled
  , unparsableDeadline
  , appendJob
  , resolveJob
  , startPending
  , finishPending
  , finishWorkflow
  ) where
import Prelude

import Data.Argonaut.Core (Json, fromArray, fromObject, fromString, toArray, toObject, toString)
import Data.Argonaut.Core as Json
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (any, foldl)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst)
import Effect (Effect)
import Effect.Exception (throwException, try)
import Effect.Exception as Exception
import Foreign.Object as Obj
import Node.Errors.SystemError as SystemError
import Node.FS.Sync as FSSync
import Unsafe.Coerce (unsafeCoerce)

import Agency.Scripts.Do.WorkflowVocabulary as Vocabulary
import Agency.Scripts.Do.Sys as Sys

-- | Activity values accepted by the persisted workflow protocol.
data ActiveStatus
  = ActiveIdle
  | ActiveWorking
  | ActiveWaiting
  | ActiveUnknown String

derive instance eqActiveStatus :: Eq ActiveStatus

parseActiveStatus :: String -> ActiveStatus
parseActiveStatus value = case value of
  "idle" -> ActiveIdle
  "working" -> ActiveWorking
  "waiting" -> ActiveWaiting
  _ -> ActiveUnknown value

renderActiveStatus :: ActiveStatus -> String
renderActiveStatus status = case status of
  ActiveIdle -> "idle"
  ActiveWorking -> "working"
  ActiveWaiting -> "waiting"
  ActiveUnknown value -> value

-- | Lifecycle status values accepted by the persisted workflow protocol.
data WorkflowStatus
  = WorkflowIdle
  | WorkflowRunning
  | WorkflowCompleted
  | WorkflowFailed
  | WorkflowUnknown String

derive instance eqWorkflowStatus :: Eq WorkflowStatus

parseWorkflowStatus :: String -> WorkflowStatus
parseWorkflowStatus value = case value of
  "idle" -> WorkflowIdle
  "running" -> WorkflowRunning
  "completed" -> WorkflowCompleted
  "failed" -> WorkflowFailed
  _ -> WorkflowUnknown value

renderWorkflowStatus :: WorkflowStatus -> String
renderWorkflowStatus status = case status of
  WorkflowIdle -> "idle"
  WorkflowRunning -> "running"
  WorkflowCompleted -> "completed"
  WorkflowFailed -> "failed"
  WorkflowUnknown value -> value

-- | Step result values accepted by the persisted workflow protocol.
data StepStatus
  = StepPassed
  | StepFailed
  | StepSkipped
  | StepUnknown String

derive instance eqStepStatus :: Eq StepStatus

parseStepStatus :: String -> StepStatus
parseStepStatus value = case value of
  "passed" -> StepPassed
  "failed" -> StepFailed
  "skipped" -> StepSkipped
  _ -> StepUnknown value

renderStepStatus :: StepStatus -> String
renderStepStatus status = case status of
  StepPassed -> "passed"
  StepFailed -> "failed"
  StepSkipped -> "skipped"
  StepUnknown value -> value

validActiveStatus :: String -> Either String ActiveStatus
validActiveStatus value = case parseActiveStatus value of
  ActiveUnknown _ -> Left ("state: invalid active '" <> value <> "'")
  status -> Right status

validWorkflowStatus :: String -> Either String WorkflowStatus
validWorkflowStatus value = case parseWorkflowStatus value of
  WorkflowUnknown _ -> Left ("state: invalid status '" <> value <> "'")
  status -> Right status

validStepStatus :: String -> Either String StepStatus
validStepStatus value = case parseStepStatus value of
  StepUnknown _ -> Left ("state: invalid step status '" <> value <> "'")
  status -> Right status

validJobOutcome :: String -> Either String JobOutcome
validJobOutcome value = case parseJobOutcome value of
  JobUnknown _ -> Left ("state: invalid job outcome '" <> value <> "'")
  outcome -> Right outcome

-- | A step that has begun but has not yet been recorded as complete.
type PendingStep =
  { name :: String
  , startedAt :: String
  }

-- | A completed workflow step. `reason` is omitted from JSON when absent.
type Step =
  { name :: String
  , status :: StepStatus
  , verification :: String
  , startedAt :: String
  , completedAt :: String
  , reason :: Maybe String
  }

-- | Terminal results recorded by job-end.
data JobOutcome
  = JobCompleted
  | JobFailed
  | JobCancelled
  | JobEscalated
  | JobUnknown String

derive instance eqJobOutcome :: Eq JobOutcome

-- | Every terminal job outcome. This list is the single home for the
-- | vocabulary; parsers and message builders derive from it instead of
-- | re-spelling the names, so a new outcome cannot be added in one place
-- | and missed in another.
allJobOutcomes :: Array JobOutcome
allJobOutcomes = [ JobCompleted, JobFailed, JobCancelled, JobEscalated ]

-- | The rendered names of every job outcome, for hints and error messages
-- | that must stay in sync with what `parseJobOutcome` accepts.
jobOutcomeNames :: Array String
jobOutcomeNames = map renderJobOutcome allJobOutcomes

-- | Resolve a persisted outcome name through `allJobOutcomes`, so accepted
-- | and rendered spellings come from one list; anything else stays visible
-- | as `JobUnknown` for the validators to reject.
parseJobOutcome :: String -> JobOutcome
parseJobOutcome value =
  fromMaybe (JobUnknown value) (Array.find (\outcome -> renderJobOutcome outcome == value) allJobOutcomes)

-- | The canonical persisted name of an outcome, the inverse of
-- | `parseJobOutcome`. `JobUnknown` renders its own text so a rejected value
-- | can be echoed back unchanged.
renderJobOutcome :: JobOutcome -> String
renderJobOutcome outcome = case outcome of
  JobCompleted -> "completed"
  JobFailed -> "failed"
  JobCancelled -> "cancelled"
  JobEscalated -> "escalated"
  JobUnknown value -> value

-- | The terminal component of a job. `finishedAt` and `outcome` must appear
-- | together and `verification` belongs only to finished jobs, so all three
-- | live in one record: an unfinished job cannot carry any of them. The
-- | persisted JSON contract stays flat — encode/decode flatten and unflatten
-- | this component, and decode rejects any partial flat spelling.
type FinishedJob =
  { finishedAt :: String
  , outcome :: JobOutcome
  , verification :: Maybe String
  }

-- | A worker-owned job. Only `job-start`/`job-end` write these fields, so
-- | timestamps are always driver-computed and never caller-supplied.
-- | `finished` present means the job is finished; Nothing means it is open,
-- | and verification is unrepresentable while it is.
type Job =
  { id :: String
  , name :: String
  , step :: String
  , startedAt :: String
  , deadline :: Maybe String
  , finished :: Maybe FinishedJob
  }

-- | Workflow state. Fields written by other workflow layers live in `extras`.
-- | Keeping them as Json preserves unknown values exactly across a load/save.
type State =
  { workflow :: String
  , startedAt :: String
  , active :: ActiveStatus
  , status :: WorkflowStatus
  , steps :: Array Step
  , pendingStep :: Maybe PendingStep
  , jobs :: Array Job
  , extras :: Map String Json
  }

-- | The persisted protocol retains at most 64 completed steps. This leaves
-- | room for recovery loops while preventing an indefinitely growing audit log.
maxPersistedSteps :: Int
maxPersistedSteps = 64

stepHistoryLimitError :: String -> String
stepHistoryLimitError condition =
  "state: step history limit (" <> show maxPersistedSteps <> ") " <> condition

boundedStepValues :: Array Json -> Either String (Array Json)
boundedStepValues values =
  if Array.length values > maxPersistedSteps then
    Left (stepHistoryLimitError "exceeded")
  else Right values

-- | The jobs ledger is bounded so worker bookkeeping cannot grow without end.
maxPersistedJobs :: Int
maxPersistedJobs = 32

jobLimitError :: String -> String
jobLimitError condition =
  "state: job ledger limit (" <> show maxPersistedJobs <> ") " <> condition

boundedJobValues :: Array Json -> Either String (Array Json)
boundedJobValues values =
  if Array.length values > maxPersistedJobs then
    Left (jobLimitError "exceeded")
  else Right values

knownKeys :: Array String
knownKeys = [ "workflow", "startedAt", "active", "status", "steps", "pendingStep", "jobs" ]

-- | Sentinel `base` for --no-vcs runs: non-empty so workflow gates pass, but
-- | it names no ref and must never be carried into a VCS-backed run.
noVcsBaseValue :: String
noVcsBaseValue = "no-vcs"

emptyState :: State
emptyState =
  { workflow: "do"
  , startedAt: ""
  , active: ActiveIdle
  , status: WorkflowIdle
  , steps: []
  , pendingStep: Nothing
  , jobs: []
  , extras: Map.empty
  }

initState :: String -> State
initState startedAt =
  emptyState
    { startedAt = startedAt
    , active = ActiveWorking
    , status = WorkflowRunning
    }

-- | Decode one optional JSON string once; required/default projections reuse
-- | this primitive so missing and malformed fields cannot diverge.
stringValue :: String -> Obj.Object Json -> Either String (Maybe String)
stringValue key object =
  case Obj.lookup key object of
    Nothing -> Right Nothing
    Just value -> case toString value of
      Just text -> Right (Just text)
      Nothing -> Left ("state: field '" <> key <> "' must be a string")

requiredString :: String -> Obj.Object Json -> Either String String
requiredString key object = do
  value <- stringValue key object
  case value of
    Just text -> Right text
    Nothing -> Left ("state: field '" <> key <> "' must be a string")

optionalString :: String -> String -> Obj.Object Json -> Either String String
optionalString key fallback object = fromMaybe fallback <$> stringValue key object

parseStep :: Json -> Either String Step
parseStep value = do
  object <- case toObject value of
    Just result -> Right result
    Nothing -> Left "state: each step must be an object"
  name <- requiredString "name" object
  validStepName name
  statusText <- requiredString "status" object
  status <- validStepStatus statusText
  verification <- requiredString "verification" object
  startedAt <- requiredString "startedAt" object
  completedAt <- requiredString "completedAt" object
  reason <- stringValue "reason" object
  pure { name, status, verification, startedAt, completedAt, reason }

parsePending :: Json -> Either String PendingStep
parsePending value = do
  object <- case toObject value of
    Just result -> Right result
    Nothing -> Left "state: pendingStep must be an object"
  name <- requiredString "name" object
  if Array.elem name Vocabulary.workflowSteps then pure unit else Left ("state: unknown pending step '" <> name <> "'")
  startedAt <- requiredString "startedAt" object
  pure { name, startedAt }

parseJob :: Json -> Either String Job
parseJob value = do
  object <- case toObject value of
    Just result -> Right result
    Nothing -> Left "state: each job must be an object"
  id <- requiredString "id" object
  name <- requiredString "name" object
  step <- requiredString "step" object
  startedAt <- requiredString "startedAt" object
  deadline <- stringValue "deadline" object
  finishedAt <- stringValue "finishedAt" object
  outcomeValue <- stringValue "outcome" object
  verification <- stringValue "verification" object
  finished <- case finishedAt, outcomeValue, verification of
    Nothing, Nothing, Nothing -> Right Nothing
    Nothing, Nothing, Just _ ->
      Left ("state: job '" <> id <> "' verification requires a finished job")
    Just at, Just text, _ -> do
      outcome <- validJobOutcome text
      pure (Just { finishedAt: at, outcome, verification })
    _, _, _ ->
      Left ("state: job '" <> id <> "' must record finishedAt and outcome together")
  let job = { id, name, step, startedAt, deadline, finished }
  validJob job
  pure job

-- | Structural invariants shared by parse and append. The finish component's
-- | pairing is structural: the decoder only builds it from a complete flat
-- | spelling, so a partial one is rejected before it reaches this check.
-- | Finished jobs also obey the same interval rule as steps: the finish
-- | cannot precede the start, and both timestamps must be canonical UTC
-- | strings to be compared — their fixed-width format makes lexicographic
-- | order chronological, so corrupt or hand-edited state surfaces as a parse
-- | error instead of silently loading. Unfinished jobs carry no interval.
validJob :: Job -> Either String Unit
validJob job = do
  if job.id == "" then Left "state: job id must be non-empty" else Right unit
  if job.name == "" then Left "state: job name must be non-empty" else Right unit
  validStepName job.step
  case job.finished of
    Nothing -> Right unit
    Just finished
      | not (Sys.isCanonicalIso job.startedAt) ->
          Left ("state: invalid timestamp '" <> job.startedAt <> "'")
      | not (Sys.isCanonicalIso finished.finishedAt) ->
          Left ("state: invalid timestamp '" <> finished.finishedAt <> "'")
      | finished.finishedAt < job.startedAt ->
          Left
            ( "state: job '" <> job.id <> "' finishedAt '" <> finished.finishedAt
                <> "' precedes startedAt '" <> job.startedAt
                <> "'"
            )
      | otherwise -> Right unit

-- | The contract only constrains id uniqueness among unfinished jobs, so a
-- | finished job's id may be reused by a later run.
validateUnfinishedIds :: Array Job -> Either String Unit
validateUnfinishedIds jobs =
  case firstDuplicate (map _.id (Array.filter (not <<< jobFinished) jobs)) of
    Nothing -> Right unit
    Just jobId -> Left ("state: duplicate unfinished job id '" <> jobId <> "'")

firstDuplicate :: Array String -> Maybe String
firstDuplicate values = go values []
  where
  go remaining seen = case Array.uncons remaining of
    Nothing -> Nothing
    Just { head, tail } ->
      if Array.elem head seen then Just head else go tail (seen <> [ head ])

parseState :: String -> Either String State
parseState source = do
  json <- jsonParser source
  object <- case toObject json of
    Just result -> Right result
    Nothing -> Left "state: top-level value must be an object"
  workflow <- optionalString "workflow" "do" object
  startedAt <- optionalString "startedAt" "" object
  activeText <- optionalString "active" "idle" object
  active <- validActiveStatus activeText
  statusText <- optionalString "status" "idle" object
  status <- validWorkflowStatus statusText
  steps <- case Obj.lookup "steps" object of
    Nothing -> Right []
    Just value -> case toArray value of
      Nothing -> Left "state: field 'steps' must be an array"
      Just values -> traverse parseStep =<< boundedStepValues values
  pendingStep <- case Obj.lookup "pendingStep" object of
    Nothing -> Right Nothing
    Just value -> if Json.isNull value then Right Nothing else Just <$> parsePending value
  jobs <- case Obj.lookup "jobs" object of
    Nothing -> Right []
    Just value -> case toArray value of
      Nothing -> Left "state: field 'jobs' must be an array"
      Just values -> do
        boundedValues <- boundedJobValues values
        parsedJobs <- traverse parseJob boundedValues
        validateUnfinishedIds parsedJobs
        pure parsedJobs
  let extras =
        foldl
          (\acc key ->
            if any (\known -> known == key) knownKeys then acc
            else case Obj.lookup key object of
              Just value -> Map.insert key value acc
              Nothing -> acc)
          Map.empty
          (Obj.keys object)
  pure
    { workflow
    , startedAt
    , active
    , status
    , steps
    , pendingStep
    , jobs
    , extras
    }

stepJson :: Step -> Json
stepJson step =
  let
    base =
      Obj.fromFoldable
        [ Tuple "name" (fromString step.name)
        , Tuple "status" (fromString (renderStepStatus step.status))
        , Tuple "verification" (fromString step.verification)
        , Tuple "startedAt" (fromString step.startedAt)
        , Tuple "completedAt" (fromString step.completedAt)
        ]
  in case step.reason of
    Nothing -> fromObject base
    Just reason -> fromObject (Obj.insert "reason" (fromString reason) base)

pendingJson :: PendingStep -> Json
pendingJson pending =
  fromObject
    (Obj.fromFoldable
      [ Tuple "name" (fromString pending.name)
      , Tuple "startedAt" (fromString pending.startedAt)
      ])

jobJson :: Job -> Json
jobJson job =
  let
    base =
      Obj.fromFoldable
        [ Tuple "id" (fromString job.id)
        , Tuple "name" (fromString job.name)
        , Tuple "step" (fromString job.step)
        , Tuple "startedAt" (fromString job.startedAt)
        ]
    withDeadline = case job.deadline of
      Nothing -> base
      Just deadline -> Obj.insert "deadline" (fromString deadline) base
  in case job.finished of
    Nothing -> fromObject withDeadline
    Just finished ->
      let
        withFinishedAt = Obj.insert "finishedAt" (fromString finished.finishedAt) withDeadline
        withOutcome = Obj.insert "outcome" (fromString (renderJobOutcome finished.outcome)) withFinishedAt
      in case finished.verification of
        Nothing -> fromObject withOutcome
        Just verification -> fromObject (Obj.insert "verification" (fromString verification) withOutcome)

-- | Encode known fields in the historical order and unknown fields sorted by key.
stringifyState :: State -> String
stringifyState state =
  let
    known =
      [ Tuple "workflow" (fromString state.workflow)
      , Tuple "startedAt" (fromString state.startedAt)
      , Tuple "active" (fromString (renderActiveStatus state.active))
      , Tuple "status" (fromString (renderWorkflowStatus state.status))
      , Tuple "steps" (fromArray (map stepJson state.steps))
      ]
    withPending = case state.pendingStep of
      Nothing -> known
      Just pending -> known <> [ Tuple "pendingStep" (pendingJson pending) ]
    -- An empty ledger stays absent, mirroring pendingStep, so state files
    -- without jobs keep their historical shape.
    withJobs =
      if Array.null state.jobs then withPending
      else withPending <> [ Tuple "jobs" (fromArray (map jobJson state.jobs)) ]
    extras =
      Array.sortWith fst (Map.toUnfoldable state.extras :: Array (Tuple String Json))
  in Json.stringify (fromObject (Obj.fromFoldable (withJobs <> extras)))

stateGetJson :: String -> State -> Maybe Json
stateGetJson key state =
  case key of
    "workflow" -> Just (fromString state.workflow)
    "startedAt" -> Just (fromString state.startedAt)
    "active" -> Just (fromString (renderActiveStatus state.active))
    "status" -> Just (fromString (renderWorkflowStatus state.status))
    "steps" -> Just (fromArray (map stepJson state.steps))
    "pendingStep" -> pendingJson <$> state.pendingStep
    "jobs" -> if Array.null state.jobs then Nothing else Just (fromArray (map jobJson state.jobs))
    _ -> Map.lookup key state.extras

-- | The shell helper's string projection: absent/non-string fields are empty.
stateGet :: String -> State -> String
stateGet key state =
  case stateGetJson key state >>= toString of
    Just value -> value
    Nothing -> ""

-- | Set a CLI field while preserving the State invariants.
-- | Reserved structured fields are decoded and never fall through to extras.
setField :: String -> Json -> State -> Either String State
setField key value state =
  case key of
    "workflow" -> setStringField key (\text -> state { workflow = text })
    "startedAt" -> setStringField key (\text -> state { startedAt = text })
    "active" -> do
      text <- stringField key
      active <- validActiveStatus text
      pure (state { active = active })
    "status" -> do
      text <- stringField key
      status <- validWorkflowStatus text
      pure (state { status = status })
    "steps" -> case toArray value of
      Nothing -> Left "state: field 'steps' must be an array"
      Just values -> do
        boundedValues <- boundedStepValues values
        steps <- traverse parseStep boundedValues
        pure (state { steps = steps })
    "pendingStep" ->
      if Json.isNull value then Right (state { pendingStep = Nothing })
      else do
        pending <- parsePending value
        pure (state { pendingStep = Just pending })
    "jobs" -> Left "state: field 'jobs' is read-only — use job-start and job-end"
    _ -> Right (state { extras = Map.insert key value state.extras })
  where
  stringField field =
    case toString value of
      Just text -> Right text
      Nothing -> Left ("state: field '" <> field <> "' must be a string")
  setStringField field update = update <$> stringField field

validStepName :: String -> Either String Unit
validStepName name =
  if Array.elem name Vocabulary.workflowSteps then Right unit
  else Left ("state: unknown step '" <> name <> "'")

validStep :: Step -> Either String Step
validStep step = do
  validStepName step.name
  _ <- validStepStatus (renderStepStatus step.status)
  pure step

appendStep :: Step -> State -> Either String State
appendStep step state = do
  _ <- validStep step
  if Array.length state.steps >= maxPersistedSteps then
    Left (stepHistoryLimitError "reached")
  else Right (state { steps = state.steps <> [ step ] })

-- | Whether the job carries its finish component. The typed pairing makes
-- | this the one "is it done" question — there is no half-finished state.
jobFinished :: Job -> Boolean
jobFinished job = case job.finished of
  Just _ -> true
  Nothing -> false

-- | The open jobs in ledger order. Every gate that must not yield with
-- | incomplete worker work — step-end, the corrective step record, summary,
-- | and restart carry-over — filters through this one definition.
unfinishedJobs :: State -> Array Job
unfinishedJobs state = Array.filter (not <<< jobFinished) state.jobs

-- | Parse the stored deadline once for stall evaluation and diagnostics.
-- | `Nothing` means the job has no deadline; `Left` carries the raw text
-- | when the stored value cannot be parsed.
deadlineEpoch :: Job -> Effect (Maybe (Either String Int))
deadlineEpoch job = case job.deadline of
  Nothing -> pure Nothing
  Just raw -> do
    parsed <- Sys.isoToEpoch raw
    pure case parsed of
      Left _ -> Just (Left raw)
      Right epoch -> Just (Right epoch)

-- | A job whose persisted deadline has already passed at `nowEpoch`.
-- | An unparsable deadline never counts as stalled; callers that must not
-- | swallow that anomaly report it through `unparsableDeadline`.
jobStalled :: Int -> Job -> Effect Boolean
jobStalled nowEpoch job = do
  parsed <- deadlineEpoch job
  pure case parsed of
    Just (Right limitEpoch) -> limitEpoch < nowEpoch
    _ -> false

-- | The raw stored deadline when it cannot be parsed. Absent when the job
-- | has no deadline or the value parses, so the summary can mark the
-- | contract breakage that `jobStalled` deliberately treats as unstalled.
unparsableDeadline :: Job -> Effect (Maybe String)
unparsableDeadline job = do
  parsed <- deadlineEpoch job
  pure case parsed of
    Just (Left raw) -> Just raw
    _ -> Nothing

-- | Append a new unfinished job under the ledger's bounds and id rules.
appendJob :: Job -> State -> Either String State
appendJob job state = do
  validJob job
  if Array.length state.jobs >= maxPersistedJobs then
    Left (jobLimitError "reached")
  else if any (\existing -> not (jobFinished existing) && existing.id == job.id) state.jobs then
    Left ("state: job '" <> job.id <> "' already running")
  else Right (state { jobs = state.jobs <> [ job ] })

-- | Resolve the unfinished job with this id, recording the driver-computed
-- | finish timestamp alongside its outcome. Every outcome but `completed`
-- | must carry a recorded reason, so the ledger can explain why the worker
-- | stopped instead of losing it.
resolveJob :: String -> JobOutcome -> Maybe String -> String -> State -> Either String State
resolveJob jobId outcome verification completedAt state =
  case Array.findIndex (\job -> not (jobFinished job) && job.id == jobId) state.jobs of
    Nothing -> Left ("state: no unfinished job '" <> jobId <> "'")
    Just index -> case outcome, verification of
      JobCompleted, _ -> resolveAt index
      _, Just reason | reason /= "" -> resolveAt index
      _, _ ->
        Left
          ( "state: job '" <> jobId <> "' outcome '" <> renderJobOutcome outcome
              <> "' requires a recorded reason (verification)"
          )
  where
  resolveAt index =
    case Array.index state.jobs index of
      Nothing -> Left ("state: no unfinished job '" <> jobId <> "'")
      Just job
        | completedAt < job.startedAt ->
            -- Canonical UTC strings compare chronologically as text, so a
            -- finish before the start is refused here (same rationale as
            -- `validJob`); writing it would wedge every later load.
            Left
              ( "state: job '" <> job.id <> "' finishedAt '" <> completedAt
                  <> "' precedes startedAt '" <> job.startedAt
                  <> "'"
              )
        | otherwise ->
            let
              resolve job' =
                job' { finished = Just { finishedAt: completedAt, outcome, verification } }
            in Right (state { jobs = fromMaybe state.jobs (Array.modifyAt index resolve state.jobs) })

startPending :: PendingStep -> State -> State
startPending pending state = state { pendingStep = Just pending }

finishPending :: State -> State
finishPending state = state { pendingStep = Nothing }

-- | Mark a terminal lifecycle result and clear active-work signaling.
finishWorkflow :: WorkflowStatus -> State -> State
finishWorkflow status state = state { active = ActiveIdle, status = status }

-- | Load state if present. ENOENT is the documented detection fallback;
-- | every other read error and every parse error remains visible to callers.
readState :: String -> Effect (Either String (Maybe State))
readState path = do
  readResult <- try (Sys.readUtf8 path)
  pure case readResult of
    Left error ->
      if SystemError.code (unsafeCoerce error) == "ENOENT" then Right Nothing
      else Left (SystemError.message (unsafeCoerce error))
    Right source -> case parseState source of
      Left error -> Left error
      Right value -> Right (Just value)

-- | Serialize a complete state transition. Creating the sibling directory is
-- | atomic; a surviving directory may be stale after a crash and must be
-- | explicitly removed only after confirming no mutation is still running.
withStateLock :: forall a. String -> Effect a -> Effect (Either String a)
withStateLock path action = do
  let lockPath = path <> ".lock"
  acquired <- try (FSSync.mkdir lockPath)
  case acquired of
    Left error ->
      let systemError = unsafeCoerce error
      in pure
        ( Left
            ( if SystemError.code systemError == "EEXIST" then
                "state: lock '" <> lockPath <> "' already exists; another state mutation is running, or it is stale after a crash — remove the lock explicitly after confirming no mutation is active"
              else "state: unable to acquire lock '" <> lockPath <> "': " <> SystemError.message systemError
            )
        )
    Right _ -> do
      result <- try action
      released <- try (FSSync.rmdir lockPath)
      case result, released of
        Left actionError, Left releaseError ->
          throwException
            ( Exception.error
                ( Exception.message actionError
                    <> "; additionally failed to release state lock '"
                    <> lockPath
                    <> "': "
                    <> Exception.message releaseError
                )
            )
        Left actionError, Right _ -> throwException actionError
        Right _, Left releaseError ->
          pure (Left ("state: unable to release lock '" <> lockPath <> "': " <> Exception.message releaseError))
        Right value, Right _ -> pure (Right value)

writeState :: String -> State -> Effect Unit
writeState path state = do
  temporary <- Sys.uniqueTempPath path
  result <- try do
    Sys.writeUtf8 temporary (stringifyState state)
    Sys.rename temporary path
  case result of
    Left error -> do
      -- The write may have created a partial file; cleanup must not replace its error.
      _ <- try (FSSync.unlink temporary)
      throwException error
    Right _ -> pure unit
