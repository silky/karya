-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Cmd.PlayUtil_test where
import qualified Data.Map as Map

import Util.Test
import qualified Midi.Key as Key
import qualified Midi.Midi as Midi
import qualified Ui.State as State
import qualified Ui.UiTest as UiTest
import qualified Cmd.Cmd as Cmd
import qualified Cmd.CmdTest as CmdTest
import qualified Cmd.Performance as Performance
import qualified Cmd.PlayUtil as PlayUtil

import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.LEvent as LEvent
import qualified Perform.Midi.Patch as Patch
import Global
import Types


test_control_defaults = do
    let make = (State.allocation UiTest.i1 #= Just alloc)
            . CmdTest.make_tracks . UiTest.inst_note_track
        alloc = UiTest.midi_allocation "s/1" $
            Patch.control_defaults #= Map.fromList [("cc17", 0.5)] $
            Patch.config [(UiTest.wdev, 0)]
        extract = first $ fmap (map snd . DeriveTest.midi_channel)
    let run state = extract $ perform_events state UiTest.default_block_id
    let (midi, logs) = run $ make ("i1", [(0, 1, "4c")])
    equal logs []
    equal midi $
        Right [Midi.ControlChange 17 64, Midi.NoteOn Key.c4 127,
            Midi.NoteOff Key.c4 127]
    -- Default controls won't override an existing one.
    let (midi, logs) = run $ make ("i1 | %cc17=0", [(0, 1, "4c")])
    equal logs []
    equal midi $
        Right [Midi.ControlChange 17 0, Midi.NoteOn Key.c4 127,
            Midi.NoteOff Key.c4 127]

perform_events :: State.State -> BlockId
    -> (Either String [Midi.WriteMessage], [Text])
perform_events ui_state block_id =
    (midi, mapMaybe DeriveTest.show_interesting_log all_logs)
    where
    (midi, midi_logs) = case CmdTest.result_ok result of
        Right events -> first Right $ LEvent.partition events
        Left err -> (Left err, [])
    all_logs = Cmd.perf_logs perf ++ logs ++ CmdTest.result_logs result
        ++ midi_logs
    result = CmdTest.run ui_state cmd_state $
        PlayUtil.perform_events (Cmd.perf_events perf)
    (perf, logs) = Performance.derive ui_state cmd_state block_id
    cmd_state = CmdTest.default_cmd_state
