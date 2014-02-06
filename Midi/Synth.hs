-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Simulate a MIDI synth and turn low level MIDI msgs back into a medium
-- level form.  This is a bit like \"unperform\".
module Midi.Synth where
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.Reader as Reader
import qualified Control.Monad.State.Strict as State

import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Tuple as Tuple

import qualified Text.Printf as Printf

import Util.Control
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Midi.Midi as Midi
import qualified Midi.State as MState
import Midi.State (Addr)

import qualified Perform.Pitch as Pitch
import Types


-- * analyze

initial_pitches :: [Note] -> [(Int, Pitch.NoteNumber)]
initial_pitches notes = Seq.sort_on fst $ map Tuple.swap $ Map.toList $
    Map.fromListWith (+) [(initial_pitch note, 1) | note <- notes ]

nonconstant_pitches :: [Note] -> [Note]
nonconstant_pitches = filter $ not . null . note_pitches
    -- filter out ones after note-off
    -- take a decay time

initial_pitch :: Note -> Pitch.NoteNumber
initial_pitch = round_cents . note_pitch

round_cents :: Pitch.NoteNumber -> Pitch.NoteNumber
round_cents = (/100) . Pitch.nn . round . (*100)

-- * compute

data State = State {
    state_channel :: !MState.State
    -- | Notes still sounding.  This retains notes for 'deactivate_time' after
    -- their note-off to capture controls during the decay.
    , state_active :: !(Map.Map Addr [SoundingNote])
    , state_notes :: ![Note]
    , state_warns :: ![(Midi.WriteMessage, Text)]
    , state_pb_range :: !(Map.Map Addr PbRange)
    } deriving (Show)

-- | (down, up)
type PbRange = (Pitch.NoteNumber, Pitch.NoteNumber)

get_pb_range :: Addr -> State -> PbRange
get_pb_range addr = Map.findWithDefault (-1, 1) addr . state_pb_range

empty_state :: State
empty_state = State MState.empty mempty [] [] mempty

-- | SoundingNotes may still be open.
type SoundingNote = NoteT (Maybe RealTime)
type Note = NoteT RealTime

data NoteT dur = Note {
    note_start :: RealTime
    , note_duration :: dur
    , note_key :: Midi.Key
    , note_vel :: Midi.Velocity
    , note_pitch :: Pitch.NoteNumber
    , note_pitches :: [(RealTime, Pitch.NoteNumber)]
    , note_controls :: ControlMap
    , note_addr :: Addr
    } deriving (Eq, Show)

type ControlMap = Map.Map MState.Control [(RealTime, Midi.ControlValue)]

-- | Keep the current msg for 'warn'.
type SynthM a = Reader.ReaderT Midi.WriteMessage
    (State.StateT State Identity.Identity) a

modify :: (State -> State) -> SynthM ()
modify f = do
    st <- State.get
    State.put $! f st

run :: State -> [Midi.WriteMessage] -> State
run state msgs = postproc $ run_state (mapM_ msg1 (Seq.zip_prev msgs))
    where
    run_state = Identity.runIdentity . flip State.execStateT state
    msg1 (prev, wmsg) = flip Reader.runReaderT wmsg $ do
        let prev_t = maybe 0 Midi.wmsg_ts prev
        when (Midi.wmsg_ts wmsg < prev_t) $
            warn $ "timestamp less than previous: " <> prettyt prev_t
        run_msg wmsg

postproc :: State -> State
postproc state_ = state
    { state_active = Map.filterWithKey (\_ ns -> not (null ns)) $
        Map.map (map postproc_note) (state_active state)
    , state_notes = reverse $ map postproc_note (state_notes state)
    , state_warns = reverse $ state_warns state
    }
    where
    state = deactivate 9999999 state_
    postproc_note note = note
        { note_controls = Map.map reverse (note_controls note)
        , note_pitches = reverse (note_pitches note)
        }

run_msg :: Midi.WriteMessage -> SynthM ()
run_msg wmsg@(Midi.WriteMessage dev ts (Midi.ChannelMessage chan msg)) = do
    let addr = (dev, chan)
    modify $ update_channel_state wmsg . deactivate ts
    case normalize_msg msg of
        Midi.NoteOff key _ -> note_off addr ts key
        Midi.NoteOn key vel -> note_on addr ts key vel
        Midi.Aftertouch _ _ -> warn "aftertouch not supported"
        Midi.ControlChange c val -> control addr ts (MState.CC c) val
        Midi.ProgramChange _ -> warn "program change not supported"
        Midi.ChannelPressure val -> control addr ts MState.Pressure val
        Midi.PitchBend val -> pitch_bend addr ts val
        _ -> warn "unhandled msg"
run_msg _ = return ()

update_channel_state :: Midi.WriteMessage -> State -> State
update_channel_state wmsg state =
    state { state_channel = MState.process (state_channel state) msg }
    where msg = (Midi.wmsg_dev wmsg, Midi.wmsg_msg wmsg)

normalize_msg :: Midi.ChannelMessage -> Midi.ChannelMessage
normalize_msg (Midi.NoteOn key 0) = Midi.NoteOff key 1
normalize_msg msg = msg

-- | After notes have had a note-off time for a certain amount of time, move
-- them from 'state_active' to 'state_notes'.  The certain amount of time
-- should be the note's decay time, but since I don't really know that, just
-- pick an arbitrary constant.
deactivate :: RealTime -> State -> State
deactivate now state = state
    { state_active = still_active
    , state_notes = mapMaybe close (concat done) ++ state_notes state
    }
    where
    (addrs, (done, active)) = second unzip $ unzip $
        map (second (List.partition note_done)) $
        Map.toList (state_active state)
    still_active = Map.fromList $ filter (not . null . snd) $ zip addrs active
    note_done note = case note_duration note of
        Just d -> now >= d + deactivate_time
        Nothing -> False
    close note = case note_duration note of
        Nothing -> Nothing
        Just d -> Just $ note { note_duration = d }

deactivate_time :: RealTime
deactivate_time = 1

-- * msgs

note_on :: Addr -> RealTime -> Midi.Key -> Midi.Velocity -> SynthM ()
note_on addr ts key vel = do
    active <- State.gets $ Map.findWithDefault [] addr . state_active
    let sounding = filter (key_sounding key) active
    unless (null sounding) $
        warn $ "sounding notes: " <> prettyt sounding
    channel <- State.gets $ MState.get_channel addr . state_channel
    pb_range <- State.gets $ get_pb_range addr
    modify_notes addr (make_note pb_range channel addr ts key vel :)

make_note :: PbRange -> MState.Channel -> Addr -> RealTime -> Midi.Key
    -> Midi.Velocity -> SoundingNote
make_note pb_range state addr start key vel = Note
    { note_start = start
    , note_duration = Nothing
    , note_key = key
    , note_vel = vel
    , note_pitch = convert_pitch pb_range key (MState.chan_pb state)
    , note_pitches = []
    , note_controls = here <$> MState.chan_controls state
    , note_addr = addr
    }
    where here val = [(start, val)]

note_off :: Addr -> RealTime -> Midi.Key -> SynthM ()
note_off addr ts key = do
    active <- State.gets $ Map.findWithDefault [] addr . state_active
    let (sounding, rest) = List.partition (key_sounding key) active
    case sounding of
        [] -> warn "no sounding notes"
        n : ns -> do
            unless (null ns) $
                warn $ "multiple sounding notes: " <> prettyt sounding
            modify_notes addr $ const $
                n { note_duration = Just ts } : rest

key_sounding :: Midi.Key -> SoundingNote -> Bool
key_sounding key n = note_duration n == Nothing && note_key n == key

-- | Append a CC change to all sounding notes.
control :: Addr -> RealTime -> MState.Control -> Midi.ControlValue -> SynthM ()
control addr ts control val = modify_notes addr (map insert)
    where
    insert note = note { note_controls =
        Map.insertWith (++) control [(ts, val)] (note_controls note) }

-- | Append pitch bend to all sounding notes.
pitch_bend :: Addr -> RealTime -> Midi.PitchBendValue -> SynthM ()
pitch_bend addr ts val = do
    pb_range <- State.gets $ get_pb_range addr
    modify_notes addr (map (insert pb_range))
    where
    insert pb_range note = note { note_pitches =
        (ts, convert_pitch pb_range (note_key note) val) : note_pitches note }

convert_pitch :: PbRange -> Midi.Key -> Midi.PitchBendValue -> Pitch.NoteNumber
convert_pitch (down, up) key val = Midi.from_key key + convert val
    where
    convert v
        | v >= 0 = Pitch.nn (Num.f2d v) * up
        | otherwise = Pitch.nn (- (Num.f2d v)) * down

modify_notes :: Addr -> ([SoundingNote] -> [SoundingNote]) -> SynthM ()
modify_notes addr f = do
    active <- State.gets state_active
    let notes = Map.findWithDefault [] addr active
    modify $ \state -> state
        { state_active = Map.insert addr (f notes) (state_active state) }

-- * util

warn :: Text -> SynthM ()
warn msg = do
    wmsg <- Reader.ask
    State.modify $ \state ->
        state { state_warns = (wmsg, msg) : state_warns state }


-- * pretty

-- | Format synth state in an easier to read way.
pretty_state :: State -> Text
pretty_state (State _chan active notes warns _) = Text.intercalate "\n" $ concat
    [ ["active:"], map prettyt (concat (Map.elems active))
    , ["", "warns:"], map pretty_warn warns
    , ["", "notes:"], map prettyt notes
    ]

instance Pretty.Pretty dur => Pretty.Pretty (NoteT dur) where
    pretty (Note start dur _key vel pitch pitches controls (dev, chan)) =
        Printf.printf "%s %s %s--%s: vel:%x" addr_s (pretty (round_cents pitch))
            (pretty start) (pretty dur) vel
        <> (if null pitches then "" else " p:" <> pretty pitches)
        <> (if Map.null controls then "" else " c:" <> pretty_controls controls)
        where addr_s = pretty dev ++ ":" ++ show chan

pretty_controls :: ControlMap -> String
pretty_controls controls = Seq.join "\n\t"
    [show cont ++ ":" ++ pretty vals | (cont, vals) <- Map.assocs controls]

pretty_warn :: (Midi.WriteMessage, Text) -> Text
pretty_warn (Midi.WriteMessage dev ts (Midi.ChannelMessage chan msg), warn) =
    prettyt ts <> " " <> prettyt dev <> ":" <> showt chan
        <> " " <> showt msg <> ": " <> warn
pretty_warn (Midi.WriteMessage dev ts msg, warn) =
    prettyt ts <> " " <> prettyt dev <> ":" <> showt msg <> ": " <> warn
