-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.Bali.Gender_test where
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Score as Score


transform :: String
transform = "import bali.gender | realize-ngoret"

test_ngoret_standalone = do
    let run = DeriveTest.extract DeriveTest.e_note
            . DeriveTest.derive_tracks transform . UiTest.note_track
    equal (run [(0, 1, "4c"), (1, 0, "'- .5 .5 --"), (2, 1, "4e")])
        ([(0, 2.5, "4c"), (1.5, 1, "4d"), (2, 1, "4e")], [])

    -- The grace note goes at the midpoint if there isn't enough time.
    equal (run [(0, 1, "4c"), (1, 0, "'- 10 .5 --"), (2, 1, "4e")])
        ([(0, 2.5, "4c"), (1, 1.5, "4d"), (2, 1, "4e")], [])

    -- Short note doesn't get extended.
    equal (run [(0, 0.5, "4c"), (1, 0, "'- 1 .5 --"), (2, 1, "4e")])
        ([(0, 0.5, "4c"), (1, 1.5, "4d"), (2, 1, "4e")], [])

    -- Trailing ngoret is an error.
    equal (run [(0, 0.5, "4c"), (1, 0, "'- 1 .5 --")])
        ([(0, 0.5, "4c")], ["no next event"])

test_ngoret = do
    -- This also tests some error checking and absolute warp functions.
    let run_e extract = DeriveTest.extract extract
            . DeriveTest.derive_tracks_linear transform
        run = run_e DeriveTest.e_note
    let c_to_e evt1 evt2 =
            [ (">", [(0, 1, evt1), (2, 1, evt2)])
            , ("*", [(0, 0, "4c"), (2, 0, "4e")])
            ]

    strings_like (snd $ run $ c_to_e "'" "'") ["no previous"]
    -- Starting at 0 will emit an event at negative time.
    -- Thanks to the "x <= 0 means constant" hack the pitch is accurate even
    -- though TimeVector.constant starts it at 0.
    equal (run $ UiTest.note_track [(0, 1, "'^ .5 .5 -- 4d")])
        ([(-0.5, 1, "4c"), (0, 1, "4d")], [])

    -- Negative start time works when tempo is non-trivial.
    equal (run $ ("tempo", [(0, 0, "1"), (8, 0, "2")])
            : UiTest.note_track [(0, 1, "'^ .5 .5 -- 4d")])
        ([(-0.5, 1, "4c"), (0, 1, "4d")], [])

    -- Ngoret is a constant time before second note regardless of tempo.
    -- And dyn works.
    let e_dyn e = (DeriveTest.e_note e, Score.initial_dynamic e)
    let (evts, logs) = run_e e_dyn $
            ("tempo", [(0, 0, ".5")]) : c_to_e "" "' .5 .5"
    equal logs []
    equal evts
        [ ((0, 2, "4c"), 1)
        , ((3.5, 1, "4d"), 0.75)
        , ((4, 2, "4e"), 1)
        ]

    -- ngoret damp time doesn't go past second note
    equal (run $ c_to_e "" "' .5 5")
        ([(0, 1, "4c"), (1.5, 1.5, "4d"), (2, 1, "4e")], [])

    -- If it doesn't have room for the requested duration it will go halfway
    -- between the two notes
    equal (run $ c_to_e "" "' 10 1")
        ([(0, 1, "4c"), (1, 2, "4d"), (2, 1, "4e")], [])

    -- Works when not inverted as well.
    equal (run
            [ ("*", [(0, 0, "4c"), (2, 0, "4e")])
            , (">", [(0, 1, ""), (2, 1, "' .5 1 1")])
            ])
        ([(0, 1, "4c"), (1.5, 1.5, "4d"), (2, 1, "4e")], [])

    -- Explicit down ngoret.
    equal (run $ c_to_e "" "'_ .5 .5 1")
        ([(0, 1, "4c"), (1.5, 1, "4f"), (2, 1, "4e")], [])

test_ngoret_infer_duration = do
    let run = DeriveTest.extract DeriveTest.e_note . DeriveTest.derive_blocks
        top = "top -- " ++ transform ++ " | realize-ngoret | infer-duration"
    -- This also tests the interaction between the default note deriver and
    -- infer-duration, when invoked via Util.note.
    equal (run
            [ (top, [(">", [(0, 1, "sub"), (1, 1, "sub")])])
            , ("sub=ruler", UiTest.note_track
                [(0, 1, "4c"), (1, 0, "' .5 .5 -- 4e")])
            ])
        ([(0, 1.5, "4c"), (0.5, 1, "4d"), (1, 1.5, "4e"), (1.5, 1, "4d"),
            (2, 1, "4e")], [])
    --    sub      sub
    --    4c    '4e|4c      '4e|
    -- 4c ------------
    -- 4d       ------      ------
    -- 4e           --------------
    -- 4e                      ------
    --
    -- TODO Notice that 4e overlaps itself.  To fix this, I need restrikes
    -- to shorten the original.

test_ngoret_transpose = do
    let run = DeriveTest.extract DeriveTest.e_pitch
            . DeriveTest.derive_tracks (transform ++ " | %t-dia=7")
            . UiTest.note_track
    -- Make sure the transposition doesn't get applied twice.
    equal (run [(0, 1, "4c"), (1, 1, "' .5 .5 -- 4e")])
        (["5c", "5d", "5e"], [])

test_realize_damp = do
    let run = DeriveTest.extract DeriveTest.e_note
            . DeriveTest.derive_tracks transform . UiTest.note_track
    -- First note is extended.
    equal (run [(0, 2, "4c"), (2, 1, "' .5 .5 -- 4e")])
        ([(0, 2.5, "4c"), (1.5, 1, "4d"), (2, 1, "4e")], [])

    -- But not if it has a rest.
    equal (run [(0, 1, "4c"), (2, 1, "' .5 .5 -- 4e")])
        ([(0, 1, "4c"), (1.5, 1, "4d"), (2, 1, "4e")], [])
