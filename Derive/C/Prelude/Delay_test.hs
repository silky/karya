-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.C.Prelude.Delay_test where
import qualified Derive.DeriveTest as DeriveTest
import qualified Midi.Key as Key
import qualified Midi.Midi as Midi
import qualified Ui.UiTest as UiTest

import           Global
import           Util.Test


test_delay :: Test
test_delay = do
    let run title pref tracks = DeriveTest.extract_events DeriveTest.e_event $
            DeriveTest.derive_tracks "" (tracks ++ [event])
            where
            event = (title, [(0, 1, pref <> "--1"), (1, 1, pref <> "--2")])

    -- delay notes with a delay signal
    let pref = "d %delay | "
    equal (run ">i" pref [("delay", [(0, 0, "1"), (1, 0, "2")])]) $
        [(1, 1, pref <> "--1"), (3, 1, pref <> "--2")]
    equal (run ">i | d 2" "" []) $
        [(2, 1, "--1"), (3, 1, "--2")]
    equal (run ">i | d %delay,2" "" []) $
        [(2, 1, "--1"), (3, 1, "--2")]
    let pref = "d %delay | "
    equal (run ">i" pref [("delay", [(0, 0, "1"), (1, 0, "2")])]) $
        [(1, 1, pref <> "--1"), (3, 1, pref <> "--2")]
    -- delay twice
    equal (run ">i | d %delay,1s | d %delay,1s" "" []) $
        [(2, 1, "--1"), (3, 1, "--2")]

test_delay_inverted :: Test
test_delay_inverted = do
    let run text = extract $ DeriveTest.derive_tracks ""
            [ ("tempo", [(0, 0, "2")])
            , (">i", [(2, 2, text)])
            , ("*twelve", [(0, 0, "4c"), (2, 0, "4d")])
            ]
        extract = DeriveTest.extract_events DeriveTest.e_note
    equal (run "d 2t |") [(2, 1, "4d")]
    equal (run "d .1s |") [(1.1, 1.0, "4d")]

test_echo :: Test
test_echo = do
    let (mmsgs, logs) = perform ("echo 2", [(0, 1, ""), (1, 1, "")])
            [("*", [(0, 0, "4c"), (1, 0, "4d")])]
    equal logs []
    equal (DeriveTest.note_on_vel mmsgs)
        [(0, 60, 127), (1000, 62, 127), (2000, 60, 51), (3000, 62, 51)]

test_event_echo :: Test
test_event_echo = do
    let (mmsgs, logs) = perform
            ("e-echo 2", [(0, 1, ""), (1, 1, "")])
            [("*", [(0, 0, "4c"), (1, 0, "4d")])]
    equal logs []
    equal (DeriveTest.note_on_vel mmsgs)
        [ (0, Key.c4, 127)
        , (1000, Key.d4, 127), (2000, 60, 51), (3000, Key.d4, 51)
        ]

    let (mmsgs, logs) = perform
            ("e-echo %edelay", [(0, 1, ""), (1, 1, "")])
            [ ("*", [(0, 0, "4c"), (1, 0, "4d")])
            , ("edelay", [(0, 0, "2"), (1, 0, "4")])
            , ("e-echo-times", [(0, 0, "1"), (1, 0, "2")])
            ]
    equal logs []
    equal (DeriveTest.note_on_vel mmsgs)
        [ (0, Key.c4, 127), (1000, Key.d4, 127)
        , (2000, Key.c4, 51), (5000, Key.d4, 51), (9000, Key.d4, 20)
        ]

perform :: (Text, [UiTest.EventSpec]) -> [UiTest.TrackSpec]
     -> ([Midi.WriteMessage], [Text])
perform (title, events) tracks = DeriveTest.perform_block $
    tracks ++ [(">i1 | " <> title, events)]
