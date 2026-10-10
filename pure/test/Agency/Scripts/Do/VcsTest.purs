module Agency.Scripts.Do.VcsTest (run) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console as Console

import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs

assert :: String -> Boolean -> Effect Unit
assert label condition =
  if condition then pure unit
  else do
    Console.error ("FAIL: " <> label)
    Sys.exit 1

run :: Effect Unit
run = do
  assert "VCS override has highest precedence" (Vcs.detectVcs (Just "git") (Just "jj") true false == Vcs.Git)
  assert "state VCS precedes filesystem" (Vcs.detectVcs Nothing (Just "jj") false true == Vcs.Jj)
  assert "jj filesystem precedes git filesystem" (Vcs.detectVcs Nothing Nothing true true == Vcs.Jj)
  case Vcs.parseVcsOp [ "detect" ] of
    Right Vcs.Detect -> pure unit
    _ -> assert "detect parses" false
  case Vcs.parseVcsOp [ "commit", "message", "src/Main.purs" ] of
    Right (Vcs.Commit message files) -> do
      assert "commit preserves message" (message == "message")
      assert "commit preserves file arguments" (files == [ "src/Main.purs" ])
    _ -> assert "commit parses" false
  case Vcs.parseVcsOp [ "refresh-default-branch" ] of
    Right Vcs.RefreshDefaultBranch -> pure unit
    _ -> assert "refresh-default-branch parses" false
  case Vcs.parseVcsOp [ "fast-forward-if-safe" ] of
    Right Vcs.FastForwardIfSafe -> pure unit
    _ -> assert "fast-forward-if-safe parses" false
