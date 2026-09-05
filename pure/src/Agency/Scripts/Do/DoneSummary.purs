module Agency.Scripts.Do.DoneSummary
  ( DoneRow
  , DoneSummary
  , run
  , compute
  , renderMarkdown
  , renderFacts
  , render
  , fmtDur
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Results as Results
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), Replacement(..), joinWith, replaceAll)
import Data.String.CodeUnits (drop)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)

run :: WorkflowContext -> Effect Outcome.OpOutcome
run context = do
  loaded <- Results.loadState context
  case loaded of
    Left error -> pure (failText (if Args.startsWith "do-results: " error then "done: " <> drop 12 error else error))
    Right state -> do
      summary <- compute state
      case summary of
        Left error -> pure (failText ("done: " <> error))
        Right value -> pure (Outcome.withStdout (renderMarkdown value <> renderFacts value))

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
compute :: State.State -> Effect (Either String DoneSummary)
compute state = do
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
renderMarkdown :: DoneSummary -> String
renderMarkdown summary =
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
render :: State.State -> Int -> Effect String
render state totalDuration = do
  summary <- compute state
  pure case summary of
    Left error -> "done: " <> error <> "\n"
    Right value ->
      let overridden = value { totalSeconds = totalDuration }
      in renderMarkdown overridden <> renderFacts overridden

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


failText :: String -> Outcome.OpOutcome
failText message = Outcome.failure 1 (message <> "\n")
