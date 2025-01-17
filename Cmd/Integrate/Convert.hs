-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
-- | The 'convert' function and support.
module Cmd.Integrate.Convert (
    Track(..), Tracks
    , convert
#ifdef TESTING
    , module Cmd.Integrate.Convert
#endif
) where
import qualified Data.Either as Either
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import qualified Util.Lists as Lists
import qualified Util.Log as Log
import qualified Util.Pretty as Pretty
import qualified Util.Texts as Texts

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Perf as Perf
import qualified Derive.Call as Call
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Expr as Expr
import qualified Derive.PSignal as PSignal
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.Score as Score
import qualified Derive.ScoreT as ScoreT
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Stack as Stack
import qualified Derive.Stream as Stream

import qualified Instrument.Common as Common
import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import qualified Ui.Event as Event
import qualified Ui.Ui as Ui

import           Global
import           Types


-- | Include flags as a comment in generated events, for debugging.  It
-- clutters the output though.  TODO: need a better way
debug :: Bool
debug = False

type Error = Text
type Title = Text

-- | A simplified description of a UI track, as collected by
-- "Derive.Call.Integrate".
data Track = Track {
    track_title :: !Title
    , track_events :: ![Event.Event]
    } deriving (Eq, Show)

instance Pretty Track where
    format (Track title events) = Pretty.record "Track"
        [ ("title", Pretty.format title)
        , ("events", Pretty.format events)
        ]

-- | (note track, control tracks)
type Tracks = [(Track, [Track])]
type Config = (GetCallMap, Pitch.ScaleId)
type GetCallMap = ScoreT.Instrument -> Common.CallMap

-- | Convert 'Score.Event's to 'Tracks'.  This involves splitting overlapping
-- events into tracks, and trying to map low level notation back to high level.
convert :: Cmd.M m => BlockId -> Stream.Stream Score.Event -> m Tracks
convert source_block stream = do
    lookup_inst <- Cmd.get_lookup_instrument
    let get_call_map = maybe mempty (Common.common_call_map . Cmd.inst_common)
            . lookup_inst
    default_scale_id <- Perf.default_scale_id
    tracknums <- Map.fromList <$> Ui.tracknums_of source_block
    let (events, logs) = Stream.partition stream
        (errs, tracks) = integrate (get_call_map, default_scale_id)
            tracknums events
    mapM_ (Log.write . Log.add_prefix "integrate") logs
    -- If something failed to derive I shouldn't integrate that into the block.
    when (any ((>=Log.Warn) . Log.msg_priority) logs) $
        Cmd.throw "aborting integrate due to warnings"
    unless (null errs) $
        Cmd.throw $ "integrating events: " <> Text.intercalate "; " errs
    return tracks

-- | Convert derived score events back into UI events.
integrate :: Config -> Map TrackId TrackNum -> [Score.Event]
    -> ([Error], Tracks)
integrate config tracknums =
    Either.partitionEithers . map (integrate_track config)
    . allocate_tracks tracknums

-- | Allocate the events to separate tracks.
allocate_tracks :: Map TrackId TrackNum -> [Score.Event]
    -> [(TrackKey, [Score.Event])]
allocate_tracks tracknums = concatMap overlap . Lists.keyedGroupSort group_key
    where
    overlap (key, events) = map ((,) key) (split_overlapping events)
    -- Sort by tracknum so an integrated block's tracks come out in the same
    -- order as the original.
    group_key :: Score.Event -> TrackKey
    group_key event =
        ( tracknum_of =<< track_of event
        , Score.event_instrument event
        , PSignal.sig_scale_id (Score.event_pitch event)
        , event_voice event
        , event_hand event
        )
    tracknum_of tid = Map.lookup tid tracknums

-- | Split events into separate lists of non-overlapping events.
split_overlapping :: [Score.Event] -> [[Score.Event]]
split_overlapping [] = []
split_overlapping events = track : split_overlapping rest
    where
    -- Go through the track and collect non-overlapping events, then do it
    -- recursively until there are none left.
    (track, rest) = Either.partitionEithers (strip events)
    strip [] = []
    strip (event:events) = Left event : map Right overlapping ++ strip rest
        where (overlapping, rest) = span (overlaps event) events

overlaps :: Score.Event -> Score.Event -> Bool
overlaps e1 e2 = Score.event_start e2 < Score.event_end e1
    || Score.event_start e1 == Score.event_start e2

event_voice :: Score.Event -> Maybe Voice
event_voice = Env.maybe_val EnvKey.voice . Score.event_environ

event_hand :: Score.Event -> Maybe Call.Hand
event_hand = Env.maybe_val EnvKey.hand . Score.event_environ

track_of :: Score.Event -> Maybe TrackId
track_of = Lists.head . mapMaybe Stack.track_of . Stack.innermost
    . Score.event_stack

-- | This determines how tracks are split when integration recreates track
-- structure.
type TrackKey =
    ( Maybe TrackNum, ScoreT.Instrument, Pitch.ScaleId
    , Maybe Voice, Maybe Call.Hand
    )
type Voice = Int

integrate_track :: Config -> (TrackKey, [Score.Event])
    -> Either Error (Track, [Track])
integrate_track (get_call_map, default_scale_id)
        ((_, inst, scale_id, voice, hand), events) = do
    pitch_track <- if no_pitch_signals events || no_scale
        then return []
        else case pitch_events sid $ events of
            (track, []) -> return [track]
            (_, errs) -> Left $ Text.intercalate "; " errs
    return
        ( note_events inst (voice, hand) (get_call_map inst) events
        , pitch_track ++ control_events events
        )
    where
    -- Instruments like mridangam '(natural)' call use this for ambient pitch.
    no_scale = scale_id == PSignal.pscale_scale_id PSignal.no_scale
    sid = if scale_id == default_scale_id then Pitch.empty_scale else scale_id

-- ** note

note_events :: ScoreT.Instrument -> (Maybe Voice, Maybe Call.Hand)
    -> Common.CallMap -> [Score.Event] -> Track
note_events inst (voice, hand) call_map events =
    make_track note_title (map (note_event call_map) events)
    where
    note_title = Text.intercalate " | " $ filter (/="")
        [ ParseTitle.instrument_to_title inst
        , add_env EnvKey.voice voice
        , add_env EnvKey.hand hand
        ]
    add_env key = maybe "" (((key <> "=")<>) . ShowVal.show_val)

note_event :: Common.CallMap -> Score.Event -> Event.Event
note_event call_map event =
    ui_event (Score.event_stack event)
        (RealTime.to_score (Score.event_start event))
        (RealTime.to_score (Score.event_duration event))
        (note_call call_map event)

note_call :: Common.CallMap -> Score.Event -> Text
note_call call_map event = Texts.join2 " -- " text comment
    where
    text
        | Score.event_integrate event /= "" = Score.event_integrate event
        | Just sym <- Map.lookup attrs call_map = Expr.unsym sym
        | attrs /= mempty = ShowVal.show_val attrs
        | otherwise = ""
        where attrs = Score.event_attributes event
    -- Append flags to help with debugging.  The presence of a flag
    -- probably means some postproc step wasn't applied.
    comment
        | debug && flags /= mempty = pretty flags
        | otherwise = ""
        where flags = Score.event_flags event


-- ** pitch

-- | Unlike 'control_events', this only drops dups that occur within the same
-- event.  This is because it's more normal to think of each note as
-- establishing a new pitch, even if it's the same as the last one.
pitch_events :: Pitch.ScaleId -> [Score.Event] -> (Track, [Error])
pitch_events scale_id events =
    (make_track pitch_title (tidy_pitches ui_events), concat errs)
    where
    pitch_title = ParseTitle.scale_to_title scale_id
    (ui_events, errs) = unzip $ map pitch_signal_events events
    tidy_pitches = clip_to_zero . clip_concat . map drop_dups

no_pitch_signals :: [Score.Event] -> Bool
no_pitch_signals = all (PSignal.null . Score.event_pitch)

-- | Convert an event's pitch signal to symbolic note names.  This uses
-- 'PSignal.pitch_note', which handles a constant transposition, but not
-- continuous pitch changes (it's not even clear how to spell those).  I could
-- try to convert back from NoteNumbers, but I still have the problem of how
-- to convert the curve back to high level pitches.
pitch_signal_events :: Score.Event -> ([Event.Event], [Error])
pitch_signal_events event = (ui_events, pitch_errs)
    where
    start = Score.event_start event
    (xs, ys) = unzip $ PSignal.to_pairs $ PSignal.clip_before start $
        Score.event_pitch event
    pitches = zip3 xs ys
        (map (PSignal.pitch_note . Score.apply_controls event start) ys)
    pitch_errs =
        [ pretty x <> ": converting " <> pretty p <> " " <> pretty err
        | (x, p, Left err) <- pitches
        ]
    ui_events =
        [ ui_event (Score.event_stack event) (RealTime.to_score x) 0
            (Pitch.note_text note)
        | (x, _, Right note) <- pitches
        ]

-- ** control

control_events :: [Score.Event] -> [Track]
control_events events =
    filter (not . empty_track) $ map (control_track events) controls
    where
    controls = List.sort $ Lists.unique $ concatMap
        (map typed_control . filter wanted . Map.toList . Score.event_controls)
        events
    -- The integrate calls always include these because they affect the
    -- pitches.  'pitch_signal_events' will have already applied them though,
    -- so we don't need to have them again.
    -- TODO: technically they should be from pscale_transposers, but that's
    -- so much work to collect, let's just assume the standards.
    wanted = (`Set.notMember` Controls.integrate_keep) . fst
    typed_control (control, sig) = ScoreT.Typed (ScoreT.type_of sig) control

control_track :: [Score.Event] -> ScoreT.Typed ScoreT.Control -> Track
control_track events control =
    make_track (ParseTitle.control_to_title control) ui_events
    where
    ui_events = drop_dyn $ tidy_controls $ map (signal_events c) events
    -- Don't emit a dyn track if it's just the default.
    drop_dyn events = case Map.lookup c Derive.initial_control_vals of
        Just val | all ((==t) . Event.text) events -> []
            where t = ShowVal.show_hex_val val
        _ -> events
    tidy_controls = clip_to_zero . drop_dups . clip_concat
    c = ScoreT.typed_val control

signal_events :: ScoreT.Control -> Score.Event -> [Event.Event]
signal_events control event = case Score.event_control control event of
    Nothing -> []
    Just sig -> map (uncurry mk) $ Signal.to_pairs $
        Signal.clip_before start (ScoreT.typed_val sig)
    where
    -- Suppose ambient dyn is .75, but then post integrate it is set to .6.
    -- Since the dyn track multiplies by default, this would wind up doubly
    -- applying the .75, for .75*.6.  So the integrate call saves its ambient
    -- dyn so we can invert it here.
    invert
        | control == Controls.dynamic = fromMaybe 1 $
            Env.maybe_val (ScoreT.control_name Controls.dynamic_integrate) $
            Score.event_environ event
        | otherwise = 1
    start = Score.event_start event
    mk x y = ui_event (Score.event_stack event) (RealTime.to_score x) 0
        (ShowVal.show_hex_val (y / invert))

-- * util

ui_event :: Stack.Stack -> ScoreTime -> ScoreTime -> Text -> Event.Event
ui_event stack pos dur text =
    Event.stack_ #= Just (Event.Stack stack pos) $ Event.event pos dur text

-- | Concatenate the events, dropping ones that are out of order.  The
-- durations are not modified, so they still might overlap in duration, but the
-- start times will be increasing.
clip_concat :: [[Event.Event]] -> [Event.Event]
clip_concat = Lists.dropWith out_of_order . concat
    where out_of_order e1 e2 = Event.start e2 <= Event.start e1

-- | Drop subsequent events with the same text, since those are redundant for
-- controls.
drop_dups :: [Event.Event] -> [Event.Event]
drop_dups = Lists.dropDups Event.text

-- | Drop events before 0, keeping at least one at 0.  Controls can wind up
-- with samples before 0 (e.g. after using 'Derive.Score.move'), but events
-- can't start before 0.
clip_to_zero :: [Event.Event] -> [Event.Event]
clip_to_zero (e1 : rest@(e2 : _))
    | Event.start e1 <= 0 && Event.start e2 <= 0 = clip_to_zero rest
    | otherwise = (Event.start_ %= max 0 $ e1) : rest
clip_to_zero [e] = [Event.start_ %= max 0 $ e]
clip_to_zero [] = []

make_track :: Title -> [Event.Event] -> Track
make_track title events = Track title (Lists.sortOn Event.start events)

empty_track :: Track -> Bool
empty_track (Track _ []) = True
empty_track _ = False
