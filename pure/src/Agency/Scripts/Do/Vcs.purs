module Agency.Scripts.Do.Vcs
  ( module VcsKinds
  , VcsOp(..)
  , DirtyState(..)
  , VcsValue
  , parseVcsOp
  , detectVcs
  , runVcsOp
  , fetchValue
  , refreshDefaultBranchValue
  , remoteUrlValue
  , headRevisionValue
  , defaultBranchValue
  , currentBranchValue
  , currentAtDefault
  , validateBase
  , renderValue
  , inspectDirty
  , vcsName
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
import Agency.Scripts.Do.Binaries as Binaries
import Agency.Scripts.Do.Context (WorkflowContext, stateFile, statePath)
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.VcsKind (VcsKind(..))
import Agency.Scripts.Do.VcsKind (VcsKind(..)) as VcsKinds
import Data.Argonaut.Core as Json
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (fromString)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), Replacement(..), contains, joinWith, replaceAll, split, trim)
import Data.String.CodeUnits (drop, length)
import Data.Traversable (traverse)
import Effect (Effect)

-- | A VCS query keeps its process status alongside the normalized value.
type VcsValue =
  { code :: Int
  , value :: String
  , stdout :: String
  , stderr :: String
  }

-- | Clean requires a successful inspection of a detected VCS.
data DirtyState
  = Clean
  | DirtyDetected
  | NoVcsDetected
  | InspectionFailed Outcome.OpOutcome

-- | The complete vcs-op command algebra. Arguments that are paths are kept
-- | verbatim so git/jj receive the same path list as the shell adapter.
data VcsOp
  = Detect
  | Fetch
  | RemoteUrl
  | HeadRevision
  | HeadCommitSha
  | DefaultBranch
  | CurrentBranch
  | Base
  | Dirty
  | WorkingCopyStatus
  | DiffRange (Array String)
  | DiffNames (Array String)
  | DiffStat (Array String)
  | NewFiles (Array String)
  | LogRange (Array String)
  | LogHead
  | Branch String
  | Commit String (Array String)
  | Push (Maybe String)
  | FixCommit String (Array String)
  | RefreshDefaultBranch
  | FastForwardIfSafe

operationNames :: Array String
operationNames =
  [ "detect"
  , "fetch"
  , "remote-url"
  , "head-revision"
  , "head-commit-sha"
  , "default-branch"
  , "current-branch"
  , "base"
  , "dirty"
  , "working-copy-status"
  , "diff-range"
  , "diff-names"
  , "diff-stat"
  , "new-files"
  , "log-range"
  , "log-head"
  , "branch"
  , "commit"
  , "push"
  , "fix-commit"
  , "refresh-default-branch"
  , "fast-forward-if-safe"
  ]

availableOps :: String
availableOps = joinWith ", " operationNames

vcsName :: VcsKind -> String
vcsName kind = case kind of
  Git -> "git"
  Jj -> "jj"
  Unknown -> "unknown"

-- | Resolve a VCS from already-read inputs. The order is part of the shell
-- | compatibility contract and is kept in one pure decision function.
detectVcs :: Maybe String -> Maybe String -> Boolean -> Boolean -> VcsKind
detectVcs override fromState jjPresent gitPresent =
  case override of
    Just value -> parseKind value
    Nothing -> case fromState of
      Just value -> parseKind value
      Nothing -> if jjPresent then Jj else if gitPresent then Git else Unknown
  where
  parseKind value = case value of
    "git" -> Git
    "jj" -> Jj
    _ -> Unknown

parseVcsOp :: Array String -> Either String VcsOp
parseVcsOp args =
  case Args.requiredNonEmpty args of
    Nothing -> Left (unknownOperation "")
    Just { value: name, rest } ->
      if Array.elem name operationNames then
        case name of
          "detect" -> Right Detect
          "fetch" -> Right Fetch
          "remote-url" -> Right RemoteUrl
          "head-revision" -> Right HeadRevision
          "head-commit-sha" -> Right HeadCommitSha
          "default-branch" -> Right DefaultBranch
          "current-branch" -> Right CurrentBranch
          "base" -> Right Base
          "dirty" -> Right Dirty
          "working-copy-status" -> Right WorkingCopyStatus
          "diff-range" -> Right (DiffRange rest)
          "diff-names" -> Right (DiffNames rest)
          "diff-stat" -> Right (DiffStat rest)
          "new-files" -> Right (NewFiles rest)
          "log-range" -> Right (LogRange rest)
          "log-head" -> Right LogHead
          "branch" -> case Args.requiredNonEmpty rest of
            Just { value: branchName } -> Right (Branch branchName)
            Nothing -> Left "vcs-op branch: branch name required"
          "commit" -> case Args.requiredNonEmpty rest of
            Nothing -> Left "vcs-op commit: commit message required"
            Just { value: message, rest: files } -> Right (Commit message files)
          "push" -> Right (Push (Array.head rest >>= Args.nonEmpty))
          "fix-commit" -> case Args.requiredNonEmpty rest of
            Nothing -> Left "vcs-op fix-commit: commit message required"
            Just { value: message, rest: files } -> Right (FixCommit message files)
          "refresh-default-branch" -> Right RefreshDefaultBranch
          "fast-forward-if-safe" -> Right FastForwardIfSafe
          _ -> Left (unknownOperation name)
      else Left (unknownOperation name)
  where
  unknownOperation name =
    "vcs-op: unknown operation '" <> name <> "'\nAvailable: " <> availableOps
-- | Run one VCS operation against one resolved workflow context. Computed
-- | output is returned to the adapter; only explicitly pass-through commands
-- | inherit the adapter streams.
runVcsOp :: WorkflowContext -> VcsOp -> Effect Outcome.OpOutcome
runVcsOp context operation = case operation of
  Detect -> pure (Outcome.withStdout (vcsName context.vcs <> "\n"))
  Fetch -> fetchValue context
  RemoteUrl -> renderValue <$> remoteUrlResult context
  HeadRevision -> renderValue <$> headRevisionValue context
  HeadCommitSha -> case context.vcs of
    Git -> capturedCommand Binaries.git [ "rev-parse", "HEAD" ] context
    Jj -> headCommitShaJj context
    Unknown -> pure noVcsOutcome
  DefaultBranch -> renderValue <$> defaultBranchValue context
  CurrentBranch -> renderValue <$> currentBranchValue context
  Base -> resolveBase context
  Dirty -> dirty context
  WorkingCopyStatus -> Outcome.captured <$> workingCopyResult context
  DiffRange paths -> diffRange context paths
  DiffNames paths -> diffNames context paths
  DiffStat paths -> diffStat context paths
  NewFiles paths -> newFiles context paths
  LogRange paths -> logRange context paths
  LogHead -> logHead context
  Branch name -> branch context name
  Commit message files -> commit context message files
  Push ref -> push context ref
  FixCommit message files -> fixCommit context message files
  RefreshDefaultBranch -> refreshDefaultBranchValue context
  FastForwardIfSafe -> fastForwardIfSafe context

-- | Fetch only the selected workflow remote. Origin is preferred; a lone
-- | non-origin remote is accepted, while an ambiguous remote set is rejected.
fetchValue :: WorkflowContext -> Effect Outcome.OpOutcome
fetchValue context = case context.vcs of
  Unknown -> pure noVcsOutcome
  Git -> withRemote context \remote ->
    capturedCommand Binaries.git [ "fetch", remote ] context
  Jj -> withRemote context \remote ->
    capturedCommand Binaries.jj [ "git", "fetch", "--remote", remote ] context

-- | Refresh remote HEAD only when Git has a selected remote.
refreshDefaultBranchValue :: WorkflowContext -> Effect Outcome.OpOutcome
refreshDefaultBranchValue context = case context.vcs of
  Git -> withRemote context \remote ->
    capturedCommand Binaries.git [ "remote", "set-head", remote, "--auto" ] context
  Jj -> pure Outcome.success
  Unknown -> pure Outcome.success

fastForwardIfSafe :: WorkflowContext -> Effect Outcome.OpOutcome
fastForwardIfSafe context = case context.vcs of
  Jj -> pure Outcome.success
  Unknown -> pure Outcome.success
  Git -> do
    upstream <- Sys.exec Binaries.git [ "rev-parse", "--abbrev-ref", "@{u}" ]
    if upstream.code /= 0 then
      if noUpstream upstream then pure Outcome.success else pure (Outcome.captured upstream)
    else do
      let upstreamName = trim upstream.stdout
      if upstreamName == "" then pure Outcome.success
      else do
        behind <- Sys.exec Binaries.git [ "rev-list", "--count", "HEAD.." <> upstreamName ]
        if behind.code /= 0 then pure (Outcome.captured behind)
        else do
          ahead <- Sys.exec Binaries.git [ "rev-list", "--count", upstreamName <> "..HEAD" ]
          if ahead.code /= 0 then pure (Outcome.captured ahead)
          else case { behind: fromString (trim behind.stdout), ahead: fromString (trim ahead.stdout) } of
            { behind: Just behindCount, ahead: Just aheadCount } ->
              if behindCount > 0 && aheadCount == 0 then
                capturedCommand Binaries.git [ "pull", "--ff-only" ] context
              else pure Outcome.success
            _ -> pure (failureLines
              [ "vcs-op: unable to parse git rev-list counts"
              , "        HEAD.." <> upstreamName <> ": " <> trim behind.stdout
              , "        " <> upstreamName <> "..HEAD: " <> trim ahead.stdout
              ])

noUpstream :: Sys.ExecResult -> Boolean
noUpstream result =
  let message = trim result.stderr
  in trim result.stdout == ""
    && (contains (Pattern "no upstream") message
      || contains (Pattern "does not point to a branch") message)

-- | The sync invocations that resolve a base. One owner: both missing-base
-- | diagnostics render their remediation from these forms.
baseSyncForms :: { explicit :: String, stack :: String, default :: String }
baseSyncForms =
  { explicit: "agency_driver({ op: \"sync\", noVcs: false, base: \"<target>\" })"
  , stack: "agency_driver({ op: \"sync\", noVcs: false, stack: true })"
  , default: "agency_driver({ op: \"sync\", noVcs: false })"
  }

-- | Read the persisted base from the context resolved by the adapter.
resolveBase :: WorkflowContext -> Effect Outcome.OpOutcome
resolveBase context = case context.base of
  Just value -> pure (Outcome.withStdout (value <> "\n"))
  Nothing -> do
    stateResult <- State.readState (statePath context)
    pure case stateResult of
      Left error -> failureLines
        [ "vcs-op: base is not set and workflow state could not be read: " <> error
        , "        Resolve the reported state-read error before choosing a run or base."
        ]
      Right Nothing -> failureLines
        [ "vcs-op: base is not set and there is no initialized workflow run."
        , "        Choose noVcs=true with agency_driver({ op: \"init\", noVcs: true }) or noVcs=false with agency_driver({ op: \"init\", noVcs: false }), then sync."
        , "        No base or selector can be inferred here."
        ]
      Right (Just state)
        | state.status /= State.WorkflowRunning -> failureLines
            [ "vcs-op: base is not set and this workflow run is not running."
            , "        Choose or resume a run before syncing; no base or run is inferred or written by vcs-op."
            ]
        | otherwise -> case State.stateGetJson "noVcs" state >>= Json.toBoolean of
            Just true -> failureLines
              [ "vcs-op: base is not set; this run selected noVcs=true."
              , "        Complete or retry sync with agency_driver({ op: \"sync\", noVcs: true })."
              ]
            Just false -> failureLines
              [ "vcs-op: base is not set; this run selected noVcs=false."
              , "        Sync did not persist a base. The intended selector (--base, --stack, or default) is not recorded, so choose it rather than assuming the default."
              , "        Explicit base: " <> baseSyncForms.explicit
              , "        Stack: " <> baseSyncForms.stack
              , "        Default: " <> baseSyncForms.default
              ]
            Nothing -> failureLines
              [ "vcs-op: base is not set and this run has no valid noVcs choice."
              , "        Choose noVcs=true or false and the intended base selector before syncing; repair the missing or invalid persisted choice."
              ]

-- | Forge and VCS mutations consume one remote-selection policy: origin when
-- | present, otherwise exactly one configured remote. Multiple non-origin
-- | remotes are ambiguous and never selected by position.
remoteUrlValue :: WorkflowContext -> Effect (Either String String)
remoteUrlValue context = do
  result <- remoteUrlResult context
  pure if result.code == 0 then Right result.value else Left (if result.stderr == "" then "vcs-op: unable to read remote URL" else trim result.stderr)

remoteUrlResult :: WorkflowContext -> Effect VcsValue
remoteUrlResult context = do
  entries <- remoteEntries context
  pure case entries of
    Left error -> failureValue error
    Right remotes -> case selectRemote remotes of
      Left error -> failureValue error
      Right remote -> { code: 0, value: remote.url, stdout: remote.url <> "\n", stderr: "" }

-- | Query the current revision while retaining a failed subprocess status.
-- | Under jj the bookmark on @ is the head; with no bookmark there, the
-- | bookmark on @- (the just-described feature change) is the feature
-- | branch, matching currentBranchValue's --stack semantics.
headRevisionValue :: WorkflowContext -> Effect VcsValue
headRevisionValue context = case context.vcs of
  Git -> do
    result <- Sys.exec Binaries.git [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (valueResult result (trim result.stdout))
  Jj -> jjBranchValue
  Unknown -> pure { code: 1, value: "", stdout: "", stderr: "vcs-op: no VCS detected\n" }

-- | Resolve a real default ref; never manufacture a conventional name.
defaultBranchValue :: WorkflowContext -> Effect VcsValue
defaultBranchValue context = case context.vcs of
  Git -> do
    remote <- remoteName context
    case remote of
      Right name -> do
        result <- Sys.exec Binaries.git [ "symbolic-ref", "--short", "refs/remotes/" <> name <> "/HEAD" ]
        let candidate = stripRemote name (firstLine result.stdout)
        if result.code /= 0 || candidate == "" then remoteGitDefault name
        else do
          exists <- gitRefExists ("refs/remotes/" <> name <> "/" <> candidate)
          case exists of
            Left error -> pure (failureValue error)
            Right true -> pure (valueResult result candidate)
            Right false -> remoteGitDefault name
      Left _ -> localGitDefault
  Jj -> do
    remote <- remoteName context
    case remote of
      Left _ -> localJjDefault
      Right name -> do
        result <- Sys.exec Binaries.jj [ "bookmark", "list", "--remote", name, "--template", "name ++ \"\\n\"" ]
        if result.code /= 0 then localJjDefault
        else case firstKnownDefault (lines result.stdout) of
          Just value -> pure (valueResult result value)
          Nothing -> localJjDefault
  Unknown -> pure (failureValue "vcs-op: unable to resolve default branch (no VCS detected)")

-- | Query the branch used by sync's --stack policy, preserving failures.
currentBranchValue :: WorkflowContext -> Effect VcsValue
currentBranchValue context = case context.vcs of
  Git -> do
    result <- Sys.exec Binaries.git [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (valueResult result (trim result.stdout))
  Jj -> jjBranchValue
  -- Unknown is a valid empty query result for --stack: there is no branch
  -- to stack onto, and the caller emits its existing guidance.
  Unknown -> pure { code: 0, value: "", stdout: "", stderr: "" }

-- | The jj feature-bookmark rule, owned once: the bookmark on @, else the
-- | bookmark on @- (which may be the base branch). Nothing means neither
-- | revision carries a bookmark — callers decide what that implies for
-- | their contract (branch reads report empty; commit refuses; head-commit
-- | -sha falls back to the parent commit; push refuses a broad push).
jjFeatureBookmark :: Effect (Either Outcome.OpOutcome (Maybe String))
jjFeatureBookmark = do
  at <- bookmarkAt "@"
  case at of
    Right (Just _) -> pure at
    Right Nothing -> bookmarkAt "@-"
    Left outcome -> pure (Left outcome)

jjBranchValue :: Effect VcsValue
jjBranchValue = do
  found <- jjFeatureBookmark
  case found of
    Left outcome -> pure (outcomeValue outcome)
    Right Nothing -> pure { code: 0, value: "", stdout: "", stderr: "" }
    Right (Just name) -> pure { code: 0, value: name, stdout: name <> "\n", stderr: "" }

-- | Degraded VcsValue from a failed jj bookmark inspection: keeps the
-- | process status and the underlying stderr so the caller can diagnose it.
outcomeValue :: Outcome.OpOutcome -> VcsValue
outcomeValue outcome = case outcome.output of
  Outcome.Captured o -> { code: outcome.exit, value: "", stdout: o.stdout, stderr: o.stderr }
  Outcome.Passthrough -> { code: outcome.exit, value: "", stdout: "", stderr: "vcs-op: unable to inspect jj bookmarks\n" }

-- | Compare the current revision to a resolved default semantically rather
-- | than treating differently named local aliases as feature branches.
currentAtDefault :: WorkflowContext -> String -> Effect (Either String Boolean)
currentAtDefault context base = case context.vcs of
  Git -> do
    defaultRef <- gitReadBase context base
    case defaultRef of
      Left error -> pure (Left error)
      Right ref -> sameGitRevision "HEAD" ref
  Jj -> do
    defaultRef <- jjResolveBase context base
    case defaultRef of
      Left error -> pure (Left error)
      Right ref -> sameJjRevision "@" ref "vcs-op: unable to compare current branch with default"
  Unknown -> pure (Left "vcs-op: no VCS detected")

-- | Validate persisted and explicit base names against actual refs.
validateBase :: WorkflowContext -> String -> Effect (Either String Unit)
validateBase context base
  | base == "" = pure (Left "base must not be empty")
  | otherwise = case context.vcs of
      Git -> map (map (\_ -> unit)) (gitReadBase context base)
      Jj -> map (map (\_ -> unit)) (jjResolveBase context base)
      Unknown -> pure (Left "vcs-op: no VCS detected")

-- | Inspect the working copy without conflating a clean tree with a failed
-- | inspection. The sync operation propagates InspectionFailed unchanged.
inspectDirty :: WorkflowContext -> Effect DirtyState
inspectDirty context = case context.vcs of
  Unknown -> pure NoVcsDetected
  _ -> do
    result <- workingCopyResult context
    pure if result.code /= 0 then InspectionFailed (Outcome.captured result)
    else if trim result.stdout /= "" then DirtyDetected else Clean

-- | Share the inspection and listing query, retaining subprocess diagnostics.
workingCopyResult :: WorkflowContext -> Effect Sys.ExecResult
workingCopyResult context = do
  result <- case context.vcs of
    Git -> Sys.exec Binaries.git [ "status", "--porcelain", "--untracked-files=all" ]
    Jj -> Sys.exec Binaries.jj [ "diff", "--revisions", "@", "--summary" ]
    Unknown -> pure { code: 1, stdout: "", stderr: "vcs-op: no VCS detected\n" }
  pure if result.code /= 0 && trim result.stderr == "" then
    result { stderr = "vcs-op: unable to inspect " <> vcsName context.vcs <> " working copy\n" }
  else result

dirty :: WorkflowContext -> Effect Outcome.OpOutcome
dirty context = do
  state <- inspectDirty context
  pure case state of
    Clean -> Outcome.withStdout "clean\n"
    DirtyDetected -> Outcome.withStdout "dirty\n"
    NoVcsDetected -> Outcome.withStdout "no-vcs\n"
    InspectionFailed outcome -> outcome

diffRange :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
diffRange context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> withGitReadBase context value \base ->
      passthroughCommand context Binaries.git ([ "diff", base <> "...HEAD", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom context value
      case source of
        Left outcome -> pure outcome
        -- --git emits a standard unified diff; jj's default format is not
        -- consumable by the unified-diff readers downstream (reviewers,
        -- code-police passes). The git branch already emits unified diffs.
        Right from -> passthroughCommand context Binaries.jj ([ "diff", "--git", "--from", from, "--to", "@", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

diffNames :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
diffNames context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> withGitReadBase context value \base ->
      passthroughCommand context Binaries.git ([ "diff", base <> "...HEAD", "--name-only", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom context value
      case source of
        Left outcome -> pure outcome
        Right from -> passthroughCommand context Binaries.jj ([ "diff", "--from", from, "--to", "@", "--name-only", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

diffStat :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
diffStat context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> withGitReadBase context value \base ->
      passthroughCommand context Binaries.git ([ "diff", base <> "...HEAD", "--shortstat", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom context value
      case source of
        Left outcome -> pure outcome
        -- --stat emits a histogram with a trailing total, matching the
        -- shortstat shape the git branch produces behind the same op.
        Right from -> passthroughCommand context Binaries.jj ([ "diff", "--stat", "--from", from, "--to", "@", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

newFiles :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
newFiles context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> withGitReadBase context value \base ->
      passthroughCommand context Binaries.git ([ "diff", "--diff-filter=A", "--name-only", base <> "...HEAD", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom context value
      case source of
        Left outcome -> pure outcome
        Right from -> do
          result <- Sys.exec Binaries.jj ([ "diff", "--from", from, "--to", "@", "--summary", "--" ] <> paths)
          if result.code /= 0 then pure (Outcome.captured result)
          else
            let added = Array.mapMaybe addedName (split (Pattern "\n") result.stdout)
            in pure (Outcome.withStdout (if Array.null added then "" else joinWith "\n" added <> "\n"))
    Unknown -> pure noVcsOutcome
  where
  addedName line =
    let tokens = Array.filter (_ /= "") (split (Pattern " " ) (trim line))
    in if Array.head tokens == Just "A" then Array.index tokens 1 else Nothing

logRange :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
logRange context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> withGitReadBase context value \base ->
      passthroughCommand context Binaries.git ([ "log", base <> "..HEAD", "--oneline", "--" ] <> paths)
    Jj -> do
      source <- jjResolveBase context value
      case source of
        Left error -> pure (failureLine error)
        Right base -> do
          probe <- Sys.exec Binaries.jj [ "diff", "--revisions", "@", "--summary" ]
          if probe.code /= 0 then pure (failureLine "vcs-op: unable to inspect jj working copy for log-range")
          else do
            let target = if trim probe.stdout /= "" then "@" else "@-"
            passthroughCommand context Binaries.jj ([ "log", "--revision", base <> ".." <> target, "--no-graph", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

-- | The commit CI will run against, post-commit: the feature bookmark's
-- | commit — the bookmark on @, else the bookmark on @- (the just-described
-- | change), per jjFeatureBookmark. With no feature bookmark at either
-- | revision, the fallback is @-'s commit. Fails loudly when no real
-- | revision is resolvable: jj's null root commit (all zeros) is not an
-- | identity, so a fresh repository has no CI target.
headCommitShaJj :: WorkflowContext -> Effect Outcome.OpOutcome
headCommitShaJj context = do
  found <- jjFeatureBookmark
  case found of
    Left outcome -> pure outcome
    Right (Just name) -> capturedCommand Binaries.jj [ "log", "--revision", name, "--no-graph", "--template", "commit_id ++ \"\\n\"" ] context
    Right Nothing -> do
      parent <- jjCommitId "@-"
      case parent of
        Just sha -> pure (Outcome.withStdout (sha <> "\n"))
        Nothing -> pure (failureLine "vcs-op: no resolvable CI-target revision (fresh repository with only the null root commit)")

-- | commit_id of a revision, Nothing when the query fails, resolves to
-- | several commits, or the revision is jj's null root commit (all zeros),
-- | which names no real change.
jjCommitId :: String -> Effect (Maybe String)
jjCommitId revision = do
  result <- jjCommitIds revision
  pure case result of
    Right [ sha ] -> nullShaGuard sha
    _ -> Nothing

nullShaGuard :: String -> Maybe String
nullShaGuard sha = if isNullSha sha then Nothing else Just sha

isNullSha :: String -> Boolean
isNullSha sha = length sha == 40 && replaceAll (Pattern "0") (Replacement "") sha == ""

logHead :: WorkflowContext -> Effect Outcome.OpOutcome
logHead context = case context.vcs of
  Git -> passthroughCommand context Binaries.git [ "log", "--max-count=1", "--oneline" ]
  Jj -> passthroughCommand context Binaries.jj [ "log", "--revision", "@-", "--no-graph", "--limit", "1", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"" ]
  Unknown -> pure noVcsOutcome

-- | The merge-base pin every range op diffs from: always a commit ID, so the
-- | later `jj diff --from` stays unambiguous even when the merge-base change
-- | is divergent (a change-ID revset errors then).
jjRangeFrom :: WorkflowContext -> String -> Effect (Either Outcome.OpOutcome String)
jjRangeFrom context base = do
  resolved <- jjResolveBase context base
  case resolved of
    Left error -> pure (Left (failureLine error))
    Right ref -> do
      let revset = "heads(ancestors(@) & ancestors(" <> ref <> "))"
      result <- jjCommitIds revset
      pure case result of
        Left failure -> Left (failureLine (commandError ("vcs-op: unable to resolve merge-base for base '" <> base <> "'") failure))
        Right [] -> Right ref
        Right [ sha ] -> Right sha
        Right shas -> Left (failureLines
          [ "vcs-op: merge-base for base '" <> base <> "' is ambiguous (heads: " <> joinWith ", " shas <> ")"
          , "        Several merge bases exist (criss-cross history); diffing would pick one silently. Reconcile the history — for example `jj rebase` — so the range has a single merge base first."
          ])

branch :: WorkflowContext -> String -> Effect Outcome.OpOutcome
branch context name = case validateBranchName name of
  Left error -> pure (failureLine error)
  Right _ -> case context.base of
    Nothing -> resolveBase context
    Just value -> case context.vcs of
      Git -> do
        base <- gitReadBase context value
        case base of
          Left error -> pure (failureLine error)
          Right ref -> passthroughCommand context Binaries.git [ "checkout", "-b", name, ref ]
      Jj -> preserveState context do
        parent <- jjResolveBase context value
        case parent of
          Left error -> pure (failureLine error)
          Right ref -> do
            let createBookmark = passthroughCommand context Binaries.jj [ "bookmark", "create", name, "--revision", "@" ]
            pickedUp <- jjPickedUpWork
            case pickedUp of
              Left error -> pure (failureLine error)
              Right false -> do
                first <- passthroughCommand context Binaries.jj [ "new", ref ]
                if first.exit == 0 then createBookmark else pure first
              Right true -> do
                -- Picked-up work already lives in @: the fresh branch must sit on
                -- top of these changes (matching the git arm's checkout -b), so the
                -- bookmark attaches to the change carrying them instead of
                -- `jj new` stranding them behind an empty bookmarked change.
                atBase <- sameJjRevision "@" ref ("vcs-op branch: unable to compare the working copy with base '" <> ref <> "'")
                case atBase of
                  Left error -> pure (failureLine error)
                  Right true -> pure (failureLine ("vcs-op branch: the picked-up working copy changes sit on the base revision '" <> ref <> "'; refusing to strand them or retarget the trunk"))
                  Right false -> do
                    -- The deleted `jj new ref` anchored every branch at the
                    -- base; attaching to picked-up work must keep that
                    -- parentage guarantee or refuse.
                    stacked <- sameJjRevision "@-" ref ("vcs-op branch: unable to compare the picked-up working copy's parent with base '" <> ref <> "'")
                    case stacked of
                      Left error -> pure (failureLine error)
                      Right false -> pure (failureLine ("vcs-op branch: the picked-up working copy changes are not stacked on the base revision '" <> ref <> "'; refusing to attach the feature bookmark off-base"))
                      Right true -> createBookmark
      Unknown -> pure noVcsOutcome

commit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
commit context message files =
  if Array.null files then pure (failureLine "vcs-op: at least one file required (got none — pass the files you changed)")
  else do
    valid <- validateDirty context.vcs files
    case valid of
      Left error -> pure (Outcome.failure 1 (error <> "\n"))
      Right _ -> case context.vcs of
        Git -> stageThenCommit context message files
        Jj -> preserveState context (jjCommit context message files)
        Unknown -> pure noVcsOutcome

stageThenCommit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
stageThenCommit context message files = do
  staged <- passthroughCommand context Binaries.git ([ "add", "--" ] <> files)
  if staged.exit /= 0 then pure staged
  else passthroughCommand context Binaries.git ([ "commit", "--only", "--message", message, "--" ] <> files)

validateDirty :: VcsKind -> Array String -> Effect (Either String Unit)
validateDirty vcs files = do
  bad <- Array.filterA (\file -> do
    result <- case vcs of
      Git -> Sys.exec Binaries.git [ "status", "--porcelain", "--", file ]
      Jj -> Sys.exec Binaries.jj [ "diff", "--name-only", "--", file ]
      Unknown -> pure { code: 1, stdout: "", stderr: "" }
    pure (result.code /= 0 || trim result.stdout == "")) files
  if Array.null bad then pure (Right unit)
  else pure (Left (joinLines
    [ "vcs-op: file(s) not dirty (not in working-copy changes): " <> joinWithSpace bad
    , "        The caller must pass files it actually changed."
    ]))

jjCommit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
jjCommit context message files = do
  feature <- featureBookmark context
  case feature of
    Left outcome -> pure outcome
    Right bookmark -> do
      allResult <- Sys.exec Binaries.jj [ "diff", "--name-only" ]
      if allResult.code /= 0 then pure (Outcome.captured allResult)
      else do
        canonicalResults <- traverse canonicalFiles files
        case traverse identity canonicalResults of
          Left outcome -> pure outcome
          Right canonicalGroups ->
            let canonical = Array.concat canonicalGroups
                allChanged = lines allResult.stdout
                unrelated = Array.filter (\changed -> not (Array.any (\file -> file == changed) canonical)) allChanged
            in if Array.null unrelated then describeAndMove context bookmark message
            else splitAndMove context bookmark message unrelated
  where
  canonicalFiles file = do
    result <- Sys.exec Binaries.jj [ "diff", "--name-only", "--", file ]
    pure if result.code /= 0 then Left (Outcome.captured result) else Right (lines result.stdout)

-- | A jj commit only advances the feature bookmark created by `branch`.
-- | Refusing an absent/trunk bookmark avoids ever retargeting the base.
-- | A prior jj push can make the empty child immutable, leaving the feature
-- | bookmark on its parent. Either revision is safe unless it is the base.
featureBookmark :: WorkflowContext -> Effect (Either Outcome.OpOutcome String)
featureBookmark context = case context.base of
  Nothing -> pure (Left (failureLines
    [ "vcs-op commit: jj requires a resolved base to protect the trunk bookmark; workflow state resolved no base."
    , "        A prior value that does not name a ref (empty, non-string, or the no-vcs sentinel) is dropped at init — set the base to the branch's PR target."
    , "        Explicit base: agency_driver({ op: \"set\", field: \"base\", value: \"<target>\" })"
    , "        Or resolve it via sync: " <> baseSyncForms.explicit <> ", " <> baseSyncForms.stack <> ", or " <> baseSyncForms.default <> " for the default."
    ]))
  Just base -> do
    found <- jjFeatureBookmark
    pure (protect base found)
  where
  protect base found = case found of
    Left outcome -> Left outcome
    Right Nothing -> Left (failureLine "vcs-op commit: no feature bookmark at the working copy or its parent; refusing to move the trunk")
    Right (Just name) | name == base -> Left (failureLine ("vcs-op commit: refusing to move trunk bookmark '" <> name <> "'"))
    Right (Just name) -> Right name

describeAndMove :: WorkflowContext -> String -> String -> Effect Outcome.OpOutcome
describeAndMove context bookmark message = do
  described <- passthroughCommand context Binaries.jj [ "describe", "--message=" <> message ]
  if described.exit /= 0 then pure described
  else do
    newCode <- passthroughCommand context Binaries.jj [ "new" ]
    if newCode.exit /= 0 then pure newCode
    else moveBookmark context bookmark "@-"

splitAndMove :: WorkflowContext -> String -> String -> Array String -> Effect Outcome.OpOutcome
splitAndMove context bookmark message unrelated = do
  described <- passthroughCommand context Binaries.jj [ "describe", "--message=" <> message ]
  if described.exit /= 0 then pure described
  else do
    splitCode <- passthroughCommand context Binaries.jj ([ "split", "--message=chore: unrelated changes", "--" ] <> map jjSplitPath unrelated)
    if splitCode.exit /= 0 then pure splitCode
    else do
      rebase <- passthroughCommand context Binaries.jj [ "rebase", "--revision", "@-", "--insert-after", "@" ]
      if rebase.exit /= 0 then pure rebase
      else do
        moved <- moveBookmark context bookmark "@"
        if moved.exit /= 0 then pure moved
        else passthroughCommand context Binaries.jj [ "edit", "@+" ]

moveBookmark :: WorkflowContext -> String -> String -> Effect Outcome.OpOutcome
moveBookmark context name target =
  passthroughCommand context Binaries.jj [ "bookmark", "move", name, "--to", target ]

bookmarkAt :: String -> Effect (Either Outcome.OpOutcome (Maybe String))
bookmarkAt revision = do
  result <- Sys.exec Binaries.jj [ "bookmark", "list", "--revision", revision, "--template", "name ++ \"\\n\"" ]
  if result.code /= 0 then
    pure (Left (if result.stderr == "" then failureLine ("vcs-op: unable to inspect bookmark at '" <> revision <> "'") else Outcome.captured result))
  else pure (Right (Args.nonEmpty (firstLine result.stdout)))

push :: WorkflowContext -> Maybe String -> Effect Outcome.OpOutcome
push context ref = case context.vcs of
  Git -> case ref of
    Just value -> withRemote context \remote ->
      passthroughCommand context Binaries.git [ "push", "--set-upstream", remote, "--", value ]
    Nothing -> passthroughCommand context Binaries.git [ "push" ]
  Jj -> do
    bookmark <- case ref of
      Just value | context.base == Just value -> pure (Left ("vcs-op: bookmark '" <> value <> "' is the base; refusing jj trunk push"))
      Just value -> pure (Right value)
      Nothing -> currentFeatureBookmark context
    case bookmark of
      Left error -> pure (failureLine error)
      Right value -> withRemote context \remote ->
        passthroughCommand context Binaries.jj [ "git", "push", "--remote", remote, "--bookmark", value ]
  Unknown -> pure noVcsOutcome

fixCommit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
fixCommit context message files = do
  committed <- commit context message files
  if committed.exit /= 0 then pure committed else push context Nothing

valueResult :: Sys.ExecResult -> String -> VcsValue
valueResult result value =
  { code: result.code
  , value
  , stdout: result.stdout
  , stderr: result.stderr
  }

renderValue :: VcsValue -> Outcome.OpOutcome
renderValue result =
  let stdout =
        if result.code == 0 then
          if result.value == "" then "" else result.value <> "\n"
        else result.stdout
  in
    { exit: result.code
    , output: Outcome.Captured
        { stdout
        , stderr: result.stderr
        , stderrFirst: false
        }
    }

capturedCommand :: String -> Array String -> WorkflowContext -> Effect Outcome.OpOutcome
capturedCommand command args _ = Outcome.captured <$> Sys.exec command args

passthroughCommand :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
passthroughCommand context command args =
  if context.captureOutput then
    Outcome.captured <$> Sys.exec command args
  else do
    result <- Sys.execInherit command args
    case result.error of
      Just error -> pure (Outcome.failure 1 ("vcs-op: " <> command <> " failed to spawn: " <> error <> "\n"))
      Nothing -> pure (Outcome.passthrough result.code)

type Remote =
  { name :: String
  , url :: String
  }

withRemote :: WorkflowContext -> (String -> Effect Outcome.OpOutcome) -> Effect Outcome.OpOutcome
withRemote context action = do
  selected <- remoteName context
  case selected of
    Left error -> pure (failureLine error)
    Right remote -> action remote

remoteName :: WorkflowContext -> Effect (Either String String)
remoteName context = do
  entries <- remoteEntries context
  pure case entries of
    Left error -> Left error
    Right remotes -> map _.name (selectRemote remotes)

remoteEntries :: WorkflowContext -> Effect (Either String (Array Remote))
remoteEntries context = case context.vcs of
  Git -> do
    listed <- Sys.exec Binaries.git [ "remote" ]
    if listed.code /= 0 then pure (Left (commandError "vcs-op: unable to list git remotes" listed))
    else do
      results <- traverse gitRemote (lines listed.stdout)
      pure (traverse identity results)
  Jj -> do
    listed <- Sys.exec Binaries.jj [ "git", "remote", "list" ]
    pure if listed.code /= 0 then Left (commandError "vcs-op: unable to list jj remotes" listed)
    else Right (Array.mapMaybe parseJjRemote (lines listed.stdout))
  Unknown -> pure (Left "vcs-op: no VCS detected")
  where
  gitRemote name = do
    url <- Sys.exec Binaries.git [ "remote", "get-url", name ]
    pure if url.code == 0 && trim url.stdout /= "" then Right { name, url: trim url.stdout }
    else Left (commandError ("vcs-op: unable to read remote '" <> name <> "'") url)

selectRemote :: Array Remote -> Either String Remote
selectRemote remotes = case Array.find (\remote -> remote.name == "origin") remotes of
  Just origin -> Right origin
  Nothing -> case remotes of
    [ remote ] -> Right remote
    [] -> Left "vcs-op: no remote configured"
    _ -> Left "vcs-op: multiple remotes configured but none is named origin"

parseJjRemote :: String -> Maybe Remote
parseJjRemote line = case Array.uncons (Array.filter (_ /= "") (split (Pattern " ") (trim line))) of
  Nothing -> Nothing
  Just { head: name, tail } -> case Array.head tail of
    Nothing -> Nothing
    Just url -> Just { name, url }

remoteGitDefault :: String -> Effect VcsValue
remoteGitDefault remote = do
  main <- gitRefExists ("refs/remotes/" <> remote <> "/main")
  case main of
    Left error -> pure (failureValue error)
    Right true -> pure { code: 0, value: "main", stdout: "main\n", stderr: "" }
    Right false -> do
      master <- gitRefExists ("refs/remotes/" <> remote <> "/master")
      case master of
        Left error -> pure (failureValue error)
        Right true -> pure { code: 0, value: "master", stdout: "master\n", stderr: "" }
        Right false -> localGitDefault

localGitDefault :: Effect VcsValue
localGitDefault = do
  main <- gitLocalRef "main"
  case main of
    Left error -> pure (failureValue error)
    Right true -> pure { code: 0, value: "main", stdout: "main\n", stderr: "" }
    Right false -> do
      master <- gitLocalRef "master"
      pure case master of
        Left error -> failureValue error
        Right true -> { code: 0, value: "master", stdout: "master\n", stderr: "" }
        Right false -> failureValue "vcs-op: unable to resolve default branch (no remote HEAD and no verified local main/master) — pass --base <branch> explicitly"

localJjDefault :: Effect VcsValue
localJjDefault = do
  main <- jjBookmarkCommit "main" Nothing
  case main of
    Left error -> pure (failureValue error)
    Right (Just _) -> pure { code: 0, value: "main", stdout: "main\n", stderr: "" }
    Right Nothing -> do
      master <- jjBookmarkCommit "master" Nothing
      pure case master of
        Left error -> failureValue error
        Right (Just _) -> { code: 0, value: "master", stdout: "master\n", stderr: "" }
        Right Nothing -> failureValue "vcs-op: unable to resolve default branch (no remote main/master bookmark and no verified local main/master) — pass --base <branch> explicitly"

firstKnownDefault :: Array String -> Maybe String
firstKnownDefault = Array.find (\name -> name == "main" || name == "master")

gitReadBase :: WorkflowContext -> String -> Effect (Either String String)
gitReadBase context base = do
  remote <- remoteName context
  case remote of
    Right name -> do
      exists <- gitRefExists ("refs/remotes/" <> name <> "/" <> base)
      case exists of
        Left error -> pure (Left error)
        Right true -> pure (Right (name <> "/" <> base))
        Right false -> gitLocalBase base
    Left _ -> gitLocalBase base

withGitReadBase :: WorkflowContext -> String -> (String -> Effect Outcome.OpOutcome) -> Effect Outcome.OpOutcome
withGitReadBase context base action = do
  resolved <- gitReadBase context base
  case resolved of
    Left error -> pure (failureLine error)
    Right ref -> action ref

gitLocalBase :: String -> Effect (Either String String)
gitLocalBase base = do
  exists <- gitRefExists ("refs/heads/" <> base)
  pure case exists of
    Left error -> Left error
    Right true -> Right base
    Right false -> Left ("vcs-op: base '" <> base <> "' does not name a local or selected-remote branch")

gitRefExists :: String -> Effect (Either String Boolean)
gitRefExists ref = do
  result <- Sys.exec Binaries.git [ "show-ref", "--verify", "--quiet", ref ]
  pure case result.code of
    0 -> Right true
    1 -> Right false
    _ -> Left (commandError ("vcs-op: unable to verify git ref '" <> ref <> "'") result)

gitLocalRef :: String -> Effect (Either String Boolean)
gitLocalRef name = gitRefExists ("refs/heads/" <> name)

-- | Resolve a base selector to the one commit its bookmark names. State keeps
-- | the bookmark name so `base` follows the advancing trunk, while jj argv
-- | receives the commit ID: a commit ID resolves even when its change is
-- | divergent, where a change-ID revset errors. A selector is a local bookmark
-- | name or a remote-qualified `name@remote`; unqualified names fall back to
-- | the selected remote.
jjResolveBase :: WorkflowContext -> String -> Effect (Either String String)
jjResolveBase context base = do
  local <- jjBookmarkCommit base Nothing
  case local of
    Left error -> pure (Left error)
    Right (Just sha) -> pure (Right sha)
    Right Nothing -> case splitRemoteRef base of
      Just { name, scope } -> remoteCommit name (Just scope)
      Nothing -> do
        remote <- remoteName context
        case remote of
          Left _ -> pure (Left (baseNotBookmark base))
          Right scope -> remoteCommit base (Just scope)
  where
  remoteCommit name scope = do
    found <- jjBookmarkCommit name scope
    pure case found of
      Left error -> Left error
      Right (Just sha) -> Right sha
      Right Nothing -> Left (baseNotBookmark base)

-- | `name@remote` addresses a remote-tracking bookmark in jj revsets, and jj
-- | refuses `@` in bookmark names — so a two-part `@` split is exactly that
-- | form and nothing else.
splitRemoteRef :: String -> Maybe { name :: String, scope :: String }
splitRemoteRef value = case split (Pattern "@") value of
  [ name, scope ] | name /= "" && scope /= "" -> Just { name, scope }
  _ -> Nothing

-- | The one "revset → commit IDs" query: one template contract (one commit ID
-- | per line), one parse. Callers classify the result; the raw result rides
-- | along on failure so a caller may render jj's stderr where its own contract
-- | allows — not every caller does.
-- | `head-commit-sha` deliberately stays outside this seam: its contract is
-- | byte-faithful passthrough of jj's stdout, with nothing to classify.
jjCommitIds :: String -> Effect (Either Sys.ExecResult (Array String))
jjCommitIds revset = do
  result <- Sys.exec Binaries.jj [ "log", "--revision", revset, "--no-graph", "--template", "commit_id ++ \"\\n\"" ]
  pure if result.code /= 0 then Left result else Right (lines result.stdout)

-- | The one commit a bookmark names, optionally scoped to a remote. Right
-- | Nothing when no bookmark matches; a conflicted bookmark names several
-- | commits, so nothing can be pinned and the error lists every target. The
-- | label and revset derive from the same name here so an actionable error can
-- | never cite a bookmark the probe did not query.
jjBookmarkCommit :: String -> Maybe String -> Effect (Either String (Maybe String))
jjBookmarkCommit name remote = do
  let label = case remote of
        Nothing -> name
        Just scope -> name <> "@" <> scope
      revset = case remote of
        Nothing -> "bookmarks(" <> exactPattern name <> ")"
        Just scope -> "remote_bookmarks(" <> exactPattern name <> ", remote=" <> exactPattern scope <> ")"
  result <- jjCommitIds revset
  pure case result of
    Left failure -> Left (commandError ("vcs-op: unable to resolve jj bookmark '" <> label <> "'") failure)
    Right [] -> Right Nothing
    Right [ sha ] -> Right (Just sha)
    Right shas -> Left (joinLines
      [ "vcs-op: jj bookmark '" <> label <> "' is conflicted (targets: " <> joinWith ", " shas <> ")"
      , case remote of
          Nothing -> "        Nothing can be pinned while it names several revisions; point it at one with `jj bookmark set " <> name <> " -r <commit-id>`."
          Just scope -> "        Nothing can be pinned while the remote bookmark '" <> name <> "' names several revisions on '" <> scope <> "'; resolve it there to a single target."
      ])

-- | An exact jj string pattern: a bookmark name is an opaque literal, never a
-- | glob (jj parses bare strings as glob patterns).
exactPattern :: String -> String
exactPattern value = "exact:" <> revsetString value

-- | The quoted literal body: backslash and quote are escaped so a name with
-- | either survives jj's string-literal parsing instead of breaking the
-- | pattern.
revsetString :: String -> String
revsetString value = "\"" <> replaceAll (Pattern "\\") (Replacement "\\\\") (replaceAll (Pattern "\"") (Replacement "\\\"") value) <> "\""

baseNotBookmark :: String -> String
baseNotBookmark base = "vcs-op: base '" <> base <> "' does not name a local or selected-remote bookmark"

sameGitRevision :: String -> String -> Effect (Either String Boolean)
sameGitRevision left right = do
  leftResult <- Sys.exec Binaries.git [ "rev-parse", left ]
  rightResult <- Sys.exec Binaries.git [ "rev-parse", right ]
  pure if leftResult.code /= 0 || rightResult.code /= 0 then Left "vcs-op: unable to compare current branch with default"
  else Right (trim leftResult.stdout == trim rightResult.stdout)

-- | Whether @ carries picked-up work: an undescribed change with content
-- beyond the workflow state file (owned by Context.stateFile, carried by
-- preserveState — not repo work). `jj new` would strand exactly such a change
-- behind an empty bookmarked one, so the feature branch must attach to it
-- instead. Described changes are commits — they stay where their author put
-- them.
jjPickedUpWork :: Effect (Either String Boolean)
jjPickedUpWork = do
  let inspectFallback = "vcs-op: unable to inspect jj working copy for branch"
  described <- Sys.exec Binaries.jj [ "log", "--revisions", "@", "--no-graph", "--template", "description" ]
  if described.code /= 0 then pure (Left (commandError inspectFallback described))
  else if trim described.stdout /= "" then pure (Right false)
  else do
    probe <- Sys.exec Binaries.jj [ "diff", "--revisions", "@", "--name-only" ]
    if probe.code /= 0 then pure (Left (commandError inspectFallback probe))
    else pure (Right (Array.any (\path -> path /= stateFile) (lines probe.stdout)))

-- | Whether a revision is the pinned commit. Only the left side is queried:
-- | the right side arrives already pinned by jjResolveBase, so resolving it
-- | again would be dead work with an unreachable failure branch.
sameJjRevision :: String -> String -> String -> Effect (Either String Boolean)
sameJjRevision left rightSha fallback = do
  result <- jjCommitIds left
  pure case result of
    Left _ -> Left fallback
    Right [ sha ] -> Right (sha == rightSha)
    Right _ -> Right false

currentFeatureBookmark :: WorkflowContext -> Effect (Either String String)
currentFeatureBookmark context = do
  current <- currentBranchValue context
  pure if current.code /= 0 then Left (commandError "vcs-op: unable to resolve current feature bookmark" { code: current.code, stdout: current.stdout, stderr: current.stderr })
  else if current.value == "" then Left "vcs-op: no feature bookmark is checked out; refusing broad jj push"
  else if context.base == Just current.value then Left ("vcs-op: current bookmark '" <> current.value <> "' is the base; refusing broad jj push")
  else Right current.value

validateBranchName :: String -> Either String Unit
validateBranchName name =
  if name == "" || Args.startsWith "-" name || Args.startsWith "." name || contains (Pattern "..") name || contains (Pattern "@{") name || Array.any (\invalid -> contains (Pattern invalid) name) [ " ", "~", "^", ":", "?", "*", "[", "\\", ";" ] then
    Left ("vcs-op branch: invalid branch name '" <> name <> "'")
  else Right unit

preserveState :: WorkflowContext -> Effect Outcome.OpOutcome -> Effect Outcome.OpOutcome
preserveState context action = do
  let path = statePath context
  present <- Sys.exists path
  saved <- if present then Just <$> Sys.readUtf8 path else pure Nothing
  outcome <- action
  case saved of
    Nothing -> pure unit
    Just contents -> Sys.writeUtf8 path contents
  pure outcome

failureValue :: String -> VcsValue
failureValue message = { code: 1, value: "", stdout: "", stderr: message <> "\n" }

commandError :: String -> Sys.ExecResult -> String
commandError fallback result = if trim result.stderr == "" then fallback else trim result.stderr

lines :: String -> Array String
lines value = Array.filter (_ /= "") (map trim (split (Pattern "\n") value))
joinWithSpace :: Array String -> String
joinWithSpace values = joinWith " " values
-- | jj split requires a `./` prefix for a dash-leading path, even after `--`.
jjSplitPath :: String -> String
jjSplitPath path = if Args.startsWith "-" path then "./" <> path else path

noVcsOutcome :: Outcome.OpOutcome
noVcsOutcome = failureLine "vcs-op: no VCS detected"

failureLine :: String -> Outcome.OpOutcome
failureLine value = Outcome.failure 1 (value <> "\n")

failureLines :: Array String -> Outcome.OpOutcome
failureLines values = Outcome.failure 1 (joinLines values <> "\n")

joinLines :: Array String -> String
joinLines = joinWith "\n"


firstLine :: String -> String
firstLine output = fromMaybe "" (trim <$> Array.head (split (Pattern "\n") output))

stripRemote :: String -> String -> String
stripRemote remote value =
  if Args.startsWith (remote <> "/") value then drop (length remote + 1) value else value
