module Agency.Scripts.Do.Cli
  ( main
  , dispatch
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect (Effect)

import Agency.Scripts.Do.Forge as Forge
import Agency.Scripts.Do.Ops as Ops
import Agency.Scripts.Do.Sys as Sys
import Agency.Scripts.Do.Vcs as Vcs

-- | Dispatch the legacy script name in argv[0] to its PureScript runner.
dispatch :: Array String -> Effect Int
dispatch args = case Array.uncons args of
  Nothing -> do
    Sys.stderrWrite "agency-do: no script given\nAvailable: vcs-op, forge-op, do-results, do-driver, sync, done, nickel-cli\n"
    pure 1
  Just { head: script, tail: rest } -> case script of
    "vcs-op" -> dispatchVcs rest
    "forge-op" -> dispatchForge rest
    "do-results" -> dispatchResults rest
    "do-driver" -> dispatchDriver rest
    "sync" -> dispatchSync rest
    "done" -> dispatchDone rest
    "nickel-cli" -> dispatchNickel rest
    _ -> do
      Sys.stderrWrite ("agency-do: unknown script '" <> script <> "'\nAvailable: vcs-op, forge-op, do-results, do-driver, sync, done, nickel-cli\n")
      pure 1

main :: Effect Unit
main = do
  args <- Sys.argv
  code <- dispatch args
  if code == 0 then pure unit else Sys.exit code

dispatchVcs :: Array String -> Effect Int
dispatchVcs args = case Vcs.parseVcsOp args of
  Left message -> do
    Sys.stderrWrite (message <> "\n")
    pure 1
  Right operation -> Vcs.runVcsOp operation

dispatchForge :: Array String -> Effect Int
dispatchForge args = case Forge.parseForgeOp args of
  Left message -> do
    Sys.stderrWrite (message <> "\n")
    pure 1
  Right operation -> Forge.runForgeOp operation

dispatchResults :: Array String -> Effect Int
dispatchResults args = runParsed (Ops.parseResultsOp args) Ops.runResultsOp

dispatchDriver :: Array String -> Effect Int
dispatchDriver args = runParsed (Ops.parseDriverOp args) Ops.runDriverOp

dispatchSync :: Array String -> Effect Int
dispatchSync args = runParsed (Ops.parseSyncOp args) Ops.runSyncOp

dispatchDone :: Array String -> Effect Int
dispatchDone args = runParsed (Ops.parseDoneOp args) Ops.runDoneOp

dispatchNickel :: Array String -> Effect Int
dispatchNickel args = runParsed (Ops.parseNickelOp args) Ops.runNickelOp

runParsed :: forall a. Either Ops.ParseError a -> (a -> Effect Int) -> Effect Int
runParsed parsed runner = case parsed of
  Left error -> do
    Sys.stderrWrite (error.message <> "\n")
    pure error.code
  Right operation -> runner operation
