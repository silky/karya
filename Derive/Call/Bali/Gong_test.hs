-- Copyright 2015 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.Bali.Gong_test where
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.DeriveTest as DeriveTest
import Global


test_jegog = do
    let title = "import bali.gong | jegog-insts = (list >i1) | scale=legong"
            <> " | cancel"
    let run = DeriveTest.extract extract
            . DeriveTest.derive_tracks title . UiTest.note_track
        extract e = (s, d, p, DeriveTest.e_inst e)
            where (s, d, p) = DeriveTest.e_note e
        jegog = "i1"
    equal (run [(0, 1, "J | -- 3i")])
        ([(0, 1, "3i", ""), (0, 1, "1i", jegog)], [])
    -- Duration is until the next jegog note.
    equal (run [(0, 1, "J | -- 3o"), (1, 1, "3e"), (2, 1, "J | -- 3u")])
        ([ (0, 1, "3o", ""), (0, 2, "1o", jegog)
         , (1, 1, "3e", "")
         , (2, 1, "3u", ""), (2, 1, "1u", jegog)
         ], [])