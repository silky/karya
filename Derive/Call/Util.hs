{-# LANGUAGE ViewPatterns #-}
{- | Utilities for calls.

    The convention for calls is that there is a function @c_something@ which
    is type NoteCall or ControlCall or whatever.  It then extracts what is
    needed from the PassedArgs and passes those values to a function
    @something@ which is of type EventDeriver or ControlDeriver or whatever.
    The idea is that PassedArgs is a large dependency and it should be reduced
    immediately to what is needed.
-}
module Derive.Call.Util where
import qualified Data.FixedList as FixedList
import qualified Data.Hashable as Hashable
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Data.Traversable as Traversable

import qualified System.Random.Mersenne.Pure64 as Pure64

import Util.Control
import qualified Util.Num as Num
import qualified Util.Random as Random
import qualified Util.Seq as Seq

import Ui
import qualified Ui.Id as Id
import qualified Ui.Types as Types

import qualified Derive.Call as Call
import qualified Derive.CallSig as CallSig
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.Scale as Scale
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch
import qualified Perform.PitchSignal as PitchSignal
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal


-- * signals

-- | A function to generate a pitch curve.  It's convenient to define this
-- as a type alias so it can be easily passed to various functions that want
-- to draw curves.
type PitchInterpolator = Pitch.ScaleId
    -> Bool -- ^ include the initial sample or not
    -> RealTime -> Pitch.Degree -> RealTime -> Pitch.Degree
    -> PitchSignal.PitchSignal

-- | Like 'PitchInterpolator' but for control signals.
type ControlInterpolator = Bool -- ^ include the initial sample or not
    -> RealTime -> Signal.Y -> RealTime -> Signal.Y
    -> Signal.Control

with_controls :: (FixedList.FixedList list) => Derive.PassedArgs d
    -> list TrackLang.Control -> (list Signal.Y -> Derive.Deriver a)
    -> Derive.Deriver a
with_controls args controls f = do
    now <- Derive.passed_real args
    f =<< Traversable.mapM (control_at now) controls

-- | To accomodate both normal calls, which are in score time, and post
-- processing calls, which are in real time, these functions take RealTimes.
control_at :: RealTime -> TrackLang.Control -> Derive.Deriver Signal.Y
control_at pos control = case control of
    TrackLang.ConstantControl deflt -> return deflt
    TrackLang.DefaultedControl cont deflt ->
        maybe deflt id <$> Derive.control_at cont pos
    TrackLang.Control cont ->
        maybe (Derive.throw $ "not found and no default: " ++ show cont) return
            =<< Derive.control_at cont pos

-- | Convert a 'TrackLang.Control' to a signal.
to_signal :: TrackLang.Control -> Derive.Deriver Signal.Control
to_signal control = case control of
    TrackLang.ConstantControl deflt -> return $ Signal.constant deflt
    TrackLang.DefaultedControl cont deflt -> do
        sig <- Derive.get_control cont
        return $ maybe (Signal.constant deflt) id sig
    TrackLang.Control cont ->
        maybe (Derive.throw $ "not found: " ++ show cont) return
            =<< Derive.get_control cont

pitch_at :: RealTime -> TrackLang.PitchControl -> Derive.Deriver PitchSignal.Y
pitch_at pos control = case control of
    TrackLang.ConstantControl deflt ->
        PitchSignal.degree_to_y <$> Call.eval_note deflt
    TrackLang.DefaultedControl cont deflt -> do
        maybe_y <- Derive.named_pitch_at cont pos
        maybe (PitchSignal.degree_to_y <$> Call.eval_note deflt) return maybe_y
    TrackLang.Control cont -> do
        maybe_y <- Derive.named_pitch_at cont pos
        maybe (Derive.throw $ "pitch not found and no default given: "
            ++ show cont) return maybe_y

to_pitch_signal :: TrackLang.PitchControl
    -> Derive.Deriver PitchSignal.PitchSignal
to_pitch_signal control = case control of
    TrackLang.ConstantControl deflt -> constant deflt
    TrackLang.DefaultedControl cont deflt -> do
        sig <- Derive.get_named_pitch cont
        maybe (constant deflt) return sig
    TrackLang.Control cont ->
        maybe (Derive.throw $ "not found: " ++ show cont) return
            =<< Derive.get_named_pitch cont
    where
    constant note = do
        scale <- get_scale
        PitchSignal.constant (Scale.scale_id scale) <$> Call.eval_note note

degree_at :: RealTime -> TrackLang.PitchControl -> Derive.Deriver Pitch.Degree
degree_at pos control = PitchSignal.y_to_degree <$> pitch_at pos control

-- * note

degree :: RealTime -> Derive.Deriver Pitch.Degree
degree = Derive.degree_at

velocity :: RealTime -> Derive.Deriver Signal.Y
velocity pos =
    maybe Derive.default_velocity id <$> Derive.control_at Score.c_velocity pos

with_pitch :: PitchSignal.Degree -> Derive.Deriver a -> Derive.Deriver a
with_pitch = Derive.with_constant_pitch Nothing

with_velocity :: Signal.Y -> Derive.Deriver a -> Derive.Deriver a
with_velocity = Derive.with_control Score.c_velocity . Signal.constant

simple_note :: PitchSignal.Degree -> Signal.Y -> Derive.EventDeriver
simple_note pitch velocity = with_pitch pitch $ with_velocity velocity note

note :: Derive.EventDeriver
note = Call.eval_one 0 1 [TrackLang.call ""]

-- * call transformers

-- | There are a set of pitch calls that need a \"note\" arg when called in an
-- absolute context, but can more usefully default to @(Note "0")@ in
-- a relative track.  This will prepend a note arg if the scale in the environ
-- is relative.
default_relative_note :: Derive.PassedArgs derived
    -> Derive.Deriver (Derive.PassedArgs derived)
default_relative_note args
    | is_relative = do
        degree <- CallSig.cast "relative pitch 0"
            =<< Call.eval (TrackLang.val_call "0")
        return $ args { Derive.passed_vals =
            TrackLang.VDegree degree : Derive.passed_vals args }
    | otherwise = return args
    where
    environ = Derive.passed_environ args
    is_relative = either (const False) Pitch.is_relative
        (TrackLang.lookup_val TrackLang.v_scale environ)

-- | Derive with transformed Attributes.
with_attrs :: (Score.Attributes -> Score.Attributes) -> Derive.Deriver d
    -> Derive.Deriver d
with_attrs f deriver = do
    -- Attributes should always be in the default environ so this shouldn't
    -- abort.
    attrs <- Derive.get_val TrackLang.v_attributes
    Derive.with_val TrackLang.v_attributes (f attrs) deriver

-- * state access

get_srate :: Derive.Deriver RealTime
get_srate = RealTime.seconds <$> Derive.get_val TrackLang.v_srate

get_scale :: Derive.Deriver Scale.Scale
get_scale = Derive.get_scale =<< get_scale_id

lookup_scale :: Derive.Deriver (Maybe Scale.Scale)
lookup_scale = Derive.lookup_scale =<< get_scale_id

get_scale_id :: Derive.Deriver Pitch.ScaleId
get_scale_id = Derive.get_val TrackLang.v_scale

lookup_instrument :: Derive.Deriver (Maybe Score.Instrument)
lookup_instrument = Derive.lookup_val TrackLang.v_instrument

-- ** random

class Random a where
    -- | Infinite list of random numbers.  These are deterministic in that
    -- they depend on the current track, current call position, and the random
    -- seed.
    randoms :: Derive.Deriver [a]
instance Random Double where randoms = _make_randoms Pure64.randomDouble
instance Random Int where randoms = _make_randoms Pure64.randomInt

-- | Infinite list of random numbers in the given range.
randoms_in :: (Real a, Random a) => a -> a -> Derive.Deriver [a]
randoms_in low high = map (Num.restrict low high) <$> randoms

random :: (Random a) => Derive.Deriver a
random = head <$> randoms

random_in :: (Random a, Real a) => a -> a -> Derive.Deriver a
random_in low high = Num.restrict low high <$> random

shuffle :: [a] -> Derive.Deriver [a]
shuffle xs = Random.shuffle xs <$> randoms

_make_randoms :: (Pure64.PureMT -> (a, Pure64.PureMT)) -> Derive.Deriver [a]
_make_randoms f = do
    pos <- maybe 0 fst . Seq.head . Maybe.mapMaybe Stack.region_of
        . Stack.innermost <$> Derive.get_stack
    gen <- _random_generator pos
    return $ List.unfoldr (Just . f) gen

_random_generator :: ScoreTime -> Derive.Deriver Pure64.PureMT
_random_generator pos = do
    seed <- Derive.lookup_val TrackLang.v_seed :: Derive.Deriver (Maybe Double)
    track_id <- Seq.head . Maybe.mapMaybe Stack.track_of . Stack.innermost <$>
        Derive.get_stack
    let track = maybe 0 (Hashable.hash . Id.show_id . Id.unpack_id) track_id
        cseed = Hashable.hash track
            `Hashable.hashWithSalt` Maybe.fromMaybe 0 seed
            `Hashable.hashWithSalt` Types.score_to_double pos
    return $ Pure64.pureMT (fromIntegral cseed)


-- * c_equal

c_equal :: (Derive.Derived derived) => Derive.Call derived
c_equal = Derive.transformer "equal" $ \args deriver ->
    case Derive.passed_vals args of
        [TrackLang.VSymbol assignee, val] ->
            Derive.with_val assignee val deriver
        [control -> Just assignee, TrackLang.VControl val] -> do
            sig <- to_signal val
            Derive.with_control assignee sig deriver
        [control -> Just assignee, TrackLang.VNum val] ->
            Derive.with_control assignee (Signal.constant val) deriver
        [pitch -> Just assignee, TrackLang.VPitchControl val] -> do
            sig <- to_pitch_signal val
            Derive.with_pitch assignee sig deriver
        [pitch -> Just assignee, TrackLang.VDegree val] -> do
            scale_id <- get_scale_id
            Derive.with_pitch assignee (PitchSignal.constant scale_id val)
                deriver
        _ -> Derive.throw_arg_error
            "equal call expected (sym, val) or (sig, sig) args"
    where
    control (TrackLang.VControl (TrackLang.Control c)) = Just c
    control _ = Nothing
    pitch (TrackLang.VPitchControl (TrackLang.Control c@(Score.Control n)))
        | null n = Just Nothing
        | otherwise = Just (Just c)
    pitch _ = Nothing

-- * map score events

-- Functions here force a Deriver into its LEvent.LEvents and process them
-- directly, and then repackage them as a Deriver.  This can accomplish
-- concrete post-processing type effects but has the side-effect of collapsing
-- the Deriver, which will no longer respond to the environment.

-- Generators can mostly forget about LEvents and emit plain Events since
-- 'Derive.generator' applies the fmap.  Unfortunately the story is not so
-- simple for transformers.  Hopefully functions here can mostly hide LEvents
-- from transformers.

-- | Head of an LEvent list.
event_head :: Derive.EventStream d
    -> (d -> Derive.EventStream d -> Derive.LogsDeriver d)
    -> Derive.LogsDeriver d
event_head [] _ = return []
event_head (log@(LEvent.Log _) : rest) f = (log:) <$> event_head rest f
event_head (LEvent.Event event : rest) f = f event rest

-- | Map a function with state over events and lookup pitch and controls vals
-- for each event.  Exceptions are not caught.
map_signals :: (FixedList.FixedList cs, FixedList.FixedList ps) =>
    cs TrackLang.Control -> ps TrackLang.PitchControl
    -> (cs Signal.Y -> ps Pitch.Degree -> state -> Score.Event
        -> Derive.Deriver ([Score.Event], state))
    -> state -> Derive.Events -> Derive.Deriver ([Derive.Events], state)
map_signals controls pitch_controls f state events = go state events
    where
    go state [] = return ([], state)
    go state (log@(LEvent.Log _) : rest) = do
        (rest_vals, final_state) <- go state rest
        return ([log] : rest_vals, final_state)
    go state (LEvent.Event event : rest) = do
        let pos = Score.event_start event
        control_vals <- Traversable.mapM (control_at pos) controls
        pitch_vals <- Traversable.mapM (degree_at pos) pitch_controls
        (val, next_state) <- f control_vals pitch_vals state event
        (rest_vals, final_state) <- go next_state rest
        return (map LEvent.Event val : rest_vals, final_state)
