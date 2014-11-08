-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Cmd.Refactor_test where
import qualified Util.Seq as Seq
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Cmd.CmdTest as CmdTest
import qualified Cmd.Refactor as Refactor


test_selection_alts = do
    let run relative = CmdTest.run_tracks tracks $ do
            CmdTest.set_sel 1 1 1 3
            Refactor.selection_alts relative 3 "sub"
        tracks = UiTest.regular_notes 4
    let result = run True
    equal (CmdTest.result_val result)
        (Right $ Just $ map UiTest.bid ["b1-sub1", "b1-sub2", "b1-sub3"])
    let blocks = UiTest.extract_all_tracks (CmdTest.result_ui_state result)
    equal (Seq.head =<< lookup UiTest.default_block_id blocks)
        (Just (">", [(0, 1, ""), (1, 2, "alt -sub1 -sub2 -sub3"), (3, 1, "")]))

    let result = run False
    equal (CmdTest.result_val result)
        (Right $ Just $ map UiTest.bid ["sub1", "sub2", "sub3"])
    let blocks = UiTest.extract_all_tracks (CmdTest.result_ui_state result)
    equal (Seq.head =<< lookup UiTest.default_block_id blocks)
        (Just (">", [(0, 1, ""), (1, 2, "alt sub1 sub2 sub3"), (3, 1, "")]))

test_selection_at = do
    let run tracks subs start end = UiTest.extract_all_tracks $
            UiTest.exec (UiTest.run_mkblocks (("b", [(">", tracks)]) : subs)) $
                Refactor.selection_at False "sub" parent
                    [1] [UiTest.mk_tid_block parent 1] start end
        parent = UiTest.bid "b"
    equal (run [(0, 1, "a"), (1, 1, "b")] [] 0 1)
        [ (parent, [(">", [(0, 1, "sub"), (1, 1, "b")])])
        , (UiTest.bid "sub", [(">", [(0, 1, "a")])])
        ]
