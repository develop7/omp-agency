module Agency.Scripts.Do.Forge
  ( module ForgeKinds
  , ForgeOp(..)
  , parseForgeOp
  , classifyUrl
  , supports
  , detectForge
  , runForgeOp
  , forgeName
  ) where

import Prelude

import Agency.Scripts.Do.Args as Args
import Agency.Scripts.Do.Context (WorkflowContext)
import Agency.Scripts.Do.ForgeKind (ForgeKind(..))
import Agency.Scripts.Do.ForgeKind (ForgeKind(..)) as ForgeKinds
import Agency.Scripts.Do.Outcome as Outcome
import Agency.Scripts.Do.Sys as Sys
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), joinWith)
import Data.String.CodeUnits (contains)
import Effect (Effect)
-- | Forge operation algebra. Arguments remain verbatim for the forge CLI.
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
operationNames :: Array String
operationNames = [ "pr-view", "pr-create", "pr-edit", "pr-comment", "issue-view", "pr-checks" ]

commandNames :: Array String
commandNames = [ "detect", "supports" ] <> operationNames

availableOps :: String
availableOps = joinWith ", " commandNames

-- | Classify an origin URL. This is intentionally the sole URL classifier.
classifyUrl :: String -> ForgeKind
classifyUrl url
  | contains (Pattern "github.com") url = Github
  | contains (Pattern "bitbucket.") url = Bitbucket
  | otherwise = Unknown

parseForgeOp :: Array String -> Either String ForgeOp
parseForgeOp args =
  case Args.requiredNonEmpty args of
    Nothing -> Left ("forge-op: no operation given\nUsage: forge-op <detect|supports|op> [args]\nOps: " <> joinWith " " operationNames)
    Just { value: name, rest } ->
      if Array.elem name commandNames then
        case name of
          "detect" -> Right Detect
          "supports" -> case Args.requiredNonEmpty rest of
            Just { value: operation } -> Right (Supports operation)
            Nothing -> Left "forge-op: supports requires an operation (e.g. forge-op supports pr-create)"
          "pr-view" -> Right (PrView rest)
          "pr-create" -> Right (PrCreate rest)
          "pr-edit" -> Right (PrEdit rest)
          "pr-comment" -> Right (PrComment rest)
          "issue-view" -> Right (IssueView rest)
          "pr-checks" -> Right (PrChecks rest)
          _ -> Left ("forge-op: unknown operation '" <> name <> "'\nAvailable: " <> availableOps)
      else Left ("forge-op: unknown operation '" <> name <> "'\nAvailable: " <> availableOps)

supports :: ForgeKind -> String -> Boolean
supports forge operation = case forge of
  Github -> Array.elem operation operationNames
  Bitbucket -> false
  Unknown -> false

-- | Resolve forge from already-read overrides, state, and remote lookup.
-- | Providers do not access process environment or state files themselves.
detectForge :: Maybe String -> Maybe String -> Either String String -> ForgeKind
detectForge override fromState remote =
  case override of
    Just value -> parseKind value
    Nothing -> case fromState of
      Just value -> parseKind value
      Nothing -> case remote of
        Right url -> classifyUrl url
        Left _ -> Unknown
  where
  parseKind value = case value of
    "github" -> Github
    "bitbucket" -> Bitbucket
    _ -> Unknown

-- | Execute one forge operation against a resolved context. gh subprocesses
-- | deliberately inherit streams because they are interactive/pass-through.
runForgeOp :: WorkflowContext -> ForgeOp -> Effect Outcome.OpOutcome
runForgeOp context operation = case operation of
  Detect -> pure (Outcome.withStdout (forgeName context.forge <> "\n"))
  Supports name -> pure (if supports context.forge name then Outcome.success else Outcome.failure 1 "")
  PrView args -> dispatch context.forge "pr-view" "pr" "view" args
  PrCreate args -> dispatch context.forge "pr-create" "pr" "create" args
  PrEdit args -> dispatch context.forge "pr-edit" "pr" "edit" args
  PrComment args -> dispatch context.forge "pr-comment" "pr" "comment" args
  IssueView args -> dispatch context.forge "issue-view" "issue" "view" args
  PrChecks args -> dispatch context.forge "pr-checks" "pr" "checks" args
  where
  dispatch forge opName command subcommand args = case forge of
    Github -> do
      result <- Sys.execInherit "gh" ([ command, subcommand ] <> args)
      case result.error of
        Just error -> pure (Outcome.failure 1 ("forge-op: gh failed to spawn: " <> error <> "\n"))
        Nothing -> pure (Outcome.passthrough result.code)
    _ -> pure (Outcome.failure 1
      ("forge-op: forge '" <> forgeName forge <> "' does not support '" <> opName <> "'\n"
        <> "        Bitbucket support is tracked in srid/agency#10.\n"))
