module Test.Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)

import Agency.Scripts.Do.DoneTest as DoneTest
import Agency.Scripts.Do.ForgeTest as ForgeTest
import Agency.Scripts.Do.StateTest as StateTest
import Agency.Scripts.Do.VcsTest as VcsTest

main :: Effect Unit
main = do
  StateTest.run
  DoneTest.run
  ForgeTest.run
  VcsTest.run
  log "PureScript unit tests passed"
