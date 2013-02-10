module Cmd.Lang.LRuler_test where
import Util.Control
import Util.Test
import qualified Ui.State as State
import qualified Ui.UiTest as UiTest
import qualified Cmd.CmdTest as CmdTest
import qualified Cmd.Create as Create
import qualified Cmd.Lang.LRuler as LRuler
import qualified Cmd.Meter as Meter
import qualified Cmd.RulerUtil as RulerUtil

import Types


test_extract = do
    let ((vid, bid), ui_state) = UiTest.run State.empty $ do
            [top, b1, b2] <- UiTest.mkblocks
                [ ("top", [(">", [(0, 10, "b1"), (10, 6, "b2")])])
                , ("b1", [])
                , ("b2", [])
                ]
            vid <- Create.unfitted_view top
            Create.new_ruler top "r.top" $ RulerUtil.ruler []
            Create.new_ruler b1 "r.b1" $
                RulerUtil.meter_ruler 16 [Meter.repeat 4 Meter.T]
            Create.new_ruler b2 "r.b2" $
                RulerUtil.meter_ruler 16 [Meter.repeat 3 Meter.T]
            return (vid, top)
    equal (e_ruler bid ui_state) []
    res <- CmdTest.run_ui_io ui_state $ do
        CmdTest.set_sel_on vid 1 0 1 0
        LRuler.modify =<< LRuler.extract
    equal (e_ruler bid (CmdTest.result_ui_state res))
        [ (0, 2.5), (1, 2.5), (1, 2.5), (1, 2.5)
        , (1, 2), (1, 2), (1, 2)
        ]

e_ruler :: BlockId -> State.State -> Meter.Meter
e_ruler bid ustate = UiTest.eval ustate $
    Meter.ruler_meter <$> (State.get_ruler =<< State.ruler_of bid)
