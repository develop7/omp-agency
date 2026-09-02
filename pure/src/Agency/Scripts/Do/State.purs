module Agency.Scripts.Do.State
  ( PendingStep
  , Step
  , State
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
  , isoField
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
import Foreign.Object as Obj

import Agency.Scripts.Do.Sys as Sys

-- | A step that has begun but has not yet been recorded as complete.
type PendingStep =
  { name :: String
  , startedAt :: String
  }

-- | A completed workflow step. `reason` is omitted from JSON when absent.
type Step =
  { name :: String
  , status :: String
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
  , active :: String
  , status :: String
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
  , active: "idle"
  , status: "idle"
  , steps: []
  , pendingStep: Nothing
  , extras: Map.empty
  }

initState :: String -> State
initState startedAt =
  emptyState
    { startedAt = startedAt
    , active = "working"
    , status = "running"
    }

-- | Read a required JSON string field from an object.
requiredString :: String -> Obj.Object Json -> Either String String
requiredString key object =
  case Obj.lookup key object >>= toString of
    Just value -> Right value
    Nothing -> Left ("state: field '" <> key <> "' must be a string")

optionalString :: String -> String -> Obj.Object Json -> Either String String
optionalString key fallback object =
  case Obj.lookup key object of
    Nothing -> Right fallback
    Just value -> case toString value of
      Just text -> Right text
      Nothing -> Left ("state: field '" <> key <> "' must be a string")


optionalJsonString :: String -> Obj.Object Json -> Either String (Maybe String)
optionalJsonString key object =
  case Obj.lookup key object of
    Nothing -> Right Nothing
    Just value -> case toString value of
      Just text -> Right (Just text)
      Nothing -> Left ("state: field '" <> key <> "' must be a string")

parseStep :: Json -> Either String Step
parseStep value = do
  object <- case toObject value of
    Just result -> Right result
    Nothing -> Left "state: each step must be an object"
  name <- requiredString "name" object
  status <- requiredString "status" object
  verification <- requiredString "verification" object
  startedAt <- requiredString "startedAt" object
  completedAt <- requiredString "completedAt" object
  reason <- optionalJsonString "reason" object
  pure { name, status, verification, startedAt, completedAt, reason }

parsePending :: Json -> Either String PendingStep
parsePending value = do
  object <- case toObject value of
    Just result -> Right result
    Nothing -> Left "state: pendingStep must be an object"
  name <- requiredString "name" object
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
  active <- optionalString "active" "idle" object
  status <- optionalString "status" "idle" object
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
  pure { workflow, startedAt, active, status, steps, pendingStep, extras }

stepJson :: Step -> Json
stepJson step =
  let
    base =
      Obj.fromFoldable
        [ Tuple "name" (fromString step.name)
        , Tuple "status" (fromString step.status)
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
      , Tuple "active" (fromString state.active)
      , Tuple "status" (fromString state.status)
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
    "active" -> Just (fromString state.active)
    "status" -> Just (fromString state.status)
    "steps" -> Just (fromArray (map stepJson state.steps))
    "pendingStep" -> pendingJson <$> state.pendingStep
    _ -> Map.lookup key state.extras

-- | The shell helper's string projection: absent/non-string fields are empty.
stateGet :: String -> State -> String
stateGet key state =
  case stateGetJson key state >>= toString of
    Just value -> value
    Nothing -> ""

-- | Set a CLI field. Known scalar fields retain their typed representation;
-- | every other field is preserved as an arbitrary JSON value in `extras`.
setField :: String -> Json -> State -> State
setField key value state =
  case key of
    "workflow" -> state { workflow = fromMaybe state.workflow (toString value) }
    "startedAt" -> state { startedAt = fromMaybe state.startedAt (toString value) }
    "active" -> state { active = fromMaybe state.active (toString value) }
    "status" -> state { status = fromMaybe state.status (toString value) }
    _ -> state { extras = Map.insert key value state.extras }

appendStep :: Step -> State -> State
appendStep step state = state { steps = state.steps <> [ step ] }

startPending :: PendingStep -> State -> State
startPending pending state = state { pendingStep = Just pending }

finishPending :: State -> State
finishPending state = state { pendingStep = Nothing }

-- | Load state if present. A missing file is represented by `Nothing` so callers
-- | such as VCS/forge detection can implement their documented fallback.
readState :: String -> Effect (Either String (Maybe State))
readState path = do
  present <- Sys.exists path
  if not present then pure (Right Nothing)
  else do
    source <- Sys.readUtf8 path
    pure (case parseState source of
      Left error -> Left error
      Right value -> Right (Just value))

writeState :: String -> State -> Effect Unit
writeState path state = do
  Sys.writeUtf8 (path <> ".tmp") (stringifyState state)
  Sys.rename (path <> ".tmp") path

-- | Convenience projection used by the step/timing formatter.
isoField :: String -> State -> String
isoField = stateGet
