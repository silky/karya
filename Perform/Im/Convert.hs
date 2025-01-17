-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Convert 'Score.Event's to the low-level event format, 'Note.Note'.
module Perform.Im.Convert (write, convert) where
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Vector as Vector

import qualified Util.Lists as Lists
import qualified Util.Log as Log

import qualified Cmd.Cmd as Cmd
import qualified Derive.DeriveT as DeriveT
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Expr as Expr
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score
import qualified Derive.ScoreT as ScoreT
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Stack as Stack

import qualified Instrument.Common as Common
import qualified Instrument.InstT as InstT
import qualified Perform.ConvertUtil as ConvertUtil
import qualified Perform.Im.Patch as Patch
import qualified Perform.Signal

import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note
import qualified Synth.Shared.Signal as Signal

import           Global
import           Types


-- | Serialize the events to the given path.  This is done atomically because
-- this is run from the derive thread, which can be killed at any time.
write :: RealTime -> RealTime -> BlockId
    -> (ScoreT.Instrument -> Maybe Cmd.ResolvedInstrument) -> FilePath
    -> Vector.Vector Score.Event -> IO ()
write adjust0 play_multiplier block_id lookup_inst filename events = do
    notes <- LEvent.write_logs $ convert block_id lookup_inst $
        -- TODO fix sorted Derive.Stream: so I can remove this.
        Lists.sortOn Score.event_start $
        Vector.toList events
    -- The play multiplier is a speed multiplier, so it's a note time divider.
    Note.serialize filename $ multiply_time adjust0 (1/play_multiplier) $
        map (uncurry trim_controls) $ Lists.zipNexts notes
    return ()

multiply_time :: RealTime -> RealTime -> [Note.Note] -> [Note.Note]
multiply_time adjust0 n
    | n == 1 && adjust0 == 0 = id
    | otherwise = map $ \note -> note
        { Note.start = n * (Note.start note + adjust0)
        , Note.duration = n * Note.duration note
        , Note.controls = Signal.map_x (*n) <$> Note.controls note
        }

-- | Trim signals down to the note ranges.  It's more efficient to serialize
-- fewer samples, and leads to less rerendering since note hashes are based
-- on all their controls, whether or not they're in range.
--
-- Also normalize constant signals to a single sample, fewer bogus breakpoints
-- can make the synthesizer more efficient.
trim_controls :: Note.Note -> [Note.Note] -> Note.Note
trim_controls note nexts =
    note { Note.controls = trim_control note nexts <$> Note.controls note }

trim_control :: Note.Note -> [Note.Note] -> Signal.Signal -> Signal.Signal
trim_control note nexts sig =
    case Signal.constant_val_from (Note.start note) sig of
        Nothing -> case List.find ((== key note) . key) nexts of
            Nothing -> Signal.drop_before (Note.start note) sig
            Just next -> Signal.drop_after (Note.start next) $
                Signal.drop_before (Note.start note) sig
        Just y -> Signal.constant y
    where
    key n = (Note.instrument n, Note.element n)

convert :: BlockId -> (ScoreT.Instrument -> Maybe Cmd.ResolvedInstrument)
    -> [Score.Event] -> [LEvent.LEvent Note.Note]
convert block_id = ConvertUtil.convert $ \event resolved ->
    case Cmd.inst_backend resolved of
        Cmd.Im patch -> convert_event block_id event patch patch_name
            where InstT.Qualified _ patch_name = Cmd.inst_qualified resolved
        _ -> []

convert_event :: BlockId -> Score.Event -> Patch.Patch -> InstT.Name
    -> [LEvent.LEvent Note.Note]
convert_event block_id event patch patch_name = run $ do
    let supported = Patch.patch_controls patch
    let controls = Score.event_controls event
    pitch <- if Map.member Control.pitch supported
        then Just . convert_signal <$> convert_pitch event
        else return Nothing
    return $ Note.Note
        { patch = patch_name
        , instrument = Score.event_instrument event
        , trackId = event_track_id block_id event
        -- To make it easier to set element by hand, I support some types which
        -- are likely to be used for element names.
        , element =
            case Env.lookup EnvKey.element (Score.event_environ event) of
                Just (DeriveT.VStr (Expr.Str a)) -> a
                Just val | Just num <- DeriveT.constant_val val ->
                    ShowVal.show_val num
                _ -> ""
        , start = Score.event_start event
        , duration = Score.event_duration event
        , controls = maybe id (Map.insert Control.pitch) pitch $
            convert_controls supported controls
        -- Restrict attributes to the ones it says it accepts, to protect
        -- against false advertising.
        , attributes = maybe mempty fst $
            Common.lookup_attributes (Score.event_attributes event)
                (Patch.patch_attribute_map patch)
        , stack = Score.event_stack event
        }

-- | The event TrackId is later used to display render progress.  Progress is
-- only displayed on the root block, so find its tracks.  The innermost track
-- is most likely to be the one with the notes on it.
event_track_id :: BlockId -> Score.Event -> Maybe TrackId
event_track_id block_id = Lists.last <=< lookup block_id . Stack.block_tracks_of
    . Score.event_stack

run :: Log.LogId a -> [LEvent.LEvent a]
run action = LEvent.Event note : map LEvent.Log logs
    where (note, logs) = Log.run_id action

convert_signal :: Perform.Signal.Signal a -> Signal.Signal
convert_signal = Perform.Signal.coerce

-- TODO trim controls?
convert_controls :: Map Control.Control a -> DeriveT.ControlMap
    -> Map Control.Control Signal.Signal
convert_controls supported controls = Map.fromList
    [ (to_control c, convert_signal sig)
    | (c, ScoreT.Typed _ sig) <- Map.toList controls
    , Map.member (to_control c) supported
    ]

to_control :: ScoreT.Control -> Control.Control
to_control = Control.Control . ScoreT.control_name

convert_pitch :: Log.LogMonad m => Score.Event -> m Perform.Signal.NoteNumber
convert_pitch event = do
    let (sig, warns) = Score.nn_signal event
    unless (null warns) $ Log.warn $
        "convert pitch: " <> Text.intercalate ", " (map pretty warns)
    return sig
