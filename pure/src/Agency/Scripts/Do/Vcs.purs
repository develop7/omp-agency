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
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.VcsKind (VcsKind(..))
import Agency.Scripts.Do.VcsKind (VcsKind(..)) as VcsKinds
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (fromString)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), contains, joinWith, split, trim)
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

-- | Result of working-copy inspection. Clean is distinct from an inspection
-- | failure so sync cannot mistake a broken VCS query for a clean tree.
data DirtyState
  = Clean
  | DirtyDetected
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
    Jj -> capturedCommand Binaries.jj [ "log", "--revision", "@", "--no-graph", "--template", "commit_id" ] context
    Unknown -> pure noVcsOutcome
  DefaultBranch -> renderValue <$> defaultBranchValue context
  CurrentBranch -> renderValue <$> currentBranchValue context
  Base -> resolveBase context
  Dirty -> dirty context
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
    capturedCommand Binaries.jj [ "git", "fetch", remote ] context

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

-- | Read the persisted base from the context resolved by the adapter.
resolveBase :: WorkflowContext -> Effect Outcome.OpOutcome
resolveBase context = case context.base of
  Just value -> pure (Outcome.withStdout (value <> "\n"))
  Nothing -> pure (failureLines
    [ "vcs-op: base is not set. sync must run first to resolve the base"
    , "        (from --base <branch>, --stack, or the default branch)."
    , "        If this was a --from re-run, the parent run did not persist base."
    ])

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
headRevisionValue :: WorkflowContext -> Effect VcsValue
headRevisionValue context = case context.vcs of
  Git -> do
    result <- Sys.exec Binaries.git [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (valueResult result (trim result.stdout))
  Jj -> do
    bookmark <- Sys.exec Binaries.jj [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    pure (valueResult bookmark (if bookmark.code == 0 then firstLine bookmark.stdout else ""))
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
  Jj -> do
    at <- Sys.exec Binaries.jj [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    let atName = firstLine at.stdout
    if at.code /= 0 then pure (valueResult at "")
    else if atName /= "" then pure (valueResult at atName)
    else do
      parent <- Sys.exec Binaries.jj [ "bookmark", "list", "--revision", "@-", "--template", "name ++ \"\\n\"" ]
      pure (valueResult parent (firstLine parent.stdout))
  -- Unknown is a valid empty query result for --stack: there is no branch
  -- to stack onto, and the caller emits its existing guidance.
  Unknown -> pure { code: 0, value: "", stdout: "", stderr: "" }

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
    defaultRef <- jjBaseRevset context base
    case defaultRef of
      Left error -> pure (Left error)
      Right ref -> sameJjRevision "@" ref
  Unknown -> pure (Left "vcs-op: no VCS detected")

-- | Validate persisted and explicit base names against actual refs.
validateBase :: WorkflowContext -> String -> Effect (Either String Unit)
validateBase context base
  | base == "" = pure (Left "base must not be empty")
  | otherwise = case context.vcs of
      Git -> map (map (\_ -> unit)) (gitReadBase context base)
      Jj -> map (map (\_ -> unit)) (jjBaseRevset context base)
      Unknown -> pure (Left "vcs-op: no VCS detected")

-- | Inspect the working copy without conflating a clean tree with a failed
-- | inspection. The sync operation propagates InspectionFailed unchanged.
inspectDirty :: WorkflowContext -> Effect DirtyState
inspectDirty context = case context.vcs of
  Git -> do
    result <- Sys.exec Binaries.git [ "status", "--porcelain" ]
    if result.code /= 0 then
      pure (InspectionFailed
        (if result.stderr == "" then failureLine "vcs-op: unable to inspect git working copy" else Outcome.captured result))
    else if trim result.stdout /= "" then pure DirtyDetected else pure Clean
  Jj -> do
    result <- Sys.exec Binaries.jj [ "diff", "--revisions", "@", "--summary" ]
    if result.code /= 0 then pure (InspectionFailed (failureLine "vcs-op: unable to inspect jj working copy"))
    else if trim result.stdout /= "" then pure DirtyDetected else pure Clean
  Unknown -> pure Clean

dirty :: WorkflowContext -> Effect Outcome.OpOutcome
dirty context = do
  state <- inspectDirty context
  pure case state of
    Clean -> Outcome.failure 1 ""
    DirtyDetected -> Outcome.success
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
        Right from -> passthroughCommand context Binaries.jj ([ "diff", "--from", from, "--to", "@", "--" ] <> paths)
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
        Right from -> passthroughCommand context Binaries.jj ([ "diff", "--from", from, "--to", "@", "--summary", "--" ] <> paths)
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
      source <- jjBaseRevset context value
      case source of
        Left error -> pure (failureLine error)
        Right base -> do
          probe <- Sys.exec Binaries.jj [ "diff", "--revisions", "@", "--summary" ]
          if probe.code /= 0 then pure (failureLine "vcs-op: unable to inspect jj working copy for log-range")
          else do
            let target = if trim probe.stdout /= "" then "@" else "@-"
            passthroughCommand context Binaries.jj ([ "log", "--revision", base <> ".." <> target, "--no-graph", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

logHead :: WorkflowContext -> Effect Outcome.OpOutcome
logHead context = case context.vcs of
  Git -> passthroughCommand context Binaries.git [ "log", "--max-count=1", "--oneline" ]
  Jj -> passthroughCommand context Binaries.jj [ "log", "--revision", "@-", "--no-graph", "--limit", "1", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"" ]
  Unknown -> pure noVcsOutcome

jjRangeFrom :: WorkflowContext -> String -> Effect (Either Outcome.OpOutcome String)
jjRangeFrom context base = do
  resolved <- jjBaseRevset context base
  case resolved of
    Left error -> pure (Left (failureLine error))
    Right ref -> do
      let revset = "heads(ancestors(@) & ancestors(" <> ref <> "))"
      result <- Sys.exec Binaries.jj [ "log", "--revision", revset, "--no-graph", "--template", "change_id" ]
      if result.code /= 0 then pure (Left (failureLine ("vcs-op: unable to resolve merge-base for base '" <> base <> "'")))
      else pure (Right (if trim result.stdout == "" then ref else trim result.stdout))

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
        parent <- jjBaseRevset context value
        case parent of
          Left error -> pure (failureLine error)
          Right ref -> do
            first <- passthroughCommand context Binaries.jj [ "new", ref ]
            if first.exit == 0 then passthroughCommand context Binaries.jj [ "bookmark", "create", name, "--revision", "@" ] else pure first
      Unknown -> pure noVcsOutcome

commit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
commit context message files =
  if Array.null files then pure (failureLine "vcs-op: at least one file required (got none — pass the files you changed)")
  else do
    valid <- validateDirty context.vcs files
    case valid of
      Left error -> pure (Outcome.failure 1 (error <> "\n"))
      Right _ -> case context.vcs of
        Git -> passthroughCommand context Binaries.git ([ "commit", "--only", "--message", message, "--" ] <> files)
        Jj -> preserveState context (jjCommit context message files)
        Unknown -> pure noVcsOutcome

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
featureBookmark :: WorkflowContext -> Effect (Either Outcome.OpOutcome String)
featureBookmark context = case context.base of
  Nothing -> pure (Left (failureLine "vcs-op commit: jj requires a resolved base to protect the trunk bookmark"))
  Just base -> do
    found <- bookmarkAt "@"
    pure case found of
      Left outcome -> Left outcome
      Right Nothing -> Left (failureLine "vcs-op commit: no feature bookmark at the working copy; refusing to move the trunk")
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
    splitCode <- passthroughCommand context Binaries.jj ([ "split", "--message=chore: unrelated changes", "--" ] <> unrelated)
    if splitCode.exit /= 0 then pure splitCode
    else do
      rebase <- passthroughCommand context Binaries.jj [ "rebase", "--revision", "@-", "--insert-after", "@" ]
      if rebase.exit /= 0 then pure rebase
      else do
        moved <- moveBookmark context bookmark "@"
        if moved.exit /= 0 then pure moved
        else passthroughCommand context Binaries.jj [ "new", bookmark ]

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
      passthroughCommand context Binaries.git [ "push", "--set-upstream", remote, value ]
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
  main <- jjRevisionExists "main"
  case main of
    Left error -> pure (failureValue error)
    Right true -> pure { code: 0, value: "main", stdout: "main\n", stderr: "" }
    Right false -> do
      master <- jjRevisionExists "master"
      pure case master of
        Left error -> failureValue error
        Right true -> { code: 0, value: "master", stdout: "master\n", stderr: "" }
        Right false -> failureValue "vcs-op: unable to resolve default branch (no remote main/master bookmark and no verified local main/master) — pass --base <branch> explicitly"

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

jjBaseRevset :: WorkflowContext -> String -> Effect (Either String String)
jjBaseRevset context base = do
  local <- jjRevisionExists base
  case local of
    Left error -> pure (Left error)
    Right true -> pure (Right base)
    Right false -> do
      remote <- remoteName context
      case remote of
        Left _ -> pure (Left ("vcs-op: base '" <> base <> "' does not name a local or selected-remote bookmark"))
        Right name -> do
          let remoteBase = base <> "@" <> name
          exists <- jjRevisionExists remoteBase
          pure case exists of
            Left error -> Left error
            Right true -> Right remoteBase
            Right false -> Left ("vcs-op: base '" <> base <> "' does not name a local or selected-remote bookmark")

jjRevisionExists :: String -> Effect (Either String Boolean)
jjRevisionExists revision = do
  result <- Sys.exec Binaries.jj [ "log", "--revision", revision, "--no-graph", "--template", "change_id" ]
  pure if result.code == 0 then Right (trim result.stdout /= "")
  else if contains (Pattern "Revision `") result.stderr && contains (Pattern "` doesn't exist") result.stderr then Right false
  else Left (commandError ("vcs-op: unable to resolve jj revision '" <> revision <> "'") result)

sameGitRevision :: String -> String -> Effect (Either String Boolean)
sameGitRevision left right = do
  leftResult <- Sys.exec Binaries.git [ "rev-parse", left ]
  rightResult <- Sys.exec Binaries.git [ "rev-parse", right ]
  pure if leftResult.code /= 0 || rightResult.code /= 0 then Left "vcs-op: unable to compare current branch with default"
  else Right (trim leftResult.stdout == trim rightResult.stdout)

sameJjRevision :: String -> String -> Effect (Either String Boolean)
sameJjRevision left right = do
  leftResult <- Sys.exec Binaries.jj [ "log", "--revision", left, "--no-graph", "--template", "commit_id" ]
  rightResult <- Sys.exec Binaries.jj [ "log", "--revision", right, "--no-graph", "--template", "commit_id" ]
  pure if leftResult.code /= 0 || rightResult.code /= 0 then Left "vcs-op: unable to compare current branch with default"
  else Right (trim leftResult.stdout == trim rightResult.stdout)

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
  let path = context.stateDir <> "/.do-results.json"
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
