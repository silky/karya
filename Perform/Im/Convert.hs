-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Convert 'Score.Event's to the low-level event format, 'Note.Note'.
module Perform.Im.Convert (write, convert) where
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Vector as Vector

import qualified Util.Log as Log
import qualified Util.Seq as Seq
import qualified Cmd.Cmd as Cmd
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score
import qualified Derive.ScoreTypes as ScoreTypes
import qualified Derive.Stack as Stack

import qualified Instrument.Common as Common
import qualified Instrument.InstTypes as InstTypes
import qualified Perform.ConvertUtil as ConvertUtil
import qualified Perform.Im.Patch as Patch
import qualified Perform.Signal

import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note
import qualified Synth.Shared.Signal as Signal

import           Global
import           Types


-- | Serialize the events to the given patch.  This is done atomically because
-- this is run from the derive thread, which can be killed at any time.
write :: RealTime -> BlockId
    -> (Score.Instrument -> Maybe Cmd.ResolvedInstrument) -> FilePath
    -> Vector.Vector Score.Event -> IO Bool
    -- ^ False if the file would have been the same as an existing one.
write play_multiplier block_id lookup_inst filename events = do
    notes <- LEvent.write_logs $ convert block_id lookup_inst $
        Vector.toList events
    -- The so-called play multiplier is actually a divider.
    Note.serialize filename $ multiply_time (1/play_multiplier) notes

multiply_time :: RealTime -> [Note.Note] -> [Note.Note]
multiply_time n
    | n == 1 = id
    | otherwise = map $ \note -> note
        { Note.start = n * Note.start note
        , Note.duration = n * Note.duration note
        , Note.controls = Signal.map_x (*n) <$> Note.controls note
        }

convert :: BlockId -> (Score.Instrument -> Maybe Cmd.ResolvedInstrument)
    -> [Score.Event] -> [LEvent.LEvent Note.Note]
convert block_id = ConvertUtil.convert $ \event resolved ->
    case Cmd.inst_backend resolved of
        Just (Cmd.Im patch) -> convert_event block_id event patch patch_name
            where InstTypes.Qualified _ patch_name = Cmd.inst_qualified resolved
        _ -> []

convert_event :: BlockId -> Score.Event -> Patch.Patch -> InstTypes.Name
    -> [LEvent.LEvent Note.Note]
convert_event block_id event patch patch_name = run $ do
    let supported = Patch.patch_controls patch
    let controls = Score.event_controls event
    pitch <- if Map.member Control.pitch supported
        then Just . convert_signal <$> convert_pitch event
        else return Nothing
    return $ Note.Note
        { patch = patch_name
        , instrument = ScoreTypes.instrument_name (Score.event_instrument event)
        , trackId = event_track_id block_id event
        , element = fromMaybe "" $ Env.maybe_val EnvKey.patch_element $
            Score.event_environ event
        , start = Score.event_start event
        , duration = Score.event_duration event
        , controls = maybe id (Map.insert Control.pitch) pitch $
            convert_controls supported controls
        -- Restrict attributes to the ones it says it accepts, to protect
        -- against false advertising.
        , attributes = maybe mempty fst $
            Common.lookup_attributes (Score.event_attributes event)
                (Patch.patch_attribute_map patch)
        }

-- | The event TrackId is later used to display render progress.  Progress is
-- only displayed on the root block, so find its tracks.  The innermost track
-- is most likely to be the one with the notes on it.
event_track_id :: BlockId -> Score.Event -> Maybe TrackId
event_track_id block_id = Seq.last <=< lookup block_id . Stack.block_tracks_of
    . Score.event_stack

run :: Log.LogId a -> [LEvent.LEvent a]
run action = LEvent.Event note : map LEvent.Log logs
    where (note, logs) = Log.run_id action

convert_signal :: Perform.Signal.Signal a -> Signal.Signal
convert_signal = Perform.Signal.coerce

-- TODO trim controls?
convert_controls :: Map Control.Control a -> Score.ControlMap
    -> Map Control.Control Signal.Signal
convert_controls supported controls = Map.fromList
    [ (to_control c, convert_signal sig)
    | (c, ScoreTypes.Typed _ sig) <- Map.toList controls
    , Map.member (to_control c) supported
    ]

to_control :: ScoreTypes.Control -> Control.Control
to_control = Control.Control . ScoreTypes.control_name

convert_pitch :: Log.LogMonad m => Score.Event -> m Perform.Signal.NoteNumber
convert_pitch event = do
    let (sig, warns) = Score.nn_signal event
    unless (null warns) $ Log.warn $
        "convert pitch: " <> Text.intercalate ", " (map pretty warns)
    return sig
