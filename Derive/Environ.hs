-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Define a few inhabitants of Environ which are used by the built-in set of
-- calls.  Expected types are in 'Derive.TrackLang.hardcoded_types'.
module Derive.Environ where
import Data.Text (Text)

import Derive.BaseTypes (Key)


-- * directly supported by core derivers

-- | VList: arguments for a 'Derive.Call.Tags.requires_postproc' call.
-- Also see 'Derive.Call.Post.make_delayed'.
args :: Key
args = "args"

-- | VAttributes: Default set of attrs.
attributes :: Key
attributes = "attr"

-- | ScoreTime: the block deriver sets it to the ScoreTime end of the block.
-- Blocks always start at zero, but this is the only way for a call to know if
-- an event is at the end of the block.
block_end :: Key
block_end = "block-end"

-- | VSymbol: Set to the control that is being derived, inside of a control
-- track.
control :: Key
control = "control"

-- | VInstrument: Default instrument.
instrument :: Key
instrument = "inst"

-- | VSymbol: Diatonic transposition often requires a key.  The interpretation
-- of the value depends on the scale.
key :: Key
key = "key"

-- | VNum (ScoreTime): End time of the note event.  This is set when evaluating
-- note events so that inverted control tracks know when their parent event
-- ends.
note_end :: Key
note_end = "note-end"

-- | This is just like 'note_end', except, you know, the other end.
note_start :: Key
note_start = "note-start"

-- | VSymbol: Set along with 'control' to the 'Derive.Derive.Merge' function
-- which will be used for this control track.  Calls can use this to subvert
-- the merge function and emit an absolute value.
--
-- Values are @compose@ for tempo tracks, @set@, or any of the names from
-- 'Derive.Derive.ControlOp'.
merge :: Key
merge = "merge"

-- | VSymbol: Default scale, used by pitch tracks with a @*@ title.
scale :: Key
scale = "scale"

-- | VNum: Random seed used by randomization functions.  Can be explicitly
-- initialized to capture a certain \"random\" variation.
--
-- This is rounded to an integer, so only integral values make sense.
seed :: Key
seed = "seed"

-- | VNum: Sampling rate used by signal interpolators.
srate :: Key
srate = "srate"

-- | VNum: Set the default tempo, overriding 'Ui.State.default_tempo'.  This
-- only applies if there is no toplevel tempo track, and generally only has an
-- effect if the block is played as a toplevel block since it's a constant
-- tempo.
--
-- Previously I would directly set the tempo warp in the equal call, but tempo
-- setting has to be at the toplevel tempo track for it to interact properly
-- with block call stretching.
tempo :: Key
tempo = "tempo"

-- | VNum: this is the count of the tracks with the same instrument, starting
-- from 0 on the left.  So three tracks named @>pno@ would be 0, 1, and 2,
-- respectively.  Used with "Derive.Call.InferTrackVoice".
track_voice :: Key
track_voice = "track-voice"

-- * internal

-- | RealTime: suppress other notes until this time, inclusive.  Only events
-- without a suppress-until will be retained.  Applied by @infer-duration@, see
-- "Derive.Call.Post.Move".
suppress_until :: Key
suppress_until = "suppress-until"

-- | VNum: This is a bit of a hack for the dynamic to velocity conversion in
-- "Perform.Midi.Convert".  The default note deriver stashes the control
-- function output here, so if it turns out to not be a Pressure instrument
-- it can use this value.
--
-- Details in 'Perform.Midi.Convert.convert_dynamic'.
dynamic_val :: Key
dynamic_val = "dyn-val"

-- | RealTime: This stores the RealTime sum of 'Derive.Controls.start_s' and
-- 'Derive.Controls.start_t', and is later applied by the @apply-start-offset@
-- postproc.
start_offset_val :: Key
start_offset_val = "start-offset-val"

-- * supported by not so core derivers

-- | VNotePitch or VNum (NN): The top of the instrument's range.
--
-- It's a VNotePitch for instruments that are tied to a particular family of
-- scales, and have an upper note that is independent of any particular
-- frequency. For instance, a kantilan's top note will have a different
-- NoteNumber depending on its scale, or even within a single scale, depending
-- if it is pengumbang or pengisep.
--
-- For instruments with less complicated scale requirements, NoteNumber is
-- simpler.
instrument_top :: Key
instrument_top = "inst-top"

instrument_bottom :: Key
instrument_bottom = "inst-bottom"

-- | List VPitch: tuning of open strings for this instrument.  The pitches
-- should be probably absolute NNs, not in any scale, so they work regardless
-- of which scale you happen to be in.
--
-- TODO maybe it should be VNotePitch as with 'instrument_top'?
open_strings :: Key
open_strings = "open-strings"

-- | VSymbol: Instrument role, e.g. 'polos' or 'sangsih'.
role :: Key
role = "role"

-- | VSymbol: Kind of tuning for the scale in scope.  The meaning is dependent
-- on the scale, e.g. ngumbang ngisep for Balinese scales.
tuning :: Key
tuning = "tuning"

-- | VNum: Separate notes into different voices.  This is used by integrate to
-- put them on their own tracks, and by the lilypond backend to split them into
-- their own voices.  Should be an integer from 1 to 4.
voice :: Key
voice = "v"

-- | VSymbol: @right@, @r@,  @left@, or @l@.  Used by the lilypond backend, and
-- also by any call that relies on an instrument's parts being divided by hand.
hand :: Key
hand = "hand"

-- | VNum: hold the start of a call for a certain amount of ScoreTime or
-- RealTime.
hold :: Key
hold = "hold"


-- * values

-- | Scale tuning.
umbang, isep :: Text
umbang = "umbang"
isep = "isep"

-- | Instrument role.
polos, sangsih :: Text
polos = "polos"
sangsih = "sangsih"
