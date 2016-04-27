-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for "Derive.Call.India.Solkattu".  This re-exports
-- "Derive.Call.India.SolkattuScore" so I can write korvais there and directly
-- insert them into the score from here.
module Cmd.Repl.LSol (
    module Cmd.Repl.LSol
    , module Derive.Call.India.SolkattuScore
) where
import qualified Data.Text as Text

import qualified Util.Seq as Seq
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.State as State

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Selection as Selection
import qualified Derive.Call.India.Solkattu as Solkattu
import qualified Derive.Call.India.SolkattuDsl as SolkattuDsl
import Derive.Call.India.SolkattuScore

import Types


-- | Replace the contents of the selected track.
replace :: Cmd.M m => TrackTime -> Solkattu.Korvai -> m ()
replace akshara_dur korvai = do
    let stroke_dur = akshara_dur
            / fromIntegral (Solkattu.tala_nadai (Solkattu.korvai_tala korvai))
    events <- realize_korvai stroke_dur korvai
    (_, _, track_id, _) <- Selection.get_insert
    State.modify_events track_id $ const $ events

realize_korvai :: State.M m => TrackTime -> Solkattu.Korvai -> m Events.Events
realize_korvai stroke_dur korvai = do
    strokes <- State.require_right Text.unlines $
        Solkattu.realize_korvai SolkattuDsl.simple_patterns korvai
    return $ Events.from_list
        [ Event.event start 0 (Solkattu.stroke_to_call stroke)
        | (start, Just stroke) <- zip (Seq.range_ 0 stroke_dur) strokes
        ]
