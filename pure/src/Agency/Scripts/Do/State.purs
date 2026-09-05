module Agency.Scripts.Do.State
  ( PendingStep
  , ActiveStatus(..)
  , WorkflowStatus(..)
  , StepStatus(..)
  , Step
  , State
  , parseActiveStatus
  , renderActiveStatus
  , parseWorkflowStatus
  , renderWorkflowStatus
  , parseStepStatus
  , renderStepStatus
  , emptyState
  , initState
  , parseState
  , stringifyState
  , readState
  , writeState
  , stateGet
  , stateGetJson
  , setField
  , appendStep
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
import Effect.Exception (try)
import Foreign.Object as Obj
import Node.Errors.SystemError as SystemError
import Unsafe.Coerce (unsafeCoerce)

import Agency.Scripts.Do.Args as Args
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

-- | Workflow state. Fields written by other workflow layers live in `extras`.
-- | Keeping them as Json preserves unknown values exactly across a load/save.
type State =
  { workflow :: String
  , startedAt :: String
  , active :: ActiveStatus
  , status :: WorkflowStatus
  , steps :: Array Step
  , pendingStep :: Maybe PendingStep
  , extras :: Map String Json
  }

knownKeys :: Array String
knownKeys = [ "workflow", "startedAt", "active", "status", "steps", "pendingStep" ]

emptyState :: State
emptyState =
  { workflow: "do"
  , startedAt: ""
  , active: ActiveIdle
  , status: WorkflowIdle
  , steps: []
  , pendingStep: Nothing
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
  if Args.isWorkflowStep name then pure unit else Left ("state: unknown step '" <> name <> "'")
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
  if Args.isWorkflowStep name then pure unit else Left ("state: unknown pending step '" <> name <> "'")
  startedAt <- requiredString "startedAt" object
  pure { name, startedAt }

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
      Just values -> traverse parseStep values
  pendingStep <- case Obj.lookup "pendingStep" object of
    Nothing -> Right Nothing
    Just value -> if Json.isNull value then Right Nothing else Just <$> parsePending value
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
    extras =
      Array.sortWith fst (Map.toUnfoldable state.extras :: Array (Tuple String Json))
  in Json.stringify (fromObject (Obj.fromFoldable (withPending <> extras)))

stateGetJson :: String -> State -> Maybe Json
stateGetJson key state =
  case key of
    "workflow" -> Just (fromString state.workflow)
    "startedAt" -> Just (fromString state.startedAt)
    "active" -> Just (fromString (renderActiveStatus state.active))
    "status" -> Just (fromString (renderWorkflowStatus state.status))
    "steps" -> Just (fromArray (map stepJson state.steps))
    "pendingStep" -> pendingJson <$> state.pendingStep
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
        steps <- traverse parseStep values
        pure (state { steps = steps })
    "pendingStep" ->
      if Json.isNull value then Right (state { pendingStep = Nothing })
      else do
        pending <- parsePending value
        pure (state { pendingStep = Just pending })
    _ -> Right (state { extras = Map.insert key value state.extras })
  where
  stringField field =
    case toString value of
      Just text -> Right text
      Nothing -> Left ("state: field '" <> field <> "' must be a string")
  setStringField field update = update <$> stringField field

-- | State is rewritten for one workflow lifetime. A normal run appends roughly
-- | 15 steps, so retaining the complete history is bounded by that run's step
-- | count; eviction would diverge from the incumbent shell contract.
appendStep :: Step -> State -> State
appendStep step state = state { steps = state.steps <> [ step ] }

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

writeState :: String -> State -> Effect Unit
writeState path state = do
  temporary <- Sys.uniqueTempPath path
  Sys.writeUtf8 temporary (stringifyState state)
  Sys.rename temporary path
