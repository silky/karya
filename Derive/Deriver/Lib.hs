-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{- | This has the higher level parts of the deriver library.  That is,
    functions where are considered basic but can be defined outside of
    "Derive.Deriver.Monad".
-}
module Derive.Deriver.Lib where
import Prelude hiding (error)
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Monoid as Monoid

import Util.Control
import qualified Util.Log as Log
import qualified Util.Seq as Seq

import qualified Ui.Event as Event
import qualified Ui.Ruler as Ruler
import qualified Ui.State as State
import qualified Ui.Track as Track

import qualified Derive.BaseTypes as BaseTypes
import qualified Derive.Controls as Controls
import qualified Derive.Deriver.Internal as Internal
import Derive.Deriver.Monad
import qualified Derive.Environ as Environ
import qualified Derive.LEvent as LEvent
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang
import qualified Derive.TrackWarp as TrackWarp

import qualified Perform.Lilypond.Types as Lilypond.Types
import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal

import Types


-- * derive

-- This should probably be in Internal, but can't due to a circular dependency
-- with 'real'.

-- | Package up the results of a derivation.
--
-- NOTE TO SELF: Don't put bangs on this and then be surprised when the
-- laziness tests fail, you doofus.
data Result = Result {
    r_events :: Events
    , r_cache :: Cache
    , r_track_warps :: [TrackWarp.Collection]
    , r_track_signals :: Track.TrackSignals
    , r_track_dynamic :: TrackDynamic
    , r_integrated :: [Integrated]

    -- | The relevant parts of the final state should be extracted into the
    -- above fields, but returning the whole state can be useful for testing.
    , r_state :: State
    }

-- | Kick off a derivation.
--
-- The derivation state is quite involved, so there are a lot of arguments
-- here.
derive :: Constant -> Scopes -> TrackLang.Environ -> Deriver a -> RunResult a
derive constant scopes environ deriver =
    run state (with_initial_scope environ deriver)
    where state = initial_state scopes environ constant

extract_result :: RunResult Events -> Result
extract_result (result, state, logs) = Result
    { r_events = merge_logs result logs
    , r_cache = collect_cache collect <> state_cache (state_constant state)
    , r_track_warps = TrackWarp.collections (collect_warp_map collect)
    , r_track_signals = collect_track_signals collect
    , r_track_dynamic = collect_track_dynamic collect
    , r_integrated = collect_integrated collect
    , r_state = state
    }
    where collect = state_collect state

-- | Given an environ, bring instrument and scale calls into scope.
with_initial_scope :: TrackLang.Environ -> Deriver d -> Deriver d
with_initial_scope env deriver = set_inst (set_scale deriver)
    where
    set_inst = case TrackLang.get_val Environ.instrument env of
        Right inst -> with_instrument inst
        _ -> id
    set_scale = case TrackLang.get_val Environ.scale env of
        Right sym -> \deriver -> do
            scale <- get_scale (TrackLang.sym_to_scale_id sym)
            with_scale scale deriver
        _ -> id


-- * errors

require :: String -> Maybe a -> Deriver a
require msg = maybe (throw msg) return

require_right :: (err -> String) -> Either err a -> Deriver a
require_right fmt_err = either (throw . fmt_err) return

error_to_warn :: Error -> Log.Msg
error_to_warn (Error srcpos stack val) = Log.msg_srcpos srcpos Log.Warn
    (Just (Stack.to_strings stack)) ("Error: " <> prettyt val)


-- * state access

get_stack :: Deriver Stack.Stack
get_stack = gets (state_stack . state_dynamic)

real_function :: Deriver (ScoreTime -> RealTime)
real_function = do
    warp <- Internal.get_dynamic state_warp
    return $ flip Score.warp_pos warp

score_function :: Deriver (RealTime -> Maybe ScoreTime)
score_function = do
    warp <- Internal.get_dynamic state_warp
    return $ flip Score.unwarp_pos warp

-- ** scale

-- | Lookup a scale_id or throw.
get_scale :: Pitch.ScaleId -> Deriver Scale
get_scale scale_id = maybe
    (throw $ "get_scale: unknown " <> pretty scale_id)
    return =<< lookup_scale scale_id

lookup_scale :: Pitch.ScaleId -> Deriver (Maybe Scale)
lookup_scale scale_id = do
    lookup_scale <- gets (state_lookup_scale . state_constant)
    return $ lookup_scale scale_id


-- ** environment

lookup_val :: (TrackLang.Typecheck a) => TrackLang.ValName -> Deriver (Maybe a)
lookup_val name = do
    environ <- Internal.get_environ
    either throw return (TrackLang.checked_val name environ)

is_val_set :: TrackLang.ValName -> Deriver Bool
is_val_set name =
    Maybe.isJust . TrackLang.lookup_val name <$> Internal.get_environ

-- | Like 'lookup_val', but throw if the value isn't present.
get_val :: (TrackLang.Typecheck a) => TrackLang.ValName -> Deriver a
get_val name = do
    val <- lookup_val name
    maybe (throw $ "environ val not found: " ++ pretty name) return val

is_lilypond_derive :: Deriver Bool
is_lilypond_derive = Maybe.isJust <$> lookup_lilypond_config

lookup_lilypond_config :: Deriver (Maybe Lilypond.Types.Config)
lookup_lilypond_config = gets (state_lilypond . state_constant)

-- | Set the given val dynamically within the given computation.  This is
-- analogous to a dynamic let.
--
-- There is intentionally no way to modify the environment via assignment.
-- It would introduce an order of execution dependency that would complicate
-- caching as well as have a confusing non-local effect.
--
-- This dispatches to 'with_scale' or 'with_instrument' if it's setting the
-- scale or instrument, so scale or instrument scopes are always set when scale
-- and instrument are.
with_val :: (TrackLang.Typecheck val) => TrackLang.ValName -> val
    -> Deriver a -> Deriver a
with_val name val deriver
    | name == Environ.scale, Just scale_id <- TrackLang.to_scale_id v = do
        scale <- get_scale scale_id
        with_scale scale deriver
    | name == Environ.instrument, Just inst <- TrackLang.from_val v =
        with_instrument inst deriver
    | otherwise = with_val_raw name val deriver
    where v = TrackLang.to_val val

-- | Like 'with_val', but don't set scopes for instrument and scale.
with_val_raw :: (TrackLang.Typecheck val) => TrackLang.ValName -> val
    -> Deriver a -> Deriver a
with_val_raw name val = Internal.localm $ \st -> do
    environ <- Internal.insert_environ name val (state_environ st)
    return $! st { state_environ = environ }

modify_val :: (TrackLang.Typecheck val) => TrackLang.ValName
    -> (Maybe val -> val) -> Deriver a -> Deriver a
modify_val name modify = Internal.localm $ \st -> do
    let env = state_environ st
    val <- modify <$> either throw return (TrackLang.checked_val name env)
    return $! st { state_environ =
        TrackLang.insert_val name (TrackLang.to_val val) env }

with_scale :: Scale -> Deriver d -> Deriver d
with_scale scale =
    with_val_raw Environ.scale (TrackLang.scale_id_to_sym (scale_id scale))
    . with_scopes (val . pitch)
    where
    pitch = s_generator#s_pitch#s_scale #= [scale_to_lookup scale val_to_pitch]
    val = s_val#s_scale #= [scale_to_lookup scale id]

scale_to_lookup :: Scale -> (ValCall -> call) -> LookupCall call
scale_to_lookup scale convert =
    pattern_lookup name (scale_call_doc scale) $ \call_id ->
        return $ convert <$> scale_note_to_call scale (to_note call_id)
    where
    name = prettyt (scale_id scale) <> ": " <> scale_pattern scale
    to_note (TrackLang.Symbol sym) = Pitch.Note sym

-- | Convert a val call to a pitch call.  This is used so scales can export
-- their ValCalls to pitch generators.
val_to_pitch :: ValCall -> Generator Pitch
val_to_pitch (ValCall name doc vcall) = Call
    { call_name = name
    , call_doc = doc
    , call_func = pitch_call . convert_args
    }
    where
    convert_args args = args
        { passed_info = tag_call_info (passed_info args) }
    pitch_call args = vcall args >>= \val -> case val of
        TrackLang.VPitch pitch -> do
            -- Previously I dispatched to '', which is normally
            -- 'Derive.Call.Pitch.c_set'.  That would be more flexible since
            -- you can then override '', but is also less efficient.
            pos <- Internal.real $ Event.start $ info_event $ passed_info args
            return [LEvent.Event $ PitchSignal.signal [(pos, pitch)]]
        _ -> throw $ "scale call " <> untxt name
            <> " returned non-pitch: " <> untxt (ShowVal.show_val val)

with_instrument :: Score.Instrument -> Deriver d -> Deriver d
with_instrument inst deriver = do
    lookup_inst <- gets $ state_lookup_instrument . state_constant
    let with_inst = with_val_raw Environ.instrument inst
    -- Previously, I would just substitute an empty instrument, but it turned
    -- out to be error prone, since a misspelled instrument would derive
    -- anyway, only without the right calls and environ.
    Instrument calls environ <-
        require ("no instrument found for " <> untxt (ShowVal.show_val inst))
        (lookup_inst inst)
    with_inst $ with_scopes (set_scopes calls) $ with_environ environ deriver
    where
    -- Replace the calls in the instrument scope type.
    set_scopes (InstrumentCalls inst_gen inst_trans inst_val)
            (Scopes gen trans val) =
        Scopes
            { scopes_generator = set_note inst_gen gen
            , scopes_transformer = set_note inst_trans trans
            , scopes_val = set_inst inst_val val
            }
    set_note lookups scope =
        scope { scope_note = set_inst lookups (scope_note scope) }
    set_inst lookups stype = stype { stype_instrument = lookups }

-- | Merge the given environ into the environ in effect.
with_environ :: TrackLang.Environ -> Deriver a -> Deriver a
with_environ environ
    | TrackLang.null_environ environ = id
    | otherwise = Internal.local $ \st -> st
        { state_environ = environ <> state_environ st }


-- ** control

-- | Return an entire signal.
get_control :: Score.Control -> Deriver (Maybe (RealTime -> Score.TypedVal))
get_control control = get_control_function control >>= \x -> case x of
    Just f -> return $ Just f
    Nothing -> get_control_signal control >>= return . fmap signal_function

signal_function :: Score.TypedControl -> (RealTime -> Score.TypedVal)
signal_function sig t = Signal.at t <$> sig

get_control_signal :: Score.Control -> Deriver (Maybe Score.TypedControl)
get_control_signal control = Map.lookup control <$> get_controls

get_controls :: Deriver Score.ControlMap
get_controls = Internal.get_dynamic state_controls

get_control_functions :: Deriver Score.ControlFunctionMap
get_control_functions = Internal.get_dynamic state_control_functions

-- | Get the control value at the given time, taking 'state_control_functions'
-- into account.
control_at :: Score.Control -> RealTime -> Deriver (Maybe Score.TypedVal)
control_at control pos = get_control_function control >>= \x -> case x of
    Just f -> return $ Just $ f pos
    Nothing -> do
        sig <- Map.lookup control <$> get_controls
        return $ Score.control_val_at pos <$> sig

get_control_function :: Score.Control
    -> Deriver (Maybe (RealTime -> Score.TypedVal))
get_control_function control = do
    functions <- Internal.get_dynamic state_control_functions
    case Map.lookup control functions of
        Nothing -> return Nothing
        Just f -> do
            dyn <- get_control_function_dynamic
            return $ Just $ TrackLang.call_control_function f control dyn

untyped_control_at :: Score.Control -> RealTime -> Deriver (Maybe Signal.Y)
untyped_control_at cont = fmap (fmap Score.typed_val) . control_at cont

-- | Get a ControlValMap at the given time, taking 'state_control_functions'
-- into account.  Like ControlValMap, this is intended to be used for
-- a 'PitchSignal.Pitch'.
controls_at :: RealTime -> Deriver Score.ControlValMap
controls_at pos = do
    controls <- get_controls
    fs <- Internal.get_dynamic state_control_functions
    dyn <- get_control_function_dynamic
    return $ Map.fromList $ map (resolve dyn pos) $
        Seq.equal_pairs (\a b -> fst a == fst b)
            (Map.toAscList fs) (Map.toAscList controls)
    where
    resolve dyn pos p = case p of
        Seq.Both (k, f) _ -> (k, call k f)
        Seq.First (k, f) -> (k, call k f)
        Seq.Second (k, sig) -> (k, Signal.at pos (Score.typed_val sig))
        where
        call control f = Score.typed_val $
            TrackLang.call_control_function f control dyn pos

get_control_function_dynamic :: Deriver BaseTypes.Dynamic
get_control_function_dynamic = do
    ruler <- get_ruler
    Internal.get_dynamic (convert_dynamic ruler)

convert_dynamic :: Ruler.Marklists -> Dynamic -> TrackLang.Dynamic
convert_dynamic ruler dyn = TrackLang.Dynamic
    { TrackLang.dyn_controls = state_controls dyn
    , TrackLang.dyn_control_functions = state_control_functions dyn
    , TrackLang.dyn_pitches = state_pitches dyn
    , TrackLang.dyn_pitch = state_pitch dyn
    , TrackLang.dyn_environ = state_environ dyn
    , TrackLang.dyn_warp = state_warp dyn
    , TrackLang.dyn_ruler = ruler
    }

get_ruler :: Deriver Ruler.Marklists
get_ruler = Internal.lookup_current_tracknum >>= \x -> case x of
    Nothing -> return mempty
    Just (block_id, tracknum) -> do
        state <- Internal.get_ui_state id
        return $ either (const mempty) id $ State.eval state $ do
            ruler_id <- fromMaybe State.no_ruler <$>
                State.ruler_track_at block_id tracknum
            Ruler.ruler_marklists <$> State.get_ruler ruler_id

with_merged_control :: Merge -> Score.Control -> Score.TypedControl
    -> Deriver a -> Deriver a
with_merged_control merge control = with control
    where
    with = case merge of
        Set -> with_control
        Default
            | Controls.is_additive control -> with_relative_control op_add
            | otherwise -> with_relative_control op_mul
        Merge op -> with_relative_control op

with_control :: Score.Control -> Score.TypedControl -> Deriver a -> Deriver a
with_control control signal = Internal.local $ \st ->
    st { state_controls = Map.insert control signal (state_controls st) }

with_control_function :: Score.Control -> TrackLang.ControlFunction
    -> Deriver a -> Deriver a
with_control_function control f = Internal.local $ \st -> st
    { state_control_functions =
        Map.insert control f (state_control_functions st)
    }

-- | Replace the controls entirely.
with_control_maps :: Score.ControlMap -> Score.ControlFunctionMap
    -> Deriver a -> Deriver a
with_control_maps cmap cfuncs = Internal.local $ \st -> st
    { state_controls = cmap
    , state_control_functions = cfuncs
    }

-- | Modify an existing control.
--
-- If both signals are typed, the existing type wins over the relative
-- signal's type.  If one is untyped, the typed one wins.
with_relative_control :: ControlOp -> Score.Control -> Score.TypedControl
    -> Deriver a -> Deriver a
with_relative_control op cont signal deriver = do
    controls <- get_controls
    let new = apply_control_op op (Map.lookup cont controls) signal
    with_control cont new deriver

-- | Combine two signals with a ControlOp.
apply_control_op :: ControlOp -> Maybe Score.TypedControl
    -> Score.TypedControl -> Score.TypedControl
apply_control_op (ControlOp _ op ident) maybe_old new =
    Score.Typed (Score.type_of old <> Score.type_of new)
        (op (Score.typed_val old) (Score.typed_val new))
    where
    old = fromMaybe (Score.Typed (Score.type_of new) (Signal.constant ident))
        maybe_old

with_added_control :: Score.Control -> Score.TypedControl -> Deriver a
    -> Deriver a
with_added_control = with_relative_control op_add

with_multiplied_control :: Score.Control -> Score.TypedControl -> Deriver a
    -> Deriver a
with_multiplied_control = with_relative_control op_mul

multiply_control :: Score.Control -> Signal.Y -> Deriver a -> Deriver a
multiply_control cont val
    | val == 1 = id
    | otherwise = with_multiplied_control cont
        (Score.untyped (Signal.constant val))

get_control_op :: TrackLang.CallId -> Deriver ControlOp
get_control_op c_op = do
    op_map <- gets (state_control_op_map . state_constant)
    maybe (throw ("unknown control op: " ++ show c_op)) return
        (Map.lookup c_op op_map)

-- | Emit a 'ControlMod'.
modify_control :: Merge -> Score.Control -> Signal.Control -> Deriver ()
modify_control merge control signal = Internal.modify_collect $ \collect ->
    collect { collect_control_mods =
        ControlMod control signal merge : collect_control_mods collect }

-- | Apply the collected control mods to the given deriver and clear them out.
apply_control_mods :: Deriver a -> Deriver a
apply_control_mods deriver = do
    mods <- gets (collect_control_mods . state_collect)
    Internal.modify_collect $ \collect ->
        collect { collect_control_mods = [] }
    foldr ($) deriver (map apply mods)
    where
    apply (ControlMod control signal merge) =
        with_merged_control merge control (Score.untyped signal)

-- ** pitch

-- | The pitch at the given time.  The transposition controls have not been
-- applied since that is supposed to be done once only when the event is
-- generated.
--
-- The scenario is a call that generates a note based on the current pitch.
-- If 'pitch_at' applied the transposition, the new note would have to remove
-- the transposition signals so they don't get applied again at performance
-- conversion.
pitch_at :: RealTime -> Deriver (Maybe PitchSignal.Pitch)
pitch_at pos = PitchSignal.at pos <$> Internal.get_dynamic state_pitch

named_pitch_at :: Score.Control -> RealTime
    -> Deriver (Maybe PitchSignal.Pitch)
named_pitch_at name pos = do
    psig <- get_named_pitch name
    return $ maybe Nothing (PitchSignal.at pos) psig

-- | Unlike 'pitch_at', the transposition has already been applied, because you
-- can't transpose any further once you have a NoteNumber.
nn_at :: RealTime -> Deriver (Maybe Pitch.NoteNumber)
nn_at pos = do
    controls <- controls_at pos
    environ <- Internal.get_environ
    justm (pitch_at pos) $ \pitch -> do
        logged_pitch_nn ("nn " ++ pretty pos) $
            PitchSignal.apply environ controls pitch

get_named_pitch :: Score.Control -> Deriver (Maybe PitchSignal.Signal)
get_named_pitch name = Map.lookup name <$> Internal.get_dynamic state_pitches

named_nn_at :: Score.Control -> RealTime -> Deriver (Maybe Pitch.NoteNumber)
named_nn_at name pos = do
    controls <- controls_at pos
    environ <- Internal.get_environ
    justm (named_pitch_at name pos) $ \pitch -> do
        logged_pitch_nn ("named_nn " ++ pretty (name, pos)) $
            PitchSignal.apply environ controls pitch

-- | Version of 'PitchSignal.pitch_nn' that logs errors.
logged_pitch_nn :: String -> PitchSignal.Pitch
    -> Deriver (Maybe Pitch.NoteNumber)
logged_pitch_nn msg pitch = case PitchSignal.pitch_nn pitch of
    Left (PitchSignal.PitchError err) -> do
        Log.warn $ "pitch_nn " <> msg <> ": " <> untxt err
        return Nothing
    Right nn -> return $ Just nn

-- | Run the deriver in a context with the given pitch signal.  If a Control
-- is given, the pitch has that name, otherwise it's the unnamed default
-- pitch.
with_pitch :: Maybe Score.Control -> PitchSignal.Signal
    -> Deriver a -> Deriver a
with_pitch cont = modify_pitch cont . const

with_constant_pitch :: Maybe Score.Control -> PitchSignal.Pitch
    -> Deriver a -> Deriver a
with_constant_pitch maybe_name = with_pitch maybe_name . PitchSignal.constant

with_no_pitch :: Deriver a -> Deriver a
with_no_pitch = modify_pitch Nothing (const mempty)

pitch_signal_scale :: Scale -> PitchSignal.Scale
pitch_signal_scale scale =
    PitchSignal.Scale (scale_id scale) (scale_transposers scale)

modify_pitch :: Maybe Score.Control
    -> (Maybe PitchSignal.Signal -> PitchSignal.Signal)
    -> Deriver a -> Deriver a
modify_pitch Nothing f = Internal.local $ \st ->
    st { state_pitch = f (Just (state_pitch st)) }
modify_pitch (Just name) f = Internal.local $ \st ->
    st { state_pitches = Map.alter (Just . f) name (state_pitches st) }

-- | Run the derivation with a modified scope.
with_scopes :: (Scopes -> Scopes) -> Deriver a -> Deriver a
with_scopes modify = Internal.local $ \st ->
    st { state_scopes = modify (state_scopes st) }

-- | If the deriver throws, log the error and return Nothing.
catch :: Deriver a -> Deriver (Maybe a)
catch deriver = do
    st <- get
    let (result, st2, logs) = run st deriver
    mapM_ Log.write logs
    case result of
        Left err -> do
            Log.write $ error_to_warn err
            return Nothing
        Right val -> do
            Internal.merge_collect (state_collect st2)
            return $ Just val

-- * postproc

-- | Shift the controls of a deriver.  You're supposed to apply the warp
-- before deriving the controls, but I don't have a good solution for how to
-- do this yet, so I can leave these here for the moment.
shift_control :: ScoreTime -> Deriver a -> Deriver a
shift_control shift deriver = do
    real <- Internal.real shift
    Internal.local
        (\st -> st
            { state_controls = nudge real (state_controls st)
            , state_pitch = nudge_pitch real (state_pitch st)
            })
        deriver
    where
    nudge delay = Map.map (fmap (Signal.shift delay))
    nudge_pitch = PitchSignal.shift

-- ** merge

-- | The EventDerivers run as sub-derivers and the results are mappended, which
-- lets them to interleave their work or run in parallel.
d_merge :: [NoteDeriver] -> NoteDeriver
d_merge [] = mempty
d_merge [d] = d
d_merge derivers = do
    state <- get
    -- Clear collect so they can be merged back without worrying about dups.
    let cleared = state { state_collect = mempty }
    let (streams, collects) = unzip (map (run_sub cleared) derivers)
    modify $ \st -> st
        { state_collect = Monoid.mconcat (state_collect state : collects) }
    return (Seq.merge_lists event_start streams)

-- | Like 'd_merge', but the derivers are assumed to return events that are
-- non-decreasing in time, so the merge can be more efficient.  It also assumes
-- each deriver is small, so it threads collect instead of making them
-- independent.
d_merge_asc :: [NoteDeriver] -> NoteDeriver
d_merge_asc = fmap merge_asc_events . sequence

type PureResult d = (LEvent.LEvents d, Collect)

-- | Run the given deriver and return the relevant data.
run_sub :: State -> LogsDeriver derived -> PureResult derived
run_sub state deriver = (merge_logs result logs, state_collect state2)
    where (result, state2, logs) = run state deriver

merge_logs :: Either Error (LEvent.LEvents d) -> [Log.Msg]
    -> LEvent.LEvents d
merge_logs result logs = case result of
    Left err -> map LEvent.Log (logs ++ [error_to_warn err])
    Right events -> events ++ map LEvent.Log logs

-- | Merge sorted lists of events.  If the lists themselves are also sorted,
-- I can produce output without scanning the entire input list, so this should
-- be more efficient for a large input list than 'merge_events'.
merge_asc_events :: [Events] -> Events
merge_asc_events = Seq.merge_asc_lists event_start

merge_events :: Events -> Events -> Events
merge_events = Seq.merge_on event_start

-- | This will make logs always merge ahead of score events, but that should
-- be ok.
event_start :: LEvent.LEvent Score.Event -> RealTime
event_start (LEvent.Log _) = 0
event_start (LEvent.Event event) = Score.event_start event

instance Monoid.Monoid NoteDeriver where
    mempty = return []
    mappend d1 d2 = d_merge [d1, d2]
    mconcat = d_merge
