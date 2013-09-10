-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Cmd.MidiThru_test where
import qualified Util.Seq as Seq
import Util.Test
import qualified Midi.Midi as Midi
import qualified Cmd.Cmd as Cmd
import qualified Cmd.CmdTest as CmdTest
import Cmd.CmdTest (note_off, control)
import qualified Cmd.InputNote as InputNote
import qualified Cmd.MidiThru as MidiThru

import qualified Perform.Midi.Instrument as Instrument


test_input_to_midi = do
    let wdev = Midi.write_device "wdev"
        addrs = [(wdev, 0), (wdev, 1), (wdev, 2)]
    let f = map (extract_msg . snd) . fst
            . thread_inputs addrs Cmd.empty_wdev_state
    let pitch = CmdTest.pitch_change_nn
        note_on = CmdTest.note_on_nn

    -- orphan controls are ignored
    equal (f [control 1 "cc1" 127, pitch 1 64]) []

    -- redundant and unrelated pitch_changes filtered
    equal (f [note_on 64, pitch 1 65, pitch 64 63,
            pitch 64 1, pitch 64 1])
        [ (0, Midi.NoteOn 64 127)
        , (0, Midi.PitchBend (-0.5))
        , (0, Midi.PitchBend (-1))
        ]

    -- null addrs discards msgs
    equal (thread_inputs [] Cmd.empty_wdev_state [note_on 1])
        ([], Cmd.empty_wdev_state)

    -- round-robin works
    equal (f (map note_on (Seq.range 1 6 1)))
        [(chan, Midi.NoteOn n 127) | (chan, n) <- zip (cycle [0..2]) [1..6]]

    -- note off lets channel 2 be reused
    equal (f [note_on 1, note_on 2, note_on 3, note_off 3, note_on 4])
        [ (0, Midi.NoteOn 1 127), (1, Midi.NoteOn 2 127)
        , (2, Midi.NoteOn 3 127), (2, Midi.NoteOff 3 127)
        , (2, Midi.NoteOn 4 127)
        ]

    -- once assigned a note_id, controls get mapped to that channel
    equal (f [note_on 64, note_on 66, control 64 "mod" 1,
            control 66 "breath" 0.5])
        [ (0, Midi.NoteOn 64 127), (1, Midi.NoteOn 66 127)
        , (0, Midi.ControlChange 1 127), (1, Midi.ControlChange 2 63)
        ]


extract_msg :: Midi.Message -> (Midi.Channel, Midi.ChannelMessage)
extract_msg (Midi.ChannelMessage chan msg) = (chan, msg)
extract_msg msg = error $ "bad msg: " ++ show msg

thread_inputs :: [Instrument.Addr] -> Cmd.WriteDeviceState -> [InputNote.Input]
    -> ([(Midi.WriteDevice, Midi.Message)], Cmd.WriteDeviceState)
thread_inputs addrs initial_state inputs = foldl go ([], initial_state) inputs
    where
    go (prev_msgs, state) input = case next_state of
            Nothing -> (next_msgs, state)
            Just next_state -> (next_msgs, next_state)
        where
        (msgs, next_state) = MidiThru.input_to_midi (-2, 2) state addrs
            (convert_input input)
        next_msgs = prev_msgs ++ msgs

convert_input :: InputNote.Input -> InputNote.InputNn
convert_input input = case input of
    InputNote.NoteOn note_id input vel ->
        InputNote.NoteOn note_id (InputNote.input_to_nn input) vel
    InputNote.PitchChange note_id input ->
        InputNote.PitchChange note_id (InputNote.input_to_nn input)
    InputNote.NoteOff note_id vel -> InputNote.NoteOff note_id vel
    InputNote.Control note_id control val ->
        InputNote.Control note_id control val
