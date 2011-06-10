{-# LANGUAGE ScopedTypeVariables #-}
{- | Main module for the deriver monad.

    TODO update Derive\/README, move it to doc\/, and link from here

    The convention is to prepend deriver names with @d_@, so if the deriver is
    normally implemented purely, a d_ version can be made simply by composing
    'return'.

    I have a similar sort of setup to nyquist, with a \"transformation
    environment\" that functions can look at to implement behavioral
    abstraction.  The main differences are that I don't actually generate audio
    signal, but my \"ugens\" eventually render down to MIDI or OSC (or even
    nyquist or csound source!).

    \"Stack\" handling here is kind of confusing.

    The end goal is that log messages and exceptions are tagged with the place
    they occurred.  This is called the stack, and is described in
    'Perform.Warning.Stack'.  Since the stack elements indicate positions on
    the screen, they should be in unwarped score time, not real time.

    The current stack is stored in 'state_stack' and will be added to by
    'with_stack_block', 'with_stack_track', and 'with_stack_pos' as the deriver
    processes a block, a track, and individual events respectively.
    Log msgs and 'throw' will pick the current stack out of 'state_stack'.

    When 'Derive.Score.Event's are emitted they are also given the stack at the
    time of their derivation.  If there is a problem in performance, log msgs
    still have access to the stack.

-}
module Derive.Deriver.Lib where
import qualified Prelude
import Prelude hiding (error)
import Control.Monad
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Monoid as Monoid
import qualified Data.Set as Set

import Util.Control
import qualified Util.Log as Log
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import Ui
import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.State as State
import qualified Ui.Track as Track

import Derive.Deriver.Internal
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang
import qualified Derive.TrackWarp as TrackWarp

import qualified Perform.Pitch as Pitch
import qualified Perform.PitchSignal as PitchSignal
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal
import qualified Perform.Transport as Transport




-- * derive

data Result = Result {
    r_events :: Events
    , r_cache :: Cache
    , r_tempo :: Transport.TempoFunction
    , r_closest_warp :: Transport.ClosestWarpFunction
    , r_inv_tempo :: Transport.InverseTempoFunction
    , r_track_signals :: Track.TrackSignals
    , r_track_environ :: TrackEnviron

    -- | The relevant parts of the final state should be extracted into the
    -- above fields, but returning the whole state can be useful for testing.
    , r_state :: State
    }

-- | Kick off a derivation.
--
-- The derivation state is quite involved, so there are a lot of arguments
-- here.
derive :: Constant -> Scope -> Cache -> ScoreDamage -> TrackLang.Environ
    -> EventDeriver -> Result
derive constant scope cache damage environ deriver =
    Result (merge_logs result logs) (state_cache (state_cache_state state))
        tempo_func closest_func inv_tempo_func
        (collect_track_signals collect) (collect_track_environ collect)
        state
    where
    (result, state, logs) = run initial (with_inital_scope environ deriver)
    initial = initial_state scope clean_cache damage environ constant
    clean_cache = clear_damage damage cache
    collect = state_collect state
    warps = TrackWarp.collections (collect_warp_map collect)
    tempo_func = TrackWarp.tempo_func warps
    closest_func = TrackWarp.closest_warp warps
    inv_tempo_func = TrackWarp.inverse_tempo_func warps

-- | Given an environ, bring instrument and scale calls into scope.
with_inital_scope :: TrackLang.Environ -> Deriver d -> Deriver d
with_inital_scope env deriver = set_inst (set_scale deriver)
    where
    set_inst = case TrackLang.lookup_val TrackLang.v_instrument env of
        Right inst -> with_instrument inst
        _ -> id
    set_scale = case TrackLang.lookup_val TrackLang.v_scale env of
        Right scale_id -> \deriver -> do
            scale <- get_scale scale_id
            with_scale scale deriver
        _ -> id


-- * errors

require :: String -> Maybe a -> Deriver a
require msg = maybe (throw msg) return

with_msg :: String -> Deriver a -> Deriver a
with_msg msg = local state_log_context
    (\old st -> st { state_log_context = old })
    (\st -> return $ st { state_log_context = msg : state_log_context st })

error_to_warn :: DeriveError -> Log.Msg
error_to_warn (DeriveError srcpos stack val) = Log.msg_srcpos srcpos Log.Warn
    (Just stack) ("DeriveError: " ++ Pretty.pretty val)


-- * state access

-- | This is a little different from Reader.local because only a portion of
-- the state is used Reader-style.
-- TODO split State into dynamically scoped portion and use Reader for that.
--
-- Note that this doesn't restore the state on an exception.  I think this
-- is ok because exceptions are always \"caught\" at the event evaluation
-- level since it runs each one separately.  Since the state dynamic state
-- (i.e. except Collect) from the sub derivation is discarded, whatever state
-- it's in after the exception shouldn't matter.
local :: (State -> b) -> (b -> State -> State)
    -> (State -> Deriver State) -> Deriver a -> Deriver a
local from_state restore_state modify_state deriver = do
    old <- gets from_state
    new <- modify_state =<< get
    put new
    result <- deriver
    modify (restore_state old)
    return result

modify_collect :: (Collect -> Collect) -> Deriver ()
modify_collect f = modify $ \st -> st { state_collect = f (state_collect st) }

-- ** scale

-- | Lookup a scale_id or throw.
get_scale :: Pitch.ScaleId -> Deriver Scale
get_scale scale_id = maybe (throw $ "unknown " ++ show scale_id) return
    =<< lookup_scale scale_id

lookup_scale :: Pitch.ScaleId -> Deriver (Maybe Scale)
lookup_scale scale_id = do
    -- Defaulting the scale here means that relative pitch tracks don't need
    -- to mention their scale.
    scale_id <- if scale_id == Pitch.default_scale_id
        then gets (PitchSignal.sig_scale . state_pitch)
        else return scale_id
    lookup_scale <- gets (state_lookup_scale . state_constant)
    return $ lookup_scale scale_id

-- ** cache

local_cache_state :: (CacheState -> st) -> (st -> CacheState -> CacheState)
    -> (CacheState -> CacheState)
    -> Deriver a -> Deriver a
local_cache_state from_state to_state modify_state = local
    (from_state . state_cache_state)
    (\old st -> st { state_cache_state = to_state old (state_cache_state st) })
    (\st -> return $ st
        { state_cache_state = modify_state (state_cache_state st) })

modify_cache_state :: (CacheState -> CacheState) -> Deriver ()
modify_cache_state f = modify $ \st ->
    st { state_cache_state = f (state_cache_state st) }

get_cache_state :: Deriver CacheState
get_cache_state = gets state_cache_state

put_cache :: Cache -> Deriver ()
put_cache cache = modify_cache_state $ \st -> st { state_cache = cache }

with_control_damage :: ControlDamage -> Deriver derived -> Deriver derived
with_control_damage damage = local_cache_state
    state_control_damage
    (\old st -> st { state_control_damage = old })
    (\st -> st { state_control_damage = damage })

add_block_dep :: BlockId -> Deriver ()
add_block_dep block_id = modify_collect $ \st ->
    st { collect_local_dep = insert (collect_local_dep st) }
    where
    insert (GeneratorDep blocks) = GeneratorDep (Set.insert block_id blocks)

-- | Both track warps and local deps are used as dynamic return values (aka
-- modifying a variable to \"return\" something).  When evaluating a cached
-- generator, the caller wants to know the callee's track warps and local
-- deps, without getting them mixed up with its own warps and deps.  So run
-- a deriver in an empty environment, and restore it afterwards.
with_empty_collect :: Deriver a -> Deriver (a, Collect)
with_empty_collect deriver = do
    old <- gets state_collect
    new <- (\st -> return $ st { state_collect = mempty }) =<< get
    put new
    result <- deriver
    collect <- gets state_collect
    modify (\st -> st { state_collect = old })
    return (result, collect)


-- ** environment

lookup_val :: forall a. (TrackLang.Typecheck a) =>
    TrackLang.ValName -> Deriver (Maybe a)
lookup_val name = do
    environ <- gets state_environ
    let return_type = TrackLang.to_type (Prelude.error "lookup_val" :: a)
    case TrackLang.lookup_val name environ of
            Left TrackLang.NotFound -> return Nothing
            Left (TrackLang.WrongType typ) ->
                throw $ "lookup_val " ++ show name ++ ": expected "
                    ++ Pretty.pretty return_type ++ " but val type is "
                    ++ Pretty.pretty typ
            Right v -> return (Just v)

-- | Like 'lookup_val', but throw if the value isn't present.
require_val :: forall a. (TrackLang.Typecheck a) =>
    TrackLang.ValName -> Deriver a
require_val name = do
    val <- lookup_val name
    maybe (throw $ "environ val not found: " ++ Pretty.pretty name) return val

-- | Set the given val dynamically within the given computation.  This is
-- analogous to a dynamic let.
--
-- There is intentionally no way to modify the environment via assignment.
-- It would introduce an order of execution dependency that would complicate
-- caching as well as have a confusing non-local effect.
with_val :: (TrackLang.Typecheck val) => TrackLang.ValName -> val
    -> Deriver a -> Deriver a
with_val name val =
    local state_environ (\old st -> st { state_environ = old }) $ \st -> do
        environ <- insert_environ name val (state_environ st)
        return $ st { state_environ = environ }

insert_environ :: (TrackLang.Typecheck val) => TrackLang.ValName
    -> val -> TrackLang.Environ -> Deriver TrackLang.Environ
insert_environ name val environ =
    case TrackLang.put_val name val environ of
        Left typ -> throw $ "can't set " ++ show name ++ " to "
            ++ Pretty.pretty (TrackLang.to_val val)
            ++ ", expected " ++ Pretty.pretty typ
        Right environ2 -> return environ2

-- | Figure out the current block and track, and record the current environ
-- in the Collect.  This should be called only once per track.
record_track_environ :: State -> Collect
record_track_environ state = case stack of
        Stack.Track tid : Stack.Block bid : _ ->
            collect { collect_track_environ = insert bid tid }
        _ -> collect
    where
    -- Strip the stack down to the most recent track and block, since it will
    -- look like [tid, tid, tid, bid, ...].
    stack = Seq.drop_dups is_track $ filter track_or_block $
        Stack.innermost (state_stack state)
    track_or_block (Stack.Track _) = True
    track_or_block (Stack.Block _) = True
    track_or_block _ = False
    is_track (Stack.Track _) = True
    is_track _ = False
    collect = state_collect state
    insert bid tid = Map.insert (bid, tid) (state_environ state)
        (collect_track_environ collect)

with_scale :: Scale -> Deriver d -> Deriver d
with_scale scale = with_val TrackLang.v_scale (scale_id scale)
    . with_scope (\scope -> scope { scope_val = set (scope_val scope) })
    where
    set stype = stype { stype_scale = [lookup_scale_val scale] }
    lookup_scale_val :: Scale -> LookupCall ValCall
    lookup_scale_val scale call_id =
        return $ scale_note_to_call scale (to_note call_id)
        where to_note (TrackLang.Symbol sym) = Pitch.Note sym

with_instrument :: Score.Instrument -> Deriver d -> Deriver d
with_instrument inst deriver = do
    lookup_inst_calls <- gets (state_instrument_calls . state_constant)
    let inst_calls = maybe (InstrumentCalls [] []) id (lookup_inst_calls inst)
    with_val TrackLang.v_instrument inst
        (with_scope (set_scope inst_calls) deriver)
    where
    -- Replace the calls in the instrument scope type.
    set_scope (InstrumentCalls notes vals) scope = scope
        { scope_val = set_val vals (scope_val scope)
        , scope_note = set_note notes (scope_note scope)
        }
    set_val vals stype = stype { stype_instrument = vals }
    set_note notes stype = stype { stype_instrument = notes }


-- ** control

-- | Return an entire signal.  Remember, signals are in RealTime, so if you
-- want to index them in ScoreTime you will have to call 'score_to_real'.
-- 'control_at_score' does that for you.
get_control :: Score.Control -> Deriver (Maybe Signal.Control)
get_control cont = Map.lookup cont <$> gets state_controls

control_at_score :: Score.Control -> ScoreTime -> Deriver (Maybe Signal.Y)
control_at_score cont pos = control_at cont =<< score_to_real pos

control_at :: Score.Control -> RealTime -> Deriver (Maybe Signal.Y)
control_at cont pos = do
    controls <- gets state_controls
    return $ fmap (Signal.at pos) (Map.lookup cont controls)

pitch_at_score :: ScoreTime -> Deriver PitchSignal.Y
pitch_at_score pos = pitch_at =<< score_to_real pos

pitch_at :: RealTime -> Deriver PitchSignal.Y
pitch_at pos = do
    psig <- gets state_pitch
    return (PitchSignal.at pos psig)

pitch_degree_at :: RealTime -> Deriver Pitch.Degree
pitch_degree_at pos = PitchSignal.y_to_degree <$> pitch_at pos

get_named_pitch :: Score.Control -> Deriver (Maybe PitchSignal.PitchSignal)
get_named_pitch name = Map.lookup name <$> gets state_pitches

named_pitch_at :: Score.Control -> RealTime -> Deriver (Maybe PitchSignal.Y)
named_pitch_at name pos = do
    maybe_psig <- get_named_pitch name
    return $ PitchSignal.at pos <$> maybe_psig

named_degree_at :: Score.Control -> RealTime -> Deriver (Maybe Pitch.Degree)
named_degree_at name pos = do
    y <- named_pitch_at name pos
    return $ fmap PitchSignal.y_to_degree y

with_control :: Score.Control -> Signal.Control -> Deriver a -> Deriver a
with_control cont signal =
    local (Map.lookup cont . state_controls) insert alter
    where
    insert Nothing st = st
    insert (Just sig) st = st { state_controls =
        Map.insert cont sig (state_controls st) }
    alter st = return $ st { state_controls =
        Map.insert cont signal (state_controls st) }

with_control_operator :: Score.Control -> TrackLang.CallId
    -> Signal.Control -> Deriver a -> Deriver a
with_control_operator cont c_op signal deriver = do
    op <- lookup_control_op c_op
    with_relative_control cont op signal deriver

with_relative_control :: Score.Control -> ControlOp -> Signal.Control
    -> Deriver a -> Deriver a
with_relative_control cont op signal deriver = do
    controls <- gets state_controls
    let msg = "relative control applied when no absolute control is in scope: "
    case Map.lookup cont controls of
        Nothing -> do
            Log.warn (msg ++ show cont)
            deriver
        Just old_signal -> with_control cont (op old_signal signal) deriver

-- | Run the deriver in a context with the given pitch signal.  If a Control is
-- given, the pitch has that name, otherwise it's the unnamed default pitch.
with_pitch :: Maybe Score.Control -> PitchSignal.PitchSignal
    -> Deriver a -> Deriver a
with_pitch = modify_pitch (flip const)

with_constant_pitch :: Maybe Score.Control -> Pitch.Degree
    -> Deriver a -> Deriver a
with_constant_pitch maybe_name degree deriver = do
    pitch <- gets state_pitch
    with_pitch maybe_name
        (PitchSignal.constant (PitchSignal.sig_scale pitch) degree) deriver

with_relative_pitch :: Maybe Score.Control
    -> PitchOp -> PitchSignal.Relative -> Deriver a -> Deriver a
with_relative_pitch maybe_name sig_op signal deriver = do
    old <- gets state_pitch
    if old == PitchSignal.empty
        then do
            -- This shouldn't happen normally because of the default pitch.
            Log.warn
                "relative pitch applied when no absolute pitch is in scope"
            deriver
        else modify_pitch sig_op maybe_name signal deriver

with_pitch_operator :: Maybe Score.Control
    -> TrackLang.CallId -> PitchSignal.Relative -> Deriver a -> Deriver a
with_pitch_operator maybe_name c_op signal deriver = do
    sig_op <- lookup_pitch_control_op c_op
    with_relative_pitch maybe_name sig_op signal deriver

modify_pitch :: (PitchSignal.PitchSignal -> PitchSignal.PitchSignal
        -> PitchSignal.PitchSignal)
    -> Maybe Score.Control -> PitchSignal.PitchSignal
    -> Deriver a -> Deriver a
modify_pitch f Nothing signal = local
    state_pitch (\old st -> st { state_pitch = old })
    (\st -> return $ st { state_pitch = f (state_pitch st) signal })
modify_pitch f (Just name) signal = local
    (Map.lookup name . ps)
    (\old st -> st { state_pitches = Map.alter (const old) name (ps st) })
    (\st -> return $ st { state_pitches = Map.alter alter name (ps st) })
    where
    ps = state_pitches
    alter Nothing = Just signal
    alter (Just old) = Just (f old signal)

-- *** control ops

lookup_control_op :: TrackLang.CallId -> Deriver ControlOp
lookup_control_op c_op = do
    op_map <- gets (state_control_op_map . state_constant)
    maybe (throw ("unknown control op: " ++ show c_op)) return
        (Map.lookup c_op op_map)

lookup_pitch_control_op :: TrackLang.CallId -> Deriver PitchOp
lookup_pitch_control_op c_op = do
    op_map <- gets (state_pitch_op_map . state_constant)
    maybe (throw ("unknown pitch op: " ++ show c_op)) return
        (Map.lookup c_op op_map)

-- *** specializations

velocity_at :: ScoreTime -> Deriver Signal.Y
velocity_at pos = do
    vel <- control_at Score.c_velocity =<< score_to_real pos
    return $ maybe default_velocity id vel

with_velocity :: Signal.Control -> Deriver a -> Deriver a
with_velocity = with_control Score.c_velocity


-- ** with_scope

-- | Run the derivation with a modified scope.
with_scope :: (Scope -> Scope) -> Deriver a -> Deriver a
with_scope modify_scope =
    local state_scope (\old st -> st { state_scope = old })
    (\st -> return $ st { state_scope = modify_scope (state_scope st) })

-- ** stack

get_current_block_id :: Deriver BlockId
get_current_block_id = do
    stack <- gets state_stack
    case [bid | Stack.Block bid <- Stack.innermost stack] of
        [] -> throw "no blocks in stack"
        block_id : _ -> return block_id

-- | Make a quick trick block stack.
with_stack_block :: BlockId -> Deriver a -> Deriver a
with_stack_block = with_stack . Stack.Block

-- | Make a quick trick track stack.
with_stack_track :: TrackId -> Deriver a -> Deriver a
with_stack_track = with_stack . Stack.Track

with_stack_region :: ScoreTime -> ScoreTime -> Deriver a -> Deriver a
with_stack_region s e = with_stack (Stack.Region s e)

with_stack_call :: String -> Deriver a -> Deriver a
with_stack_call name = with_stack (Stack.Call name)

with_stack :: Stack.Frame -> Deriver a -> Deriver a
with_stack frame = local
    state_stack (\old st -> st { state_stack = old }) $ \st -> do
        when (Stack.length (state_stack st) > max_depth) $
            throw $ "call stack too deep: " ++ Pretty.pretty frame
        return $ st { state_stack = Stack.add frame (state_stack st) }
    where max_depth = 30
    -- A recursive loop will result in an unfriendly hang.  So limit the total
    -- nesting depth to catch those.  I could disallow all recursion, but this
    -- is more general.

-- ** track warps

add_track_warp :: TrackId -> Deriver ()
add_track_warp track_id = do
    stack <- gets state_stack
    modify_collect $ \st -> st { collect_warp_map =
        Map.insert stack (Right track_id) (collect_warp_map st) }

-- | Start a new track warp for the current block_id.
--
-- This must be called for each block, and it must be called after the tempo is
-- warped for that block so it can install the new warp.
add_new_track_warp :: Maybe TrackId -> Deriver ()
add_new_track_warp track_id = do
    stack <- gets state_stack
    block_id <- get_current_block_id
    start <- score_to_real 0
    end <- score_to_real =<< get_block_dur block_id
    warp <- gets state_warp
    let tw = Left $ TrackWarp.TrackWarp (start, end, warp, block_id, track_id)
    modify_collect $ \st -> st { collect_warp_map =
        Map.insert stack tw (collect_warp_map st) }


-- * calls

-- | Functions for writing calls.

make_calls :: [(String, call)] -> Map.Map TrackLang.CallId call
make_calls = Map.fromList . map (first TrackLang.Symbol)

-- ** passed args

passed_event :: PassedArgs derived -> Track.PosEvent
passed_event = info_event . passed_info

-- | Get the previous derived val.  This is used by control derivers so they
-- can interpolate from the previous sample.
passed_prev_val :: PassedArgs derived -> Maybe (RealTime, Elem derived)
passed_prev_val args = info_prev_val (passed_info args)

-- | Get the start of the next event, if there is one.  Used by calls to
-- determine their extent, especially control calls, which have no explicit
-- duration.
passed_next_begin :: PassedArgs d -> Maybe ScoreTime
passed_next_begin = fmap fst . Seq.head . info_next_events . passed_info

passed_next :: PassedArgs d -> ScoreTime
passed_next args = case info_next_events info of
        [] -> info_block_end info
        (pos, _) : _ -> pos
    where info = passed_info args

passed_prev_begin :: PassedArgs d -> Maybe ScoreTime
passed_prev_begin = fmap fst . Seq.head . info_prev_events . passed_info

passed_range :: PassedArgs d -> (ScoreTime, ScoreTime)
passed_range args = (pos, pos + Event.event_duration event)
    where (pos, event) = passed_event args

passed_real_range :: PassedArgs d -> Deriver (RealTime, RealTime)
passed_real_range args = (,) <$> score_to_real start <*> score_to_real end
    where (start, end) = passed_range args

-- TODO crummy name, come up with a better one
passed_score :: PassedArgs d -> ScoreTime
passed_score = fst . passed_event

passed_real :: PassedArgs d -> Deriver RealTime
passed_real = score_to_real . passed_score


-- * basic derivers

-- ** tempo

-- | Tempo is the tempo signal, which is the standard musical definition of
-- tempo: trackpos over time.  Warp is the time warping that the tempo
-- implies, which is integral (1/tempo).

score_to_real :: ScoreTime -> Deriver RealTime
score_to_real pos = do
    warp <- gets state_warp
    return (Score.warp_pos pos warp)

real_to_score :: RealTime -> Deriver ScoreTime
real_to_score pos = do
    warp <- gets state_warp
    maybe (throw $ "real_to_score out of range: " ++ show pos) return
        (Score.unwarp_pos pos warp)

d_at :: ScoreTime -> Deriver a -> Deriver a
d_at shift = d_warp (Score.id_warp { Score.warp_shift = shift })

d_stretch :: ScoreTime -> Deriver a -> Deriver a
d_stretch factor = d_warp (Score.id_warp { Score.warp_stretch = factor })

-- | 'd_at' and 'd_stretch' in one.  It's a little faster than using them
-- separately.
d_place :: ScoreTime -> ScoreTime -> Deriver a -> Deriver a
d_place shift stretch = d_warp
    (Score.id_warp { Score.warp_stretch = stretch, Score.warp_shift = shift })

d_warp :: Score.Warp -> Deriver a -> Deriver a
d_warp warp deriver
    | Score.is_id_warp warp = deriver
    | Score.warp_stretch warp <= 0 =
        throw $ "stretch <= 0: " ++ show (Score.warp_stretch warp)
    | otherwise = local state_warp (\w st -> st { state_warp = w })
        (\st -> return $
            st { state_warp = Score.compose_warps (state_warp st) warp })
        deriver

with_warp :: (Score.Warp -> Score.Warp) -> Deriver a -> Deriver a
with_warp f = local state_warp (\w st -> st { state_warp = w }) $ \st ->
    return $ st { state_warp = f (state_warp st) }

in_real_time :: Deriver a -> Deriver a
in_real_time = with_warp (const Score.id_warp)

-- | Shift the controls of a deriver.  You're supposed to apply the warp before
-- deriving the controls, but I don't have a good solution for how to do this
-- yet, so I can leave these here for the moment.
d_control_at :: ScoreTime -> Deriver a -> Deriver a
d_control_at shift deriver = do
    real <- score_to_real shift
    local (\st -> (state_controls st, state_pitch st))
        (\(controls, pitch) st -> st { state_controls = controls,
            state_pitch = pitch })
        (\st -> return $ st
            { state_controls = nudge real (state_controls st)
            , state_pitch = nudge_pitch real (state_pitch st )})
        deriver
    where
    nudge delay = Map.map (Signal.shift delay)
    nudge_pitch = PitchSignal.shift


-- | Warp a block with the given deriver with the given signal.
--
-- TODO what to do about blocks with multiple tempo tracks?  I think it would
-- be best to stretch the block to the first one.  I could break out
-- stretch_to_1 and have compile apply it to only the first tempo track.
d_tempo :: ScoreTime
    -- ^ Used to stretch the block to a length of 1, regardless of the tempo.
    -- This means that when the calling block stretches it to the duration of
    -- the event it winds up being the right length.  This is skipped for the
    -- top level block or all pieces would last exactly 1 second.  This is
    -- another reason every block must have a 'd_tempo' at the top.
    --
    -- TODO relying on the stack seems a little implicit, would it be better
    -- to pass Maybe BlockId or Maybe ScoreTime?
    --
    -- 'Derive.Call.Block.d_block' might seem like a better place to do this,
    -- but it doesn't have the local warp yet.
    -> Maybe TrackId
    -- ^ Needed to record this track in TrackWarps.  It's optional because if
    -- there's no explicit tempo track there's an implicit tempo around the
    -- whole block, but the implicit one doesn't have a track of course.
    -> Signal.Tempo -> Deriver a -> Deriver a
d_tempo block_dur maybe_track_id signal deriver = do
    let warp = tempo_to_warp signal
    root <- is_root_block
    stretch_to_1 <- if root then return id
        else do
            real_dur <- with_warp (const warp) (score_to_real block_dur)
            -- Log.debug $ "dur, global dur "
            --     ++ show (block_id, block_dur, real_dur)
            when (block_dur == 0) $
                throw "can't derive a block with zero duration"
            return (d_stretch (1 / RealTime.to_score real_dur))
    stretch_to_1 $ d_warp warp $ do
        add_new_track_warp maybe_track_id
        deriver

is_root_block :: Deriver Bool
is_root_block = do
    stack <- gets state_stack
    let blocks = [bid | Stack.Block bid <- Stack.outermost stack]
    return $ case blocks of
        [] -> True
        [_] -> True
        _ -> False

-- | Sub-derived blocks are stretched according to their length, and this
-- function defines the length of a block.  'State.block_event_end' seems the
-- most intuitive, but then you can't make blocks with trailing space.  You
-- can work around it though by appending a comment dummy event.
get_block_dur :: BlockId -> Deriver ScoreTime
get_block_dur block_id = do
    ui_state <- get_ui_state
    either (throw . ("get_block_dur: "++) . show) return
        (State.eval ui_state (State.block_event_end block_id))

tempo_to_warp :: Signal.Tempo -> Score.Warp
tempo_to_warp sig
    -- Optimize for a constant (or missing) tempo.
    | Signal.is_constant sig =
        let stretch = 1 / max min_tempo (Signal.at 0 sig)
        in Score.Warp Score.id_warp_signal 0 (Signal.y_to_score stretch)
    | otherwise = Score.Warp warp_sig 0 1
    where
    warp_sig = Signal.integrate Signal.tempo_srate $ Signal.map_y (1/) $
         Signal.clip_min min_tempo sig

min_tempo :: Signal.Y
min_tempo = 0.001


-- ** track

-- | This does setup common to all track derivation, namely recording the
-- tempo warp, and then calls the specific track deriver.  Every track except
-- tempo tracks should be wrapped with this.
track_setup :: TrackId -> Deriver d -> Deriver d
track_setup track_id deriver = add_track_warp track_id >> deriver

-- | This is a version of 'track_setup' for the tempo track.  It doesn't
-- record the track warp, see 'd_tempo' for why.
setup_without_warp :: Deriver d -> Deriver d
setup_without_warp = in_real_time


-- * utils

get_ui_state :: Deriver State.State
get_ui_state = gets (state_ui . state_constant)

-- | Because Deriver is not a UiStateMonad.
--
-- TODO I suppose it could be, but then I'd be tempted to make
-- a ReadOnlyUiStateMonad.  And I'd have to merge the exceptions.
get_track :: TrackId -> Deriver Track.Track
get_track track_id = lookup_id track_id . State.state_tracks =<< get_ui_state

get_block :: BlockId -> Deriver Block.Block
get_block block_id = lookup_id block_id . State.state_blocks =<< get_ui_state

-- | Lookup @map!key@, throwing if it doesn't exist.
lookup_id :: (Ord k, Show k) => k -> Map.Map k a -> Deriver a
lookup_id key map = case Map.lookup key map of
    Nothing -> throw $ "unknown " ++ show key
    Just val -> return val

-- | So this is kind of confusing.  When events are created, they are assigned
-- their stack based on the current event_stack, which is set by the
-- with_stack_* functions.  Then, when they are processed, the stack is used
-- to *set* event_stack, which is what 'Log.warn' and 'throw' will look at.
with_event :: Score.Event -> Deriver a -> Deriver a
with_event event = local state_stack
    (\old st -> st { state_stack = old })
    (\st -> return $ st { state_stack = Score.event_stack event })


-- ** merge

-- | The EventDerivers run as sub-derivers and the results are mappended, which
-- lets them to interleave their work or run in parallel.
d_merge :: [EventDeriver] -> EventDeriver
d_merge [d] = d -- TODO this optimization lets exceptions through... do I care?
d_merge derivers = do
    state <- get
    -- Since track warp mappend is plain concat, if I don't clear the collect
    -- I will get duplicate entries.
    let cleared = state { state_collect = mempty }
    let (streams, collects, caches) =
            List.unzip3 (map (run_sub cleared) derivers)
    modify $ \st -> st
        { state_collect = Monoid.mconcat (state_collect state : collects)
        , state_cache_state = Monoid.mconcat caches
        }
    return (Seq.merge_lists _event_start streams)

type PureResult d = (Stream (LEvent.LEvent d), Collect, CacheState)

-- | Run the given deriver and return the relevant data.
run_sub :: State -> LogsDeriver derived -> PureResult derived
run_sub state deriver =
    (merge_logs result logs, state_collect state2, state_cache_state state2)
    where (result, state2, logs) = run state deriver

merge_logs :: Either DeriveError (LEvent.LEvents d) -> [Log.Msg]
    -> LEvent.LEvents d
merge_logs result logs = case result of
    Left err -> map LEvent.Log (logs ++ [error_to_warn err])
    Right events -> events ++ map LEvent.Log logs

-- | Merge sorted lists of events.  If the lists themselves are also sorted,
-- I can produce output without scanning the entire input list, so this should
-- be more efficient for a large input list than 'merge_events'.
merge_asc_events :: [Events] -> Events
merge_asc_events = Seq.merge_asc_lists _event_start

merge_events :: Events -> Events -> Events
merge_events = Seq.merge_on _event_start

-- | This will make logs always merge ahead of score events, but that should
-- be ok.
_event_start :: LEvent.LEvent Score.Event -> RealTime
_event_start (LEvent.Log _) = 0
_event_start (LEvent.Event event) = Score.event_start event

-- -- | unused monoidal interface
-- instance Monoid.Monoid EventDeriver where
--     mempty = return empty_stream
--     mappend d1 d2 = d_merge [d1, d2]
--     mconcat = d_merge


-- * negative duration

-- process_negative_durations :: Events -> Events
-- process_negative_durations = id

{- TODO put this in its own module

-- TODO if I wind up going with the postproc route, this should probably become
-- bound to a special toplevel postproc symbol so it can be changed or turned
-- off

-- | Notes with negative duration have an implicit sounding duration which
-- depends on the following note.  Meanwhile (and for the last note of the
-- score), they have this sounding duration.
negative_duration_default :: RealTime
negative_duration_default = 1

-- | Post-process events to replace negative durations with positive ones.
process_negative_durations :: [Score.Event] -> [Score.Event]
process_negative_durations [] = []
process_negative_durations (evt:evts) = evt2 : process_negative_durations evts
    where
    next = find_next evt evts
    dur = calculate_duration (pos_dur evt) (fmap pos_dur next)
    evt2 = if dur == Score.event_duration evt then evt
        else evt { Score.event_duration = dur }
    pos_dur evt = (Score.event_start evt, Score.event_duration evt)

find_next :: Score.Event -> [Score.Event] -> Maybe Score.Event
find_next from = List.find (next_in_track from_stack . Score.event_stack)
    where from_stack = Score.event_stack from

-- | Is the second stack from an event that occurs later on the same track as
-- the first?  This is more complicated than it may seem at first because the
-- second event could come from a different deriver.  So it should look like
-- @same ; same ; bid same / tid same / higher ; *@.
next_in_track :: Warning.Stack -> Warning.Stack -> Bool
next_in_track (s0@(bid0, tid0, r0) : stack0) (s1@(bid1, tid1, r1) : stack1)
    | s0 == s1 = next_in_track stack0 stack1
    | bid0 == bid1 && tid0 == tid1 && r0 `before` r1 = True
    | otherwise = False
    where
    before (Just (s0, _)) (Just (s1, _)) = s0 < s1
    before _ _ = False
next_in_track _ _ = True

calculate_duration :: (RealTime, RealTime) -> Maybe (RealTime, RealTime)
    -> RealTime
calculate_duration (cur_pos, cur_dur) (Just (next_pos, next_dur))
        -- Departing notes are not changed.
    | cur_dur > 0 = cur_dur
        -- Arriving followed by arriving with a rest in between extends to
        -- the arrival of the rest.
    | next_dur <= 0 && rest > 0 = rest
        -- Arriving followed by arriving with no rest, or an arriving note
        -- followed by a departing note will sound until the next note.
    | otherwise = next_pos - cur_pos
    where
    rest = next_pos + next_dur - cur_pos
calculate_duration (_, dur) Nothing
    | dur > 0 = dur
    | otherwise = negative_duration_default

-}
