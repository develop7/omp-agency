module Agency.Scripts.Do.Forge
  ( ForgeKind(..)
  , ForgeOp(..)
  , parseForgeOp
  , classifyUrl
  , supports
  , detectForge
  , runForgeOp
  , forgeName
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), split, trim)
import Data.String.CodeUnits (contains)
import Effect (Effect)

import Agency.Scripts.Do.State as State
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs

-- | Remote forge families recognized by the workflow.
data ForgeKind = Github | Bitbucket | Unknown

derive instance eqForgeKind :: Eq ForgeKind

-- | Operations exposed by forge-op. Argument arrays are passed to gh intact.
data ForgeOp
  = Detect
  | Supports String
  | PrView (Array String)
  | PrCreate (Array String)
  | PrEdit (Array String)
  | PrComment (Array String)
  | IssueView (Array String)
  | PrChecks (Array String)

forgeName :: ForgeKind -> String
forgeName kind = case kind of
  Github -> "github"
  Bitbucket -> "bitbucket"
  Unknown -> "unknown"

knownOps :: Array String
knownOps = [ "pr-view", "pr-create", "pr-edit", "pr-comment", "issue-view", "pr-checks" ]

availableOps :: String
availableOps = "detect, supports, pr-view, pr-create, pr-edit, pr-comment, issue-view, pr-checks"

-- | Classify an origin URL. This is intentionally the sole URL classifier.
classifyUrl :: String -> ForgeKind
classifyUrl url
  | contains (Pattern "github.com") url = Github
  | contains (Pattern "bitbucket.") url = Bitbucket
  | otherwise = Unknown

parseForgeOp :: Array String -> Either String ForgeOp
parseForgeOp args =
  case Array.uncons args of
    Nothing -> Left "forge-op: no operation given\nUsage: forge-op <detect|supports|op> [args]\nOps: pr-view pr-create pr-edit pr-comment issue-view pr-checks"
    Just { head: name, tail: rest } -> case name of
      "detect" -> Right Detect
      "supports" -> case Array.head rest of
        Just operation -> Right (Supports operation)
        Nothing -> Left "forge-op: supports requires an operation (e.g. forge-op supports pr-create)"
      "pr-view" -> Right (PrView rest)
      "pr-create" -> Right (PrCreate rest)
      "pr-edit" -> Right (PrEdit rest)
      "pr-comment" -> Right (PrComment rest)
      "issue-view" -> Right (IssueView rest)
      "pr-checks" -> Right (PrChecks rest)
      _ -> Left ("forge-op: unknown operation '" <> name <> "'\nAvailable: " <> availableOps)

supports :: ForgeKind -> String -> Boolean
supports forge operation = case forge of
  Github -> Array.any (_ == operation) knownOps
  Bitbucket -> false
  Unknown -> false

-- | Resolve forge with override/state/url fallback precedence.
detectForge :: Effect ForgeKind
detectForge = do
  override <- Sys.getEnv "FORGE_OVERRIDE"
  if override /= "" then pure (parseKind override)
  else do
    state <- State.readState ".do-results.json"
    case state of
      Right (Just value) ->
        let fromState = State.stateGet "forge" value
        in if fromState /= "" then pure (parseKind fromState) else classifyRemote
      _ -> classifyRemote
  where
  parseKind value = case value of
    "github" -> Github
    "bitbucket" -> Bitbucket
    _ -> Unknown
  classifyRemote = do
    vcs <- Vcs.detectVcs
    url <- remoteUrl vcs
    pure (classifyUrl url)

remoteUrl :: Vcs.VcsKind -> Effect String
remoteUrl vcs = do
  result <- case vcs of
    Vcs.Git -> Sys.exec "git" [ "remote", "get-url", "origin" ]
    Vcs.Jj -> Sys.exec "jj" [ "git", "remote", "list" ]
    Vcs.Unknown -> pure { code: 1, stdout: "", stderr: "" }
  if result.code /= 0 then pure ""
  else case vcs of
    Vcs.Git -> pure (trim result.stdout)
    Vcs.Jj -> case Array.head (split (Pattern "\n") result.stdout) of
      Nothing -> pure ""
      Just line -> case Array.filter (_ /= "") (split (Pattern " " ) (trim line)) of
        tokens -> case Array.uncons tokens of
          Nothing -> pure ""
          Just { tail: rest } -> pure (fromMaybe "" (Array.head rest))
    Vcs.Unknown -> pure ""

-- | Execute gh exactly as forge-op's github dispatch arm does.
runForgeOp :: ForgeOp -> Effect Int
runForgeOp operation = do
  forge <- detectForge
  case operation of
    Detect -> do
      Sys.stdoutWrite (forgeName forge <> "\n")
      pure 0
    Supports name -> if supports forge name then pure 0 else pure 1
    PrView args -> dispatch forge "pr-view" "pr" "view" args
    PrCreate args -> dispatch forge "pr-create" "pr" "create" args
    PrEdit args -> dispatch forge "pr-edit" "pr" "edit" args
    PrComment args -> dispatch forge "pr-comment" "pr" "comment" args
    IssueView args -> dispatch forge "issue-view" "issue" "view" args
    PrChecks args -> dispatch forge "pr-checks" "pr" "checks" args
  where
  dispatch forge opName command subcommand args = case forge of
    Github -> Sys.execInherit "gh" ([ command, subcommand ] <> args)
    _ -> do
      Sys.stderrWrite
        ("forge-op: forge '" <> forgeName forge <> "' does not support '" <> opName <> "'\n"
          <> "        Bitbucket support is tracked in srid/agency#10.\n")
      pure 1
