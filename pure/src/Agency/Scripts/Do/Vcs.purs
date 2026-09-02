module Agency.Scripts.Do.Vcs
  ( VcsKind(..)
  , VcsOp(..)
  , parseVcsOp
  , detectVcs
  , runVcsOp
  , vcsName
  , headRevisionValue
  , defaultBranchValue
  , currentBranchValue

) where
import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (fromString)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), split, trim)
import Data.String.CodeUnits (drop, length, take)
import Data.Traversable (traverse)
import Effect (Effect)
import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys

-- | VCS implementations understood by the dispatcher.
data VcsKind = Git | Jj | Unknown

derive instance eqVcsKind :: Eq VcsKind

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

availableOps :: String
availableOps = "detect, fetch, remote-url, head-revision, head-commit-sha, default-branch, current-branch, base, dirty, diff-range, diff-names, diff-stat, new-files, log-range, log-head, branch, commit, push, fix-commit, refresh-default-branch, fast-forward-if-safe"

vcsName :: VcsKind -> String
vcsName kind = case kind of
  Git -> "git"
  Jj -> "jj"
  Unknown -> "unknown"

parseVcsOp :: Array String -> Either String VcsOp
parseVcsOp args =
  case Array.uncons args of
    Nothing -> Left (unknownOperation "")
    Just { head: name, tail: rest } -> case name of
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
      "branch" -> case Array.head rest of
        Just branchName -> Right (Branch branchName)
        Nothing -> Left "vcs-op branch: branch name required"
      "commit" -> case Array.uncons rest of
        Nothing -> Left "vcs-op commit: commit message required"
        Just { head: message, tail: files } -> Right (Commit message files)
      "push" -> Right (Push (Array.head rest))
      "fix-commit" -> case Array.uncons rest of
        Nothing -> Left "vcs-op fix-commit: commit message required"
        Just { head: message, tail: files } -> Right (FixCommit message files)
      "refresh-default-branch" -> Right RefreshDefaultBranch
      "fast-forward-if-safe" -> Right FastForwardIfSafe
      _ -> Left (unknownOperation name)
  where
  unknownOperation name =
    "vcs-op: unknown operation '" <> name <> "'\nAvailable: " <> availableOps

-- New sync-internal operations are deliberately part of the algebra even
-- though they are no-ops for jj. They keep sync's policy out of its caller.
-- They are declared below the parser to keep the historical constructor order
-- readable in generated docs.

-- | Resolve VCS using the same precedence as state.sh/vcs-op.
detectVcs :: Effect VcsKind
detectVcs = do
  override <- Sys.getEnv "VCS_OVERRIDE"
  if override /= "" then pure (parseKind override)
  else do
    state <- State.readState ".do-results.json"
    case state of
      Right (Just value) ->
        let fromState = State.stateGet "vcs" value
        in if fromState /= "" then pure (parseKind fromState) else filesystemFallback
      _ -> filesystemFallback
  where
  parseKind value = case value of
    "git" -> Git
    "jj" -> Jj
    _ -> Unknown
  filesystemFallback = do
    jj <- Sys.isDir ".jj"
    if jj then pure Jj
    else do
      git <- Sys.isDir ".git"
      if git then pure Git else pure Unknown

-- | Run one operation and return the process exit status.
runVcsOp :: VcsOp -> Effect Int
runVcsOp operation = do
  vcs <- detectVcs
  case operation of
    Detect -> do
      printLine (vcsName vcs)
      pure 0
    Fetch -> case vcs of
      Git -> runExternal "git" [ "fetch", "origin" ]
      Jj -> runExternal "jj" [ "git", "fetch" ]
      Unknown -> noVcs
    RemoteUrl -> case vcs of
      Git -> captureAndPrint "git" [ "remote", "get-url", "origin" ]
      Jj -> jjRemoteUrl
      Unknown -> noVcs
    HeadRevision -> case vcs of
      Git -> captureAndPrint "git" [ "rev-parse", "--abbrev-ref", "HEAD" ]
      Jj -> jjHeadRevision
      Unknown -> noVcs
    HeadCommitSha -> case vcs of
      Git -> captureAndPrint "git" [ "rev-parse", "HEAD" ]
      Jj -> captureAndPrint "jj" [ "log", "--revision", "@-", "--no-graph", "--template", "commit_id" ]
      Unknown -> noVcs
    DefaultBranch -> do
      value <- defaultBranch vcs
      printLine value
      pure 0
    CurrentBranch -> currentBranch vcs
    Base -> resolveBase
    Dirty -> dirty vcs
    DiffRange paths -> diffRange vcs paths
    DiffNames paths -> diffNames vcs paths
    DiffStat paths -> diffStat vcs paths
    NewFiles paths -> newFiles vcs paths
    LogRange paths -> logRange vcs paths
    LogHead -> logHead vcs
    Branch name -> branch vcs name
    Commit message files -> commit vcs message files
    Push ref -> push vcs ref
    FixCommit message files -> fixCommit vcs message files
    RefreshDefaultBranch -> refreshDefaultBranch vcs
    FastForwardIfSafe -> fastForwardIfSafe vcs
  where
  noVcs = failLine "vcs-op: no VCS detected"

-- | New operations used by sync. Git performs the policy action, jj is a no-op.
refreshDefaultBranch :: VcsKind -> Effect Int
refreshDefaultBranch vcs = case vcs of
  Git -> runExternal "git" [ "remote", "set-head", "origin", "--auto" ]
  Jj -> pure 0
  Unknown -> pure 0

fastForwardIfSafe :: VcsKind -> Effect Int
fastForwardIfSafe vcs = case vcs of
  Jj -> pure 0
  Unknown -> pure 0
  Git -> do
    upstream <- Sys.exec "git" [ "rev-parse", "--abbrev-ref", "@{u}" ]
    if upstream.code /= 0 then pure 0
    else do
      let upstreamName = trim upstream.stdout
      behind <- Sys.exec "git" [ "rev-list", "--count", "HEAD.." <> upstreamName ]
      ahead <- Sys.exec "git" [ "rev-list", "--count", upstreamName <> "..HEAD" ]
      let behindCount = fromMaybe 0 (fromString (trim behind.stdout))
          aheadCount = fromMaybe 0 (fromString (trim ahead.stdout))
      if behind.code == 0 && ahead.code == 0 && behindCount > 0 && aheadCount == 0 then
        runExternal "git" [ "pull", "--ff-only" ]
      else pure 0

-- | Read the persisted base, failing loudly when sync has not resolved it.
resolveBase :: Effect Int
resolveBase = do
  state <- State.readState ".do-results.json"
  let base = case state of
        Right (Just value) -> State.stateGet "base" value
        _ -> ""
  if base /= "" then printLine base $> 0
  else failLines
    [ "vcs-op: base is not set. sync must run first to resolve the base"
    , "        (from --base <branch>, --stack, or the default branch)."
    , "        If this was a --from re-run, the parent run did not persist base."
    , "        (Same error fires if jq is unavailable or .do-results.json is corrupt — check 'command -v jq'.)"
    ]

captureAndPrint :: String -> Array String -> Effect Int
captureAndPrint command args = do
  result <- Sys.exec command args
  emit result
  pure result.code

runExternal :: String -> Array String -> Effect Int
runExternal = captureAndPrint

emit :: Sys.ExecResult -> Effect Unit
emit result = do
  if result.stdout == "" then pure unit else Sys.stdoutWrite result.stdout
  if result.stderr == "" then pure unit else Sys.stderrWrite result.stderr

printLine :: String -> Effect Unit
printLine value = Sys.stdoutWrite (value <> "\n")

failLine :: String -> Effect Int
failLine value = failLines [ value ]

failLines :: Array String -> Effect Int
failLines values = do
  Sys.stderrWrite (joinLines values <> "\n")
  pure 1

joinLines :: Array String -> String
joinLines values =
  case Array.uncons values of
    Nothing -> ""
    Just { head, tail } -> foldLines head tail
  where
  foldLines acc rest = case Array.uncons rest of
    Nothing -> acc
    Just { head, tail } -> foldLines (acc <> "\n" <> head) tail

firstLine :: String -> String
firstLine output = fromMaybe "" (trim <$> Array.head (split (Pattern "\n") output))


startsWith :: String -> String -> Boolean
startsWith prefix value = take (stringLength prefix) value == prefix

stringLength :: String -> Int
stringLength value = length value

jjRemoteUrl :: Effect Int
jjRemoteUrl = do
  result <- Sys.exec "jj" [ "git", "remote", "list" ]
  if result.code /= 0 then emit result $> result.code
  else case Array.head (split (Pattern "\n") result.stdout) of
    Nothing -> pure 0
    Just line -> case Array.filter (_ /= "") (split (Pattern " ") (trim line)) of
      tokens -> case Array.uncons tokens of
        Nothing -> pure 0
        Just { tail: afterName } -> case Array.uncons afterName of
          Nothing -> pure 0
          Just { head: url } -> printLine url $> 0

jjHeadRevision :: Effect Int
jjHeadRevision = do
  result <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
  let bookmark = firstLine result.stdout
  if result.code /= 0 then emit result $> result.code
  else if bookmark /= "" then printLine bookmark $> 0
  else captureAndPrint "jj" [ "log", "--revision", "@", "--no-graph", "--template", "change_id" ]

jjDefaultBranch :: Effect String
jjDefaultBranch = do
  result <- Sys.exec "jj" [ "bookmark", "list", "--remote", "origin", "--template", "name ++ \"\\n\"" ]
  if result.code /= 0 then pure "master"
  else case Array.find (\line -> startsWith "main" line || startsWith "master" line) (map trim (split (Pattern "\n") result.stdout)) of
    Just value -> pure value
    Nothing -> pure "master"

defaultBranch :: VcsKind -> Effect String
defaultBranch vcs = case vcs of
  Git -> do
    result <- Sys.exec "git" [ "symbolic-ref", "--short", "refs/remotes/origin/HEAD" ]
    if result.code == 0 && firstLine result.stdout /= "" then pure (stripOrigin (firstLine result.stdout)) else pure "master"
  Jj -> jjDefaultBranch
  Unknown -> pure "master"

stripOrigin :: String -> String
stripOrigin value = if startsWith "origin/" value then drop 7 value else value

-- | Query the current revision without writing it, for sync's protocol output.
headRevisionValue :: VcsKind -> Effect String
headRevisionValue vcs = case vcs of
  Git -> do
    result <- Sys.exec "git" [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (trim result.stdout)
  Jj -> do
    result <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    let bookmark = firstLine result.stdout
    if result.code == 0 && bookmark /= "" then pure bookmark
    else do
      fallback <- Sys.exec "jj" [ "log", "--revision", "@", "--no-graph", "--template", "change_id" ]
      pure (trim fallback.stdout)
  Unknown -> pure ""

defaultBranchValue :: VcsKind -> Effect String
defaultBranchValue = defaultBranch

currentBranchValue :: VcsKind -> Effect String
currentBranchValue vcs = case vcs of
  Git -> do
    result <- Sys.exec "git" [ "rev-parse", "--abbrev-ref", "HEAD" ]
    pure (trim result.stdout)
  Jj -> do
    at <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    if firstLine at.stdout /= "" then pure (firstLine at.stdout)
    else do
      parent <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@-", "--template", "name ++ \"\\n\"" ]
      pure (firstLine parent.stdout)
  Unknown -> pure ""

currentBranch :: VcsKind -> Effect Int
currentBranch vcs = case vcs of
  Git -> captureAndPrint "git" [ "rev-parse", "--abbrev-ref", "HEAD" ]
  Jj -> do
    at <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@", "--template", "name ++ \"\\n\"" ]
    if firstLine at.stdout /= "" then printLine (firstLine at.stdout) $> 0
    else do
      parent <- Sys.exec "jj" [ "bookmark", "list", "--revision", "@-", "--template", "name ++ \"\\n\"" ]
      printLine (firstLine parent.stdout) $> 0
  Unknown -> printLine "" $> 0

dirty :: VcsKind -> Effect Int
dirty vcs = case vcs of
  Git -> do
    result <- Sys.exec "git" [ "status", "--porcelain" ]
    if result.code /= 0 then pure 1 else if trim result.stdout /= "" then pure 0 else pure 1
  Jj -> do
    result <- Sys.exec "jj" [ "diff", "--revisions", "@", "--summary" ]
    if result.code /= 0 then failLine "vcs-op: unable to inspect jj working copy" else if trim result.stdout /= "" then pure 0 else pure 1
  Unknown -> pure 1

diffRange :: VcsKind -> Array String -> Effect Int
diffRange vcs paths = do
  base <- baseValue
  case base of
    Nothing -> resolveBase
    Just value -> case vcs of
      Git -> captureAndPrint "git" ([ "diff", "origin/" <> value <> "...HEAD", "--" ] <> paths)
      Jj -> do
        source <- jjRangeFrom value
        case source of
          Nothing -> pure 1
          Just from -> captureAndPrint "jj" ([ "diff", "--from", from, "--to", "@", "--" ] <> paths)
      Unknown -> noVcsMessage

diffNames :: VcsKind -> Array String -> Effect Int
diffNames vcs paths = do
  base <- baseValue
  case base of
    Nothing -> resolveBase
    Just value -> case vcs of
      Git -> captureAndPrint "git" ([ "diff", "origin/" <> value <> "...HEAD", "--name-only", "--" ] <> paths)
      Jj -> do
        source <- jjRangeFrom value
        case source of
          Nothing -> pure 1
          Just from -> captureAndPrint "jj" ([ "diff", "--from", from, "--to", "@", "--name-only", "--" ] <> paths)
      Unknown -> noVcsMessage

diffStat :: VcsKind -> Array String -> Effect Int
diffStat vcs paths = do
  base <- baseValue
  case base of
    Nothing -> resolveBase
    Just value -> case vcs of
      Git -> captureAndPrint "git" ([ "diff", "origin/" <> value <> "...HEAD", "--shortstat", "--" ] <> paths)
      Jj -> do
        source <- jjRangeFrom value
        case source of
          Nothing -> pure 1
          Just from -> captureAndPrint "jj" ([ "diff", "--from", from, "--to", "@", "--summary", "--" ] <> paths)
      Unknown -> noVcsMessage

newFiles :: VcsKind -> Array String -> Effect Int
newFiles vcs paths = do
  base <- baseValue
  case base of
    Nothing -> resolveBase
    Just value -> case vcs of
      Git -> captureAndPrint "git" ([ "diff", "--diff-filter=A", "--name-only", "origin/" <> value <> "...HEAD", "--" ] <> paths)
      Jj -> do
        source <- jjRangeFrom value
        case source of
          Nothing -> pure 1
          Just from -> do
            result <- Sys.exec "jj" ([ "diff", "--from", from, "--to", "@", "--summary", "--" ] <> paths)
            if result.code /= 0 then emit result $> result.code else do
              let names = Array.mapMaybe addedName (split (Pattern "\n") result.stdout)
              printText (joinLines names)
              pure 0
      Unknown -> pure 1
  where
  addedName line =
    let tokens = Array.filter (_ /= "") (split (Pattern " ") (trim line))
    in if Array.head tokens == Just "A" then Array.index tokens 1 else Nothing

logRange :: VcsKind -> Array String -> Effect Int
logRange vcs paths = do
  base <- baseValue
  case base of
    Nothing -> resolveBase
    Just value -> case vcs of
      Git -> captureAndPrint "git" ([ "log", "origin/" <> value <> "..HEAD", "--oneline", "--" ] <> paths)
      Jj -> do
        probe <- Sys.exec "jj" [ "diff", "--revisions", "@", "--summary" ]
        if probe.code /= 0 then failLine "vcs-op: unable to inspect jj working copy for log-range"
        else do
          let target = if trim probe.stdout /= "" then "@" else "@-"
          captureAndPrint "jj" [ "log", "--revision", value <> ".." <> target, "--no-graph", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"" ]
      Unknown -> noVcsMessage

logHead :: VcsKind -> Effect Int
logHead vcs = case vcs of
  Git -> captureAndPrint "git" [ "log", "--max-count=1", "--oneline" ]
  Jj -> captureAndPrint "jj" [ "log", "--revision", "@-", "--no-graph", "--limit", "1", "--template", "separate(\" \", commit_id.shortest(8), change_id.shortest(8), description.first_line()) ++ \"\\n\"" ]
  Unknown -> noVcsMessage

baseValue :: Effect (Maybe String)
baseValue = do
  state <- State.readState ".do-results.json"
  let value = case state of
        Right (Just current) -> State.stateGet "base" current
        _ -> ""
  pure (if value == "" then Nothing else Just value)

jjRangeFrom :: String -> Effect (Maybe String)
jjRangeFrom base = do
  let revset = "heads(ancestors(@) & ancestors(" <> base <> "))"
  result <- Sys.exec "jj" [ "log", "--revision", revset, "--no-graph", "--template", "change_id" ]
  if result.code /= 0 then do
    _ <- failLine ("vcs-op: unable to resolve merge-base for base '" <> base <> "'")
    pure Nothing
  else pure (Just (if trim result.stdout == "" then base else trim result.stdout))

noVcsMessage :: Effect Int
noVcsMessage = failLine "vcs-op: no VCS detected"

branch :: VcsKind -> String -> Effect Int
branch vcs name = do
  base <- baseValue
  case base of
    Nothing -> resolveBase
    Just value -> case vcs of
      Git -> do
        verify <- Sys.exec "git" [ "rev-parse", "--verify", "refs/remotes/origin/" <> value ]
        if verify.code /= 0 then failLine ("vcs-op branch: origin/" <> value <> " not found. Push the parent branch before stacking.")
        else runExternal "git" [ "branch", name, "origin/" <> value ]
      Jj -> do
        first <- runExternal "jj" [ "new", value ]
        if first == 0 then runExternal "jj" [ "bookmark", "create", name, "--revision", "@" ] else pure first
      Unknown -> noVcsMessage

commit :: VcsKind -> String -> Array String -> Effect Int
commit vcs message files =
  if Array.null files then failLine "vcs-op: at least one file required (got none — pass the files you changed)"
  else do
    valid <- validateDirty vcs files
    if not valid then pure 1
    else case vcs of
      Git -> runExternal "git" ([ "add", "--" ] <> files) >>= \code -> if code == 0 then runExternal "git" [ "commit", "--message", message ] else pure code
      Jj -> jjCommit message files
      Unknown -> noVcsMessage

validateDirty :: VcsKind -> Array String -> Effect Boolean
validateDirty vcs files = do
  bad <- Array.filterA (\file -> do
    result <- case vcs of
      Git -> Sys.exec "git" [ "status", "--porcelain", "--", file ]
      Jj -> Sys.exec "jj" [ "diff", "--name-only", "--", file ]
      Unknown -> pure { code: 1, stdout: "", stderr: "" }
    pure (result.code /= 0 || trim result.stdout == "")) files
  if Array.null bad then pure true
  else do
    _ <- failLines
      [ "vcs-op: file(s) not dirty (not in working-copy changes): " <> joinWithSpace bad
      , "        The caller must pass files it actually changed."
      ]
    pure false

joinWithSpace :: Array String -> String
joinWithSpace values =
  case Array.uncons values of
    Nothing -> ""
    Just { head, tail } -> foldSpace head tail
  where
  foldSpace acc rest = case Array.uncons rest of
    Nothing -> acc
    Just { head, tail } -> foldSpace (acc <> " " <> head) tail

jjCommit :: String -> Array String -> Effect Int
jjCommit message files = do
  allResult <- Sys.exec "jj" [ "diff", "--name-only" ]
  canonical <- Array.concat <$> traverse (canonicalFiles) files
  let allChanged = lines allResult.stdout
      unrelated = Array.filter (\changed -> not (Array.any (\file -> file == changed) canonical)) allChanged
  if Array.null unrelated then describeAndMove message
  else do
    described <- runExternal "jj" [ "describe", "--message", message ]
    if described /= 0 then pure described
    else do
      splitCode <- runExternal "jj" ([ "split" ] <> unrelated <> [ "--message", "chore: unrelated changes" ])
      if splitCode /= 0 then pure splitCode
      else do
        rebase <- runExternal "jj" [ "rebase", "--revision", "@-", "--insert-after", "@" ]
        if rebase /= 0 then pure rebase
        else do
          bookmark <- moveBookmarkToWorkingChange
          if bookmark == "" then runExternal "jj" [ "new" ] else runExternal "jj" [ "new", bookmark ]
  where
  lines value = Array.filter (_ /= "") (map trim (split (Pattern "\n") value))
  canonicalFiles file = do
    result <- Sys.exec "jj" [ "diff", "--name-only", "--", file ]
    pure (lines result.stdout)

describeAndMove :: String -> Effect Int
describeAndMove message = do
  described <- runExternal "jj" [ "describe", "--message", message ]
  newCode <- if described == 0 then runExternal "jj" [ "new" ] else pure described
  _ <- moveBookmarkToDescribedChange
  pure newCode

moveBookmarkToDescribedChange :: Effect Unit
moveBookmarkToDescribedChange = walk 20 "@"
  where
  walk remaining rev = if remaining <= 0 then pure unit else do
    result <- Sys.exec "jj" [ "bookmark", "list", "--revision", rev <> "-", "--template", "name ++ \"\\n\"" ]
    let bookmark = firstLine result.stdout
    if bookmark == "" then walk (remaining - 1) (rev <> "-")
    else do
      _ <- runExternal "jj" [ "bookmark", "move", bookmark, "--to", "@-" ]
      pure unit

moveBookmarkToWorkingChange :: Effect String
moveBookmarkToWorkingChange = walk 20 "@-"
  where
  walk remaining rev = if remaining <= 0 then pure "" else do
    result <- Sys.exec "jj" [ "bookmark", "list", "--revision", rev, "--template", "name ++ \"\\n\"" ]
    let bookmark = firstLine result.stdout
    if bookmark == "" then walk (remaining - 1) (rev <> "-")
    else do
      _ <- runExternal "jj" [ "bookmark", "move", bookmark, "--to", "@" ]
      pure bookmark

push :: VcsKind -> Maybe String -> Effect Int
push vcs ref = case vcs of
  Git -> case ref of
    Just value -> runExternal "git" [ "push", "--set-upstream", "origin", value ]
    Nothing -> runExternal "git" [ "push" ]
  Jj -> case ref of
    Just value -> runExternal "jj" [ "git", "push", "--bookmark", value ]
    Nothing -> runExternal "jj" [ "git", "push" ]
  Unknown -> noVcsMessage

fixCommit :: VcsKind -> String -> Array String -> Effect Int
fixCommit vcs message files = do
  committed <- commit vcs message files
  if committed /= 0 then pure committed
  else case vcs of
    Git -> runExternal "git" [ "push" ]
    Jj -> runExternal "jj" [ "git", "push" ]
    Unknown -> noVcsMessage
printText :: String -> Effect Unit
printText value =
  if value == "" then pure unit else Sys.stdoutWrite (value <> "\n")

