-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.C.Idiom.String_test where
import qualified Util.Num as Num
import qualified Derive.DeriveT as DeriveT
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.EnvKey as EnvKey
import qualified Derive.PSignal as PSignal
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal

import qualified Perform.NN as NN
import qualified Perform.Pitch as Pitch
import qualified Ui.UiTest as UiTest

import           Global
import           Types
import           Util.Test


test_attack_release :: Test
test_attack_release = do
    let run = run_string e_nns "bent-string 2 2 1" . UiTest.note_track
    let track p1 p2 p3 = [(0, 5, p1), (5, 5, p2), (10, 5, p3)]

    let (res, logs) = run $ track "4c" "2d" "2e"
    equal res [(0, [(0, NN.c4), (8, NN.c4)])]
    strings_like logs ["below lowest string: 38nn", "below lowest string: 40nn"]
    -- All separate strings doesn't do anything interesting.
    equal (run $ track "4c" "4d" "4e")
        ([(0, [(0, NN.c4), (8, NN.c4)])
        , (5, [(5, 62), (13, 62)])
        , (10, [(10, 64), (18, 64)])
        ], [])
    equal (run $ track "4c" "4c#" "4d")
        ( [ (0, [(0, 60), (3, 60), (5, 61)]) -- bend up for attack
          , (5, [(5, 61), (11, 61), (13, 60)]) -- bend back down for release
          , (10, [(10, NN.d4), (18, NN.d4)])
          ]
        , []
        )
    strings_like (snd $ DeriveTest.extract id $ DeriveTest.derive_tracks
            "import idiom.string | bent-string" [(">", [(0, 1, "")])])
        ["open-strings required"]

    -- Notes closer than the transition time still play properly.
    equal (run [(1, 1, "4d"), (2, 1, "4d")])
        ([(1, [(1, 62), (2, 62)]), (2, [(2, 62), (6, 62)])], [])

test_string_select :: Test
test_string_select = do
    let run = run_string extract "bent-string 0 0 1"
        extract e = (e_string e, e_nns e)
    equal (run $ UiTest.note_track [(0, 1, "4c")])
        ([("0", (0, [(0, NN.c4), (2, NN.c4)]))], [])
    equal (run $ UiTest.note_track [(0, 1, "4d")])
        ([("1", (0, [(0, NN.d4), (2, NN.d4)]))], [])
    -- The string is assigned based on the lowest pitch.
    equal (run [(">", [(0, 2, "")]), ("*", [(0, 0, "4d"), (1, 0, "4c")])])
        ([("0", (0, [(0, NN.d4), (1, NN.d4), (1, NN.c4), (3, NN.c4)]))], [])


-- TODO I have to test this ad-hoc per call until I figure out a better
-- solution, see NOTE [signal-discontinuity]
test_signal_discontinuity :: Test
test_signal_discontinuity = do
    let run = DeriveTest.extract DeriveTest.e_nns
            . DeriveTest.derive_tracks (title <> " | bent-string 0 0 1")
    equal (run [(">", [(0, 2, "")]), ("*", [(0, 0, "4c"), (1, 0, "4d")])])
        ([[(0, NN.c4), (1, NN.c4), (1, NN.d4), (3, NN.d4), (3, NN.c4)]], [])

test_mute_end :: Test
test_mute_end = do
    let run args = run_string extract ("mute-end " <> args) . UiTest.note_track
        extract e = (DeriveTest.e_start_dur e, Score.initial_dynamic e,
            DeriveTest.e_attributes e)
    equal (run "1 1 .5" [(0, 1, "3c")])
        ([((0, 1), 1, "+"), ((1, 1), 0.5, "+"), ((2, 0), 1, "+mute")], [])
    equal (run "1 1 .5" [(0, 1, "+ring -- 3c")])
        ([((0, 1), 1, "+ring")], [])
    equal (run "1 0 .5" [(0, 1, "3c")])
        ([((0, 1), 1, "+"), ((1, 0), 1, "+mute")], [])

test_gliss :: Test
test_gliss = do
    let run gliss dest = DeriveTest.extract Score.initial_nn $
            DeriveTest.derive_tracks title
            [ ("> | scale=twelve-r | key=g-maj", [(4, 1, gliss)])
            , ("*", [(4, 0, dest)])
            ]
    -- Pitches are correct for relative scale.
    equal (run "gliss -1 1" "4s") ([Just NN.e4, Just NN.g4], [])

test_gliss_a :: Test
test_gliss_a = do
    let run gliss dest = DeriveTest.extract extract $
            DeriveTest.derive_tracks title
            [(">", [(4, 1, gliss)]), ("*", [(4, 0, dest)])]
        extract e = (DeriveTest.e_note e, Score.initial_dynamic e)
    equal (run "gliss-a 2 1 .5" "4f")
        ([((3, 0.5, "4a"), 0.5), ((3.5, 0.5, "4g"), 0.75), ((4, 1, "4f"), 1)],
            [])
    equal (run "gliss-a -2 1" "4f")
        ([((3, 0.5, "4d"), 1), ((3.5, 0.5, "4e"), 1), ((4, 1, "4f"), 1)], [])
    equal (run "gliss-a 2 1" "4d")
        ([((3, 0.5, "4g"), 1), ((3.5, 0.5, "4e"), 1), ((4, 1, "4d"), 1)], [])

    let run2 gliss dest = DeriveTest.extract Score.event_start $
            DeriveTest.derive_tracks title
            [ ("tempo", [(0, 0, "1"), (2, 0, "2")]), (">", [(4, 1, gliss)])
            , ("*", [(4, 0, dest)])
            ]
    -- 0   1   2   3   4
    -- 0   1   2   2.5 3
    equal (run2 "gliss-a 2 1t" "4f") ([2.5, 2.75, 3], [])
    equal (run2 "gliss-a 2 1s" "4f") ([2, 2.5, 3], [])

test_nth_harmonic :: Test
test_nth_harmonic = do
    let run call pitch = DeriveTest.extract DeriveTest.e_nn_rounded $
            DeriveTest.derive_tracks title $
            UiTest.note_track [(0, 1, call <> " -- " <> pitch)]
    strings_like (snd $ run "on 0" "4c") ["expected Signal (>0)"]
    equal (run "string=(4c) | on 1" "4c") ([NN.c4], [])
    equal (run "string=(4c) | on 2" "4c") ([NN.c5], [])
    equal (run "string=(4c) | on 3" "4c") ([harmonic 3 NN.c4], [])

test_harmonic :: Test
test_harmonic = do
    let run call pitch = DeriveTest.extract extract $
            DeriveTest.derive_tracks
                "import idiom.string | open-strings = (list (4c) (5c))" $
            UiTest.note_track [(0, 1, call <> " -- " <> pitch)]
        extract e = (DeriveTest.e_nn_rounded e, e_string e)
    -- Pick the harmonic, even though an open string is available.
    equal (run "o" "5c") ([(harmonic 2 NN.c4, "4c")], [])
    -- 1st harmonic not allowed unless I say so.
    strings_like (snd $ run "o" "4c") ["can't find"]
    equal (run "harmonic-h1=t | o" "4c") ([(NN.c4, "4c")], [])

    -- Pick lowest harmonic.
    equal (run "o" "6c") ([(harmonic 2 NN.c5, "5c")], [])
    equal (run "o" "5g") ([(harmonic 3 NN.c4, "4c")], [])
    -- Unless I force a string.
    equal (run "string=(4c) | o" "6c") ([(harmonic 4 NN.c4, "4c")], [])

harmonic :: Int -> Pitch.NoteNumber -> Pitch.NoteNumber
harmonic n = Num.roundDigits 2 . Pitch.modify_hz (* fromIntegral n)

e_string :: Score.Event -> Text
e_string = maybe "" show_val . DeriveTest.e_environ_val EnvKey.string

show_val :: DeriveT.Val -> Text
show_val (DeriveT.VPitch pitch) = show_pitch pitch
show_val val = ShowVal.show_val val

show_pitch :: PSignal.Pitch -> Text
show_pitch = either pretty Pitch.note_text . PSignal.pitch_note . PSignal.coerce

run_string :: (Score.Event -> a) -> Text -> [UiTest.TrackSpec] -> ([a], [Text])
run_string extract call =
    DeriveTest.extract extract
        . DeriveTest.derive_tracks (title <> " | " <> call)

title :: Text
title = "import idiom.string | open-strings = (list (4c) (4d) (4e) (4g) (4a))"

e_nns :: Score.Event -> (RealTime, [(RealTime, Pitch.NoteNumber)])
e_nns e = (Score.event_start e, strip_flat $ DeriveTest.e_nns e)
    -- 'merge_curve' can't see that pitches are the same, so it can produce
    -- duplicate pitches.

strip_flat :: Eq y => [(x, y)] -> [(x, y)]
strip_flat ((x1, y1) : (_, y2) : (x3, y3) : xs)
    | y1 == y2 && y2 == y3 = strip_flat ((x1, y1) : (x3, y3) : xs)
strip_flat (x:xs) = x : strip_flat xs
strip_flat [] = []
