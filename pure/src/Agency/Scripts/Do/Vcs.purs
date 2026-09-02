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
  , renderValue
  , inspectDirty
  , vcsName
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
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
import Data.String.CodeUnits (drop)
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
    Git -> capturedCommand "git" [ "rev-parse", "HEAD" ] context
    Jj -> capturedCommand "jj" [ "log", "--revision", "@-", "--no-graph", "--template", "commit_id" ] context
    Unknown -> pure noVcsOutcome
  DefaultBranch -> do
    value <- defaultBranchValue context
    pure (Outcome.withStdout (value <> "\n"))
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

-- | Fetch is shared by the CLI operation and sync. It captures output so sync
-- | can decide what (if anything) belongs in its own protocol.
fetchValue :: WorkflowContext -> Effect Outcome.OpOutcome
fetchValue context = case context.vcs of
  Git -> capturedCommand "git" [ "fetch", "origin" ] context
  Jj -> capturedCommand "jj" [ "git", "fetch" ] context
  Unknown -> pure (noVcsOutcome)

-- | Refresh the default remote branch using the same strategy as the CLI.
refreshDefaultBranchValue :: WorkflowContext -> Effect Outcome.OpOutcome
refreshDefaultBranchValue context = case context.vcs of
  Git -> capturedCommand "git" [ "remote", "set-head", "origin", "--auto" ] context
  Jj -> pure Outcome.success
  Unknown -> pure Outcome.success

fastForwardIfSafe :: WorkflowContext -> Effect Outcome.OpOutcome
fastForwardIfSafe context = case context.vcs of
  Jj -> pure Outcome.success
  Unknown -> pure Outcome.success
  Git -> do
    upstream <- Sys.exec "git" [ "rev-parse", "--abbrev-ref", "@{u}" ]
    if upstream.code /= 0 then
      if noUpstream upstream then pure Outcome.success else pure (Outcome.captured upstream)
    else do
      let upstreamName = trim upstream.stdout
      if upstreamName == "" then pure Outcome.success
      else do
        behind <- Sys.exec "git" [ "rev-list", "--count", "HEAD.." <> upstreamName ]
        ahead <- Sys.exec "git" [ "rev-list", "--count", upstreamName <> "..HEAD" ]
        let behindCount = fromMaybe 0 (fromString (trim behind.stdout))
            aheadCount = fromMaybe 0 (fromString (trim ahead.stdout))
        if behind.code == 0 && ahead.code == 0 && behindCount > 0 && aheadCount == 0 then
          capturedCommand "git" [ "pull", "--ff-only" ] context
        else pure Outcome.success

noUpstream :: Sys.ExecResult -> Boolean
noUpstream result =
  let message = trim result.stderr
  in trim result.stdout == ""
    && (message == ""
      || contains (Pattern "no upstream") message
      || contains (Pattern "does not point to a branch") message)

-- | Read the persisted base from the context resolved by the adapter.
resolveBase :: WorkflowContext -> Effect Outcome.OpOutcome
resolveBase context = case context.base of
  Just value -> pure (Outcome.withStdout (value <> "\n"))
  Nothing -> pure (failureLines
    [ "vcs-op: base is not set. sync must run first to resolve the base"
    , "        (from --base <branch>, --stack, or the default branch)."
    , "        If this was a --from re-run, the parent run did not persist base."
    , "        (Same error fires if jq is unavailable or .do-results.json is corrupt — check 'command -v jq'.)"
    ])

-- | Look up and normalize the origin URL once. Forge detection consumes this
-- | strategy instead of maintaining a second git/jj parser.
remoteUrlValue :: WorkflowContext -> Effect (Either String String)
remoteUrlValue context = do
  result <- remoteUrlResult context
  pure if result.code == 0 then Right result.value else Left (if result.stderr == "" then "vcs-op: unable to read remote URL" else trim result.stderr)

remoteUrlResult :: WorkflowContext -> Effect VcsValue
remoteUrlResult context = case context.vcs of
  Git -> do
    result <- Sys.exec "git" [ "remote", "get-url", "origin" ]
    pure (valueResult result (trim result.stdout))
  Jj -> do
    result <- Sys.exec "jj" [ "git", "remote", "list" ]
    if result.code /= 0 then pure (valueResult result "")
    else pure (valueResult result (jjRemote result.stdout))
  Unknown -> pure { code: 1, value: "", stdout: "", stderr: "vcs-op: no VCS detected\n" }

-- | Query the current revision while retaining a failed subprocess status.
headRevisionValue :: WorkflowContext -> Effect VcsValue
headRevisionValue context = case context.vcs of
  Git -> do
    result <- Sys.exec "git" [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (valueResult result (trim result.stdout))
  Jj -> do
    bookmark <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    let name = firstLine bookmark.stdout
    if bookmark.code /= 0 then pure (valueResult bookmark "")
    else if name /= "" then pure (valueResult bookmark name)
    else do
      fallback <- Sys.exec "jj" [ "log", "--revision", "@", "--no-graph", "--template", "change_id" ]
      pure (valueResult fallback (firstLine fallback.stdout))
  Unknown -> pure { code: 1, value: "", stdout: "", stderr: "vcs-op: no VCS detected\n" }

-- | The default branch strategy retains the historical master fallback when a
-- | remote does not expose origin/HEAD.
defaultBranchValue :: WorkflowContext -> Effect String
defaultBranchValue context = case context.vcs of
  Git -> do
    result <- Sys.exec "git" [ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" ]
    pure (if result.code == 0 && firstLine result.stdout /= "" then stripOrigin (firstLine result.stdout) else "master")
  Jj -> do
    result <- Sys.exec "jj" [ "bookmark", "list", "--remote", "origin", "--template", "name ++ \"\\n\"" ]
    if result.code /= 0 then pure "master"
    else pure (fromMaybe "master" (Array.find (\line -> Args.startsWith "main" line || Args.startsWith "master" line) (map trim (split (Pattern "\n") result.stdout))))
  Unknown -> pure "master"

-- | Query the branch used by sync's --stack policy, preserving failures.
currentBranchValue :: WorkflowContext -> Effect VcsValue
currentBranchValue context = case context.vcs of
  Git -> do
    result <- Sys.exec "git" [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (valueResult result (trim result.stdout))
  Jj -> do
    at <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    let atName = firstLine at.stdout
    if at.code /= 0 then pure (valueResult at "")
    else if atName /= "" then pure (valueResult at atName)
    else do
      parent <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@-", "--template", "name ++ \"\\n\"" ]
      pure (valueResult parent (firstLine parent.stdout))
  -- Unknown is a valid empty query result for --stack: there is no branch
  -- to stack onto, and the caller emits its existing guidance.
  Unknown -> pure { code: 0, value: "", stdout: "", stderr: "" }

-- | Inspect the working copy without conflating a clean tree with a failed
-- | inspection. The sync operation propagates InspectionFailed unchanged.
inspectDirty :: WorkflowContext -> Effect DirtyState
inspectDirty context = case context.vcs of
  Git -> do
    result <- Sys.exec "git" [ "status", "--porcelain" ]
    if result.code /= 0 then
      pure (InspectionFailed
        (if result.stderr == "" then failureLine "vcs-op: unable to inspect git working copy" else Outcome.captured result))
    else if trim result.stdout /= "" then pure DirtyDetected else pure Clean
  Jj -> do
    result <- Sys.exec "jj" [ "diff", "--revisions", "@", "--summary" ]
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
    Git -> passthroughCommand "git" ([ "diff", "origin/" <> value <> "...HEAD", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom value
      case source of
        Left outcome -> pure outcome
        Right from -> passthroughCommand "jj" ([ "diff", "--from", from, "--to", "@", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

diffNames :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
diffNames context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> passthroughCommand "git" ([ "diff", "origin/" <> value <> "...HEAD", "--name-only", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom value
      case source of
        Left outcome -> pure outcome
        Right from -> passthroughCommand "jj" ([ "diff", "--from", from, "--to", "@", "--name-only", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

diffStat :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
diffStat context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> passthroughCommand "git" ([ "diff", "origin/" <> value <> "...HEAD", "--shortstat", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom value
      case source of
        Left outcome -> pure outcome
        Right from -> passthroughCommand "jj" ([ "diff", "--from", from, "--to", "@", "--summary", "--" ] <> paths)
    Unknown -> pure noVcsOutcome

newFiles :: WorkflowContext -> Array String -> Effect Outcome.OpOutcome
newFiles context paths = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> passthroughCommand "git" ([ "diff", "--diff-filter=A", "--name-only", "origin/" <> value <> "...HEAD", "--" ] <> paths)
    Jj -> do
      source <- jjRangeFrom value
      case source of
        Left outcome -> pure outcome
        Right from -> do
          result <- Sys.exec "jj" ([ "diff", "--from", from, "--to", "@", "--summary", "--" ] <> paths)
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
    Git -> passthroughCommand "git" ([ "log", "origin/" <> value <> "..HEAD", "--oneline", "--" ] <> paths)
    Jj -> do
      probe <- Sys.exec "jj" [ "diff", "--revisions", "@", "--summary" ]
      if probe.code /= 0 then pure (failureLine "vcs-op: unable to inspect jj working copy for log-range")
      else do
        let target = if trim probe.stdout /= "" then "@" else "@-"
        passthroughCommand "jj" [ "log", "--revision", value <> ".." <> target, "--no-graph", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"" ]
    Unknown -> pure noVcsOutcome

logHead :: WorkflowContext -> Effect Outcome.OpOutcome
logHead context = case context.vcs of
  Git -> passthroughCommand "git" [ "log", "--max-count=1", "--oneline" ]
  Jj -> passthroughCommand "jj" [ "log", "--revision", "@-", "--no-graph", "--limit", "1", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"" ]
  Unknown -> pure noVcsOutcome

jjRangeFrom :: String -> Effect (Either Outcome.OpOutcome String)
jjRangeFrom base = do
  let revset = "heads(ancestors(@) & ancestors(" <> base <> "))"
  result <- Sys.exec "jj" [ "log", "--revision", revset, "--no-graph", "--template", "change_id" ]
  if result.code /= 0 then pure (Left (failureLine ("vcs-op: unable to resolve merge-base for base '" <> base <> "'")))
  else pure (Right (if trim result.stdout == "" then base else trim result.stdout))

branch :: WorkflowContext -> String -> Effect Outcome.OpOutcome
branch context name = case context.base of
  Nothing -> resolveBase context
  Just value -> case context.vcs of
    Git -> do
      verify <- Sys.exec "git" [ "rev-parse", "--verify", "refs/remotes/origin/" <> value ]
      if verify.code /= 0 then pure (failureLine ("vcs-op branch: origin/" <> value <> " not found. Push the parent branch before stacking."))
      else passthroughCommand "git" [ "branch", name, "origin/" <> value ]
    Jj -> do
      first <- passthroughCommand "jj" [ "new", value ]
      if first.exit == 0 then passthroughCommand "jj" [ "bookmark", "create", name, "--revision", "@" ] else pure first
    Unknown -> pure noVcsOutcome

commit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
commit context message files =
  if Array.null files then pure (failureLine "vcs-op: at least one file required (got none — pass the files you changed)")
  else do
    valid <- validateDirty context.vcs files
    case valid of
      Left error -> pure (Outcome.failure 1 (error <> "\n"))
      Right _ -> case context.vcs of
        Git -> do
          added <- passthroughCommand "git" ([ "add", "--" ] <> files)
          if added.exit == 0 then passthroughCommand "git" [ "commit", "--message", message ] else pure added
        Jj -> jjCommit message files
        Unknown -> pure noVcsOutcome

validateDirty :: VcsKind -> Array String -> Effect (Either String Unit)
validateDirty vcs files = do
  bad <- Array.filterA (\file -> do
    result <- case vcs of
      Git -> Sys.exec "git" [ "status", "--porcelain", "--", file ]
      Jj -> Sys.exec "jj" [ "diff", "--name-only", "--", file ]
      Unknown -> pure { code: 1, stdout: "", stderr: "" }
    pure (result.code /= 0 || trim result.stdout == "")) files
  if Array.null bad then pure (Right unit)
  else pure (Left (joinLines
    [ "vcs-op: file(s) not dirty (not in working-copy changes): " <> joinWithSpace bad
    , "        The caller must pass files it actually changed."
    ]))

jjCommit :: String -> Array String -> Effect Outcome.OpOutcome
jjCommit message files = do
  allResult <- Sys.exec "jj" [ "diff", "--name-only" ]
  if allResult.code /= 0 then pure (Outcome.captured allResult)
  else do
    canonicalResults <- traverse canonicalFiles files
    case traverse identity canonicalResults of
      Left outcome -> pure outcome
      Right canonicalGroups ->
        let canonical = Array.concat canonicalGroups
            allChanged = lines allResult.stdout
            unrelated = Array.filter (\changed -> not (Array.any (\file -> file == changed) canonical)) allChanged
        in if Array.null unrelated then describeAndMove message
        else do
          -- Split flow: describe @ as the feature change, split unrelated
          -- files into a separate revision, rebase that revision above @,
          -- move the working bookmark to @, then create a fresh @ on top.
          described <- passthroughCommand "jj" [ "describe", "--message", message ]
          if described.exit /= 0 then pure described
          else do
            splitCode <- passthroughCommand "jj" ([ "split" ] <> unrelated <> [ "--message", "chore: unrelated changes" ])
            if splitCode.exit /= 0 then pure splitCode
            else do
              rebase <- passthroughCommand "jj" [ "rebase", "--revision", "@-", "--insert-after", "@" ]
              if rebase.exit /= 0 then pure rebase
              else do
                bookmarkResult <- moveBookmarkToWorkingChange
                case bookmarkResult of
                  Left outcome -> pure outcome
                  Right bookmark -> case bookmark of
                    Nothing -> passthroughCommand "jj" [ "new" ]
                    Just name -> passthroughCommand "jj" [ "new", name ]
  where
  lines value = Array.filter (_ /= "") (map trim (split (Pattern "\n") value))
  canonicalFiles file = do
    result <- Sys.exec "jj" [ "diff", "--name-only", "--", file ]
    pure if result.code /= 0 then Left (Outcome.captured result) else Right (lines result.stdout)

-- | Describe the feature revision, create the empty working change, then
-- | relocate the first bookmark found on the parent chain to the described
-- | revision. Lookup failures are hard errors; a move itself is best effort.
describeAndMove :: String -> Effect Outcome.OpOutcome
describeAndMove message = do
  described <- passthroughCommand "jj" [ "describe", "--message", message ]
  if described.exit /= 0 then pure described
  else do
    newCode <- passthroughCommand "jj" [ "new" ]
    if newCode.exit /= 0 then pure newCode
    else do
      moved <- moveBookmarkToDescribedChange
      case moved of
        Left outcome -> pure outcome
        Right _ -> pure newCode

moveBookmarkToDescribedChange :: Effect (Either Outcome.OpOutcome Unit)
moveBookmarkToDescribedChange = walk 20 "@"
  where
  walk remaining rev =
    if remaining <= 0 then pure (Right unit)
    else do
      bookmark <- bookmarkAt (rev <> "-")
      case bookmark of
        Left outcome -> pure (Left outcome)
        Right Nothing -> walk (remaining - 1) (rev <> "-")
        Right (Just name) -> do
          bestEffortBookmarkMove name "@-"
          pure (Right unit)

-- | The split flow leaves @ on the described feature revision while the
-- | working bookmark remains on @- or a farther parent. Move that bookmark
-- | to @ before `jj new <bookmark>` creates the fresh working change; the
-- | described-change flow above instead creates @ first and targets @-.
moveBookmarkToWorkingChange :: Effect (Either Outcome.OpOutcome (Maybe String))
moveBookmarkToWorkingChange = walk 20 "@-"
  where
  walk remaining rev =
    if remaining <= 0 then pure (Right Nothing)
    else do
      bookmark <- bookmarkAt rev
      case bookmark of
        Left outcome -> pure (Left outcome)
        Right Nothing -> walk (remaining - 1) (rev <> "-")
        Right (Just name) -> do
          bestEffortBookmarkMove name "@"
          pure (Right (Just name))

bookmarkAt :: String -> Effect (Either Outcome.OpOutcome (Maybe String))
bookmarkAt revision = do
  result <- Sys.exec "jj" [ "bookmark", "list", "--revision", revision, "--template", "name ++ \"\\n\"" ]
  if result.code /= 0 then
    pure (Left (if result.stderr == "" then failureLine ("vcs-op: unable to inspect bookmark at '" <> revision <> "'") else Outcome.captured result))
  else pure (Right (Args.nonEmpty (firstLine result.stdout)))

bestEffortBookmarkMove :: String -> String -> Effect Unit
bestEffortBookmarkMove name target = do
  result <- Sys.execInherit "jj" [ "bookmark", "move", name, "--to", target ]
  case result.error of
    Just error -> Sys.stderrWrite ("vcs-op: jj failed to spawn: " <> error <> "\n")
    Nothing -> pure unit
  if result.code == 0 then pure unit
  else Sys.stderrWrite "vcs-op: bookmark move failed (best-effort)\n"

push :: WorkflowContext -> Maybe String -> Effect Outcome.OpOutcome
push context ref = case context.vcs of
  Git -> case ref of
    Just value -> passthroughCommand "git" [ "push", "--set-upstream", "origin", value ]
    Nothing -> passthroughCommand "git" [ "push" ]
  Jj -> case ref of
    Just value -> passthroughCommand "jj" [ "git", "push", "--bookmark", value ]
    Nothing -> passthroughCommand "jj" [ "git", "push" ]
  Unknown -> pure noVcsOutcome

fixCommit :: WorkflowContext -> String -> Array String -> Effect Outcome.OpOutcome
fixCommit context message files = do
  committed <- commit context message files
  if committed.exit /= 0 then pure committed
  else case context.vcs of
    Git -> passthroughCommand "git" [ "push" ]
    Jj -> passthroughCommand "jj" [ "git", "push" ]
    Unknown -> pure noVcsOutcome

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

passthroughCommand :: String -> Array String -> Effect Outcome.OpOutcome
passthroughCommand command args = do
  result <- Sys.execInherit command args
  case result.error of
    Just error -> pure (Outcome.failure 1 ("vcs-op: " <> command <> " failed to spawn: " <> error <> "\n"))
    Nothing -> pure (Outcome.passthrough result.code)

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

jjRemote :: String -> String
jjRemote output = case Array.head (split (Pattern "\n") output) of
  Nothing -> ""
  Just line -> case Array.filter (_ /= "") (split (Pattern " " ) (trim line)) of
    tokens -> case Array.uncons tokens of
      Nothing -> ""
      Just { tail: afterName } -> fromMaybe "" (Array.head afterName)

firstLine :: String -> String
firstLine output = fromMaybe "" (trim <$> Array.head (split (Pattern "\n") output))

stripOrigin :: String -> String
stripOrigin value = if Args.startsWith "origin/" value then drop 7 value else value
