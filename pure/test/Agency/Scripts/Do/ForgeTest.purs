module Agency.Scripts.Do.ForgeTest (run) where

import Prelude
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console as Console

import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Sys as Sys

assert :: String -> Boolean -> Effect Unit
assert label condition =
  if condition then pure unit
  else do
    Console.error ("FAIL: " <> label)
    Sys.exit 1

run :: Effect Unit
run = do
  assert "forge override has highest precedence" (Forge.detectForge (Just "bitbucket") (Just "github") (Right "https://github.com/example/project.git") == Forge.Bitbucket)
  assert "forge state precedes remote URL" (Forge.detectForge Nothing (Just "bitbucket") (Right "https://github.com/example/project.git") == Forge.Bitbucket)
  assert "forge remote URL is fallback" (Forge.detectForge Nothing Nothing (Right "https://github.com/example/project.git") == Forge.Github)
  assert "github URL classification" (Forge.classifyUrl "https://github.com/example/project.git" == Forge.Github)
  assert "bitbucket URL classification" (Forge.classifyUrl "ssh://git@bitbucket.org/example/project.git" == Forge.Bitbucket)
  assert "unknown URL classification" (Forge.classifyUrl "https://gitlab.com/example/project.git" == Forge.Unknown)
  assert "github supports pull request view" (Forge.supports Forge.Github "pr-view")
  assert "github supports issue checks" (Forge.supports Forge.Github "pr-checks")
  assert "bitbucket has no supported operations" (not (Forge.supports Forge.Bitbucket "pr-create"))
  assert "unknown forge has no supported operations" (not (Forge.supports Forge.Unknown "issue-view"))
