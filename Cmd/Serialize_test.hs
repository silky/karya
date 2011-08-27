module Cmd.Serialize_test where
import qualified Util.Serialize
import Util.Test

import Ui

import qualified Ui.UiTest as UiTest
import qualified Ui.State as State
import qualified Cmd.Serialize as Serialize


test_serialize = do
    let (_, ustate) =
            UiTest.run_mkview [("track", [(0, 1, "e0"), (1, 1, "e1")])]
    save_state <- Serialize.save_state ustate
    let run f = (f save_state, recode (f save_state))

    uncurry equal $ run (State.state_config . Serialize.save_ui_state)
    uncurry equal $ run (State.state_views . Serialize.save_ui_state)
    uncurry equal $ run (State.state_blocks . Serialize.save_ui_state)
    uncurry equal $ run (State.state_tracks . Serialize.save_ui_state)
    uncurry equal $ run (State.state_rulers . Serialize.save_ui_state)

test_negative_zero = do
    -- make sure negative zero is encoded properly
    equal (recode (0 :: ScoreTime)) 0
    equal (recode (-0 :: ScoreTime)) (-0.0)

recode :: (Util.Serialize.Serialize a) => a -> a
recode = either error id . Util.Serialize.decode . Util.Serialize.encode
