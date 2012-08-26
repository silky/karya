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
import Data.FixedList (Nil(..))
import qualified Data.Hashable as Hashable
import qualified Data.List as List
import qualified Data.Traversable as Traversable

import qualified System.Random.Mersenne.Pure64 as Pure64

import Util.Control
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty
import qualified Util.Random as Random
import qualified Util.Seq as Seq

import qualified Ui.Id as Id
import qualified Ui.ScoreTime as ScoreTime
import qualified Derive.Args as Args
import qualified Derive.Call as Call
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Scale as Scale
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import Types


-- * signals

-- TODO There are four types that divide into two kinds.  Then I have
-- every possible combination:
-- any type: Score.Real
-- time type without value: Real
-- time type with value: TrackLang.Real
--
-- This means I wind up with a lot of duplication here to handle time types and
-- transpose types.  Surely there's a better way?  Maybe put the two kinds into
-- a typeclass?

data TransposeType = Diatonic | Chromatic deriving (Show)
data TimeType = Real | Score deriving (Eq, Show)

split_transpose :: Pitch.Transpose -> (Double, TransposeType)
split_transpose (Pitch.Chromatic c) = (c, Chromatic)
split_transpose (Pitch.Diatonic c) = (c, Diatonic)

join_transpose :: Double -> TransposeType -> Pitch.Transpose
join_transpose c Chromatic = Pitch.Chromatic c
join_transpose c Diatonic = Pitch.Diatonic c

with_controls :: (FixedList.FixedList list) => Derive.PassedArgs d
    -> list TrackLang.ValControl -> (list Signal.Y -> Derive.Deriver a)
    -> Derive.Deriver a
with_controls args controls f = do
    now <- Args.real_start args
    f =<< Traversable.mapM (flip control_at now) controls

-- | To accomodate both normal calls, which are in score time, and post
-- processing calls, which are in real time, these functions take RealTimes.
control_at :: TrackLang.ValControl -> RealTime -> Derive.Deriver Signal.Y
control_at control pos = Score.typed_val <$> typed_control_at control pos

typed_control_at :: TrackLang.ValControl -> RealTime
    -> Derive.Deriver Score.TypedVal
typed_control_at control pos = case control of
    TrackLang.ConstantControl deflt -> return deflt
    TrackLang.DefaultedControl cont deflt ->
        fromMaybe deflt <$> Derive.control_at cont pos
    TrackLang.LiteralControl cont ->
        maybe (Derive.throw $ "not found and no default: "
                ++ TrackLang.show_val cont) return
            =<< Derive.control_at cont pos

time_control_at :: TimeType -> TrackLang.ValControl -> RealTime
    -> Derive.Deriver TrackLang.RealOrScore
time_control_at default_type control pos = do
    Score.Typed typ val <- typed_control_at control pos
    time_type <- case typ of
            Score.Untyped -> return default_type
            Score.Score -> return Score
            Score.Real -> return Real
            _ -> Derive.throw $ "expected time type for "
                ++ TrackLang.show_val control ++ " but got "
                ++ Pretty.pretty typ
    return $ case time_type of
        Real -> TrackLang.Real (RealTime.seconds val)
        Score -> TrackLang.Score (ScoreTime.double val)

transpose_control_at :: TransposeType -> TrackLang.ValControl -> RealTime
    -> Derive.Deriver (Signal.Y, TransposeType)
transpose_control_at default_type control pos = do
    Score.Typed typ val <- typed_control_at control pos
    transpose_type <- case typ of
        Score.Untyped -> return default_type
        Score.Chromatic -> return Chromatic
        Score.Diatonic -> return Diatonic
        _ -> Derive.throw $ "expected transpose type for "
            ++ TrackLang.show_val control ++ " but got "
            ++ Pretty.pretty typ
    return (val, transpose_type)

-- | Convert a 'TrackLang.ValControl' to a signal.
--
-- If a signal exists but doesn't have a type, the type will be inherited from
-- the default.  This way a call can cause a signal parameter to default to
-- a certain type.
to_signal :: TrackLang.ValControl -> Derive.Deriver Score.TypedSignal
to_signal control = case control of
    TrackLang.ConstantControl deflt -> return $ fmap Signal.constant deflt
    TrackLang.DefaultedControl cont deflt -> do
        maybe_sig <- Derive.get_control cont
        return $ case maybe_sig of
            Nothing -> Signal.constant <$> deflt
            Just sig -> sig
                { Score.type_of = Score.type_of sig <> Score.type_of deflt }
    TrackLang.LiteralControl cont ->
        maybe (Derive.throw $ "not found: " ++ show cont) return
            =<< Derive.get_control cont

to_untyped_signal :: TrackLang.ValControl -> Derive.Deriver Signal.Control
to_untyped_signal = fmap Score.typed_val . to_signal

-- | Version of 'to_signal' specialized for transpose signals.  Throws if
-- the signal had a non-transpose type.
to_transpose_signal :: TransposeType -> TrackLang.ValControl
    -> Derive.Deriver (Signal.Control, Score.Control)
    -- ^ (signal, appropriate transpose control)
to_transpose_signal default_type control = do
    Score.Typed typ sig <- to_signal control
    case typ of
        Score.Untyped -> return (sig, case default_type of
            Diatonic -> Score.c_diatonic; Chromatic -> Score.c_chromatic)
        Score.Chromatic -> return (sig, Score.c_chromatic)
        Score.Diatonic -> return (sig, Score.c_diatonic)
        _ -> Derive.throw $ "expected transpose type for "
            ++ TrackLang.show_val control ++ " but got " ++ Pretty.pretty typ

-- | Version of 'to_signal' that will complain if the control isn't a time
-- type.
to_time_signal :: TimeType -> TrackLang.ValControl
    -> Derive.Deriver (Signal.Control, TimeType)
to_time_signal default_type control = do
    Score.Typed typ sig <- to_signal control
    case typ of
        Score.Untyped -> return (sig, default_type)
        Score.Score -> return (sig, Score)
        Score.Real -> return (sig, Real)
        _ -> Derive.throw $ "expected time type for "
            ++ TrackLang.show_val control ++ " but got " ++ Pretty.pretty typ

pitch_at :: RealTime -> TrackLang.PitchControl
    -> Derive.Deriver PitchSignal.Pitch
pitch_at pos control = case control of
    TrackLang.ConstantControl deflt -> Call.eval_note deflt
    TrackLang.DefaultedControl cont deflt -> do
        maybe_pitch <- Derive.named_pitch_at cont pos
        maybe (Call.eval_note deflt) return maybe_pitch
    TrackLang.LiteralControl cont -> do
        maybe_pitch <- Derive.named_pitch_at cont pos
        maybe (Derive.throw $ "pitch not found and no default given: "
            ++ show cont) return maybe_pitch

to_pitch_signal :: TrackLang.PitchControl
    -> Derive.Deriver PitchSignal.Signal
to_pitch_signal control = case control of
    TrackLang.ConstantControl deflt -> constant deflt
    TrackLang.DefaultedControl cont deflt -> do
        sig <- Derive.get_named_pitch cont
        maybe (constant deflt) return sig
    TrackLang.LiteralControl cont ->
        maybe (Derive.throw $ "not found: " ++ show cont) return
            =<< Derive.get_named_pitch cont
    where
    constant note = do
        scale <- get_scale
        constant_pitch scale <$> Call.eval_note note

nn_at :: RealTime -> TrackLang.PitchControl
    -> Derive.Deriver (Maybe Pitch.NoteNumber)
nn_at pos control = -- TODO throw exception?
    Derive.logged_pitch_nn ("Util.nn_at " ++ Pretty.pretty (pos, control))
        =<< pitch_at pos control

pitch_signal :: [(RealTime, PitchSignal.Pitch)]
    -> Derive.Deriver PitchSignal.Signal
pitch_signal xs = do
    scale <- get_scale
    return $ signal scale xs

-- | More convenient constructors for PitchSignals.
constant_pitch :: Scale.Scale -> PitchSignal.Pitch -> PitchSignal.Signal
constant_pitch = PitchSignal.constant . Derive.pitch_signal_scale

signal :: Scale.Scale -> [(RealTime, PitchSignal.Pitch)] -> PitchSignal.Signal
signal = PitchSignal.signal . Derive.pitch_signal_scale

-- * note

-- | Get the Pitch at the particular point in time in the default pitch
-- signal.  As per 'Derive.pitch_at', the transposition controls have not been
-- applied.
pitch :: RealTime -> Derive.Deriver (Maybe PitchSignal.Pitch)
pitch = Derive.pitch_at

dynamic :: RealTime -> Derive.Deriver Signal.Y
dynamic pos = maybe Derive.default_dynamic Score.typed_val <$>
    Derive.control_at Score.c_dynamic pos

with_pitch :: PitchSignal.Pitch -> Derive.Deriver a -> Derive.Deriver a
with_pitch pitch deriver = do
    scale <- get_scale
    Derive.with_constant_pitch Nothing scale pitch deriver

with_dynamic :: Signal.Y -> Derive.Deriver a -> Derive.Deriver a
with_dynamic =
    Derive.with_control Score.c_dynamic . Score.untyped . Signal.constant

pitched_note :: PitchSignal.Pitch -> Signal.Y -> Derive.EventDeriver
pitched_note pitch dynamic = with_pitch pitch $ with_dynamic dynamic note

note :: Derive.EventDeriver
note = Call.eval_one_call $ TrackLang.call "" []

-- | A zero-duration 'note'.
triggered_note :: Derive.EventDeriver
triggered_note = Call.eval_one_at 0 0 $ TrackLang.call "" [] :| []

-- * call transformers

-- | Derive with transformed Attributes.
with_attrs :: (Score.Attributes -> Score.Attributes) -> Derive.Deriver d
    -> Derive.Deriver d
with_attrs f deriver = do
    attrs <- get_attrs
    Derive.with_val TrackLang.v_attributes (f attrs) deriver

add_attrs :: Score.Attributes -> Derive.Deriver d -> Derive.Deriver d
add_attrs = with_attrs . Score.attrs_union

-- * environ

get_srate :: Derive.Deriver RealTime
get_srate = RealTime.seconds <$> Derive.get_val TrackLang.v_srate

get_scale :: Derive.Deriver Scale.Scale
get_scale = Derive.get_scale =<< get_scale_id

lookup_scale :: Derive.Deriver (Maybe Scale.Scale)
lookup_scale = Derive.lookup_scale =<< get_scale_id

get_scale_id :: Derive.Deriver Pitch.ScaleId
get_scale_id = Derive.get_val TrackLang.v_scale

lookup_key :: Derive.Deriver (Maybe Pitch.Key)
lookup_key = fmap Pitch.Key <$> Derive.lookup_val TrackLang.v_key

lookup_instrument :: Derive.Deriver (Maybe Score.Instrument)
lookup_instrument = Derive.lookup_val TrackLang.v_instrument

get_attrs :: Derive.Deriver Score.Attributes
get_attrs = fromMaybe mempty <$> Derive.lookup_val TrackLang.v_attributes

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
    pos <- maybe 0 fst . Seq.head . mapMaybe Stack.region_of
        . Stack.innermost <$> Derive.get_stack
    gen <- _random_generator pos
    return $ List.unfoldr (Just . f) gen

_random_generator :: ScoreTime -> Derive.Deriver Pure64.PureMT
_random_generator pos = do
    seed <- Derive.lookup_val TrackLang.v_seed :: Derive.Deriver (Maybe Double)
    track_id <- Seq.head . mapMaybe Stack.track_of . Stack.innermost <$>
        Derive.get_stack
    let track = maybe 0 (Hashable.hash . Id.show_id . Id.unpack_id) track_id
        cseed = Hashable.hash track
            `Hashable.hashWithSalt` fromMaybe 0 seed
            `Hashable.hashWithSalt` ScoreTime.to_double pos
    return $ Pure64.pureMT (fromIntegral cseed)

-- * time

-- | A time range from the event start until a given duration.
duration_from_start :: Derive.PassedArgs d -> TrackLang.RealOrScore
    -> Derive.Deriver (RealTime, RealTime)
duration_from_start args time = do
    start <- Args.real_start args
    case time of
        TrackLang.Real t -> return (start, start + t)
        TrackLang.Score t -> (,) start <$> Derive.real (Args.start args + t)

-- | Get the real duration of a typed time val at the given point of score
-- time.  RealTime is linear, so 1 second is always 1 second no matter where
-- it is, but ScoreTime will map to different amounts of RealTime depending
-- on where it is.
real_duration :: TimeType -> ScoreTime -> Score.TypedVal
    -> Derive.Deriver RealTime
real_duration default_type from (Score.Typed typ val)
    | typ == Score.Real || typ == Score.Untyped && default_type == Real =
        return (RealTime.seconds val)
    | typ == Score.Score || typ == Score.Untyped && default_type == Score = do
        start <- Derive.real from
        end <- Derive.real (from + ScoreTime.double val)
        return (end - start)
    | otherwise = Derive.throw $
        "expected time type for " ++ TrackLang.show_val (Score.Typed typ val)

-- | Add a RealTime to a ScoreTime.
delay :: ScoreTime -> RealTime -> Derive.Deriver ScoreTime
delay start time = do
    real_start <- Derive.real start
    Derive.score (real_start + time)

-- | Get the amount of ScoreTime to add to a given ScoreTime to delay it
-- by a certain amount.  If the delay amount is already ScoreTime then
-- it's trivial, but if it's RealTime then the returned ScoreTime has to
-- be relative to the given start time.
delay_relative :: ScoreTime -> TrackLang.RealOrScore -> Derive.Deriver ScoreTime
delay_relative _ (TrackLang.Score t) = return t
delay_relative start (TrackLang.Real t) = do
    score_t <- delay start t
    return $ score_t - start


-- * c_equal

c_equal :: (Derive.Derived derived) => Derive.Call derived
c_equal = Derive.transformer "equal" equal_transformer

equal_transformer :: Derive.PassedArgs derived -> Derive.Deriver a
    -> Derive.Deriver a
equal_transformer args deriver = case Derive.passed_vals args of
    [TrackLang.VSymbol assignee, val] ->
        Derive.with_val assignee val deriver
    [control -> Just assignee, TrackLang.VControl val] -> do
        sig <- to_signal val
        Derive.with_control assignee sig deriver
    [control -> Just assignee, TrackLang.VNum val] ->
        Derive.with_control assignee (fmap Signal.constant val) deriver
    [pitch -> Just assignee, TrackLang.VPitchControl val] -> do
        sig <- to_pitch_signal val
        Derive.with_pitch assignee sig deriver
    [pitch -> Just assignee, TrackLang.VPitch val] -> do
        scale <- get_scale
        Derive.with_pitch assignee (constant_pitch scale val) deriver
    _ -> Derive.throw_arg_error
        "equal call expected (sym, val) or (sig, sig) args"
    where
    control (TrackLang.VControl (TrackLang.LiteralControl c)) = Just c
    control _ = Nothing
    pitch (TrackLang.VPitchControl
            (TrackLang.LiteralControl c@(Score.Control n)))
        | null n = Just Nothing
        | otherwise = Just (Just c)
    pitch _ = Nothing

-- * postproc utils

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

map_events_asc :: state -> Derive.Events
    -> (state -> Score.Event -> Derive.Deriver (state, [Score.Event]))
    -> Derive.EventDeriver
map_events_asc state events f = do
    (_, result) <- map_controls Nil state events (\Nil -> f)
    return $ Derive.merge_asc_events result

-- | Specialization of 'map_controls' where the transformation will return
-- events in ascending order.
map_controls_asc :: (FixedList.FixedList cs) => cs TrackLang.ValControl
    -> state -> Derive.EventDeriver
    -> (cs Score.TypedVal -> state -> Score.Event
        -> Derive.Deriver (state, [Score.Event]))
    -> Derive.EventDeriver
map_controls_asc controls state deriver f = do
    events <- deriver
    (_, result) <- map_controls controls state events f
    return $ Derive.merge_asc_events result

-- | Specialization of 'map_controls_pitches' with no pitch signals.  Also,
-- the mapped function is not in Deriver since you are expected to be
-- depending only on the control values.
map_controls :: (FixedList.FixedList cs) => cs TrackLang.ValControl
    -> state -> Derive.Events
    -> (cs Score.TypedVal -> state -> Score.Event
        -> Derive.Deriver (state, [Score.Event]))
    -> Derive.Deriver (state, [Derive.Events])
map_controls controls state events f =
    map_controls_pitches controls Nil state events $ \cs Nil -> f cs

-- | Map a function with state over events and lookup pitch and controls vals
-- for each event.  Exceptions are caught and logged.
--
-- This is the most general transformer map over events.
map_controls_pitches :: (FixedList.FixedList cs, FixedList.FixedList ps) =>
    cs TrackLang.ValControl -> ps TrackLang.PitchControl
    -> state -> Derive.Events
    -> (cs Score.TypedVal -> ps PitchSignal.Pitch -> state -> Score.Event
        -> Derive.Deriver (state, [Score.Event]))
    -> Derive.Deriver (state, [Derive.Events])
map_controls_pitches controls pitch_controls state events f = go state events
    where
    go state [] = return (state, [])
    go state (log@(LEvent.Log _) : rest) = do
        (final_state, rest_vals) <- go state rest
        return (final_state, [log] : rest_vals)
    go state (LEvent.Event event : rest) = do
        let pos = Score.event_start event
        control_vals <- Traversable.mapM (flip typed_control_at pos) controls
        pitch_vals <- Traversable.mapM (pitch_at pos) pitch_controls
        result <- Derive.with_event event $
            f control_vals pitch_vals state event
        (final_state, rest_vals) <- go (maybe state fst result) rest
        let vals = maybe rest_vals
                ((:rest_vals) . map LEvent.Event . snd) result
        return (final_state, vals)
