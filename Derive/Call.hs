{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
{- | Basic module for call evaluation.

    It should also have Deriver utilities that could go in Derive, but are more
    specific to calls.

    It used to be that events were evaluated in \"normalized time\", which to
    say each one was shifted and stretched into place so that it always
    begins at 0t and ends at 1t.  While elegant, this was awkward in
    practice.  Some calls take ScoreTimes as arguments, and for those to
    be in the track's ScoreTime they have to be warped too.  Calls that
    look at the time of the next event on the track must warp that too.
    The result is that calls have to work in two time references
    simultaneously, which is confusing.  But the main thing is that note
    calls with subtracks need to slice the relevant events out of the
    subtracks, and those events are naturally in track time.  So the slice
    times would have to be unwarped, and then the sliced events warped.
    It was too complicated.

    Now events are evaluated in track time.  Block calls still warp the
    call into place, so blocks are still in normalized time, but other
    calls must keep track of their start and end times.

    The way expression evaluation works is a little irregular.  The toplevel
    expression returns a parameterized deriver, so this part of the type is
    exported to the haskell type system.  The values and non-toplevel calls
    return dynamically typed Vals though.  The difference between a generator
    and a transformer is that the latter takes an extra deriver arg, but since
    the type of the deriver is statically determined at the haskell level, it
    isn't passed as a normal arg but is instead hardcoded into the evaluation
    scheme for the toplevel expression.  So only the toplevel calls can take
    and return derivers.

    I experimented with a system that added a VDeriver type, but there were
    several problems:

    - If I don't parameterize Val I wind up with separate VEventDeriver,
    VPitchDeriver, etc. constructors.  Every call that takes a deriver must
    validate the type and there is no static guarantee that event deriver
    calls won't wind up the pitch deriver symbol table.  It seems nice that
    the CallMap and Environ can all be replaced with a single symbol table,
    but in practice they represent different scopes, so they would need to be
    separated anyway.

    - If I do parameterize Val, I need some complicated typeclass gymnastics
    and a lot of redundant Typecheck instances to make the new VDeriver type
    fit in with the calling scheme.  I have to differentiate PassedVals, which
    include VDeriver, from Vals, which don't, so Environ can remain
    unparameterized.  Otherwise I would need a separate Environ per track, and
    copy over vals which should be shared, like srate.  The implication is
    that Environ should really have dynamically typed deriver vals.

    - Replacing @a | b | c@ with @a (b (c))@ is appealing, but if the deriver
    is the final argument then I have a problem where a required argument wants
    to follow an optional one.  Solutions would be to implement some kind of
    keyword args that allow the required arg to remain at the end, or simply
    put it as the first arg, so that @a 1 | b 2 | c 3@ is sugar for
    @a (b (c 3) 2) 1@.

    - But, most importantly, I don't have a clear use for making derivers first
    class.  Examples would be:

        * A call that takes two derivers: @do-something (block1) (block2)@.
        I can't think of a @do-something@.

        * Derivers in the environment: @default-something = (block1)@.  I
        can't think of a @default-something@.

    I could move more in the direction of a real language by unifying all
    symbols into Environ, looking up Symbols in @eval@, and making a VCall
    type.  That way I could rebind calls with @tr = absolute-trill@ or
    do argument substitution with @d = (block1); transpose 1 | d@.  However,
    I don't have any uses in mind for that, and /haskell/ is supposed to be
    the real language.  I should focus more on making it easy to write your own
    calls in haskell.
-}
module Derive.Call where
import qualified Data.ByteString.Char8 as B

import Util.Control
import qualified Util.Log as Log
import qualified Util.Seq as Seq

import qualified Ui.Event as Event
import qualified Ui.TrackTree as TrackTree
import qualified Derive.CallSig as CallSig
import qualified Derive.Derive as Derive
import qualified Derive.Deriver.Internal as Internal
import qualified Derive.LEvent as LEvent
import qualified Derive.ParseBs as Parse
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang

import Types


-- * eval

-- | Evaluate a single note as a generator.  Fake up an event with no prev or
-- next lists.
eval_one :: (Derive.Derived d) => TrackLang.Expr -> Derive.LogsDeriver d
eval_one = eval_one_at 0 1

eval_one_call :: (Derive.Derived d) => TrackLang.Call -> Derive.LogsDeriver d
eval_one_call = eval_one . (:| [])

eval_one_at :: (Derive.Derived d) => ScoreTime -> ScoreTime -> TrackLang.Expr
    -> Derive.LogsDeriver d
eval_one_at start dur expr = eval_expr cinfo expr
    where
    -- Set the event start and duration instead of using Derive.d_place since
    -- this way I can have zero duration events.
    cinfo = Derive.dummy_call_info start dur
        ("eval_one: " ++ TrackLang.show_val expr)

-- | Apply an expr with the current call info.
reapply :: (Derive.Derived d) => Derive.PassedArgs d -> TrackLang.Expr
    -> Derive.LogsDeriver d
reapply args expr = eval_expr (Derive.passed_info args) expr

reapply_call :: (Derive.Derived d) => Derive.PassedArgs d -> TrackLang.Call
    -> Derive.LogsDeriver d
reapply_call args call = reapply args (call :| [])

-- | A version of 'eval' specialized to evaluate note calls.
eval_note :: TrackLang.Note -> Derive.Deriver PitchSignal.Pitch
eval_note note = CallSig.cast ("eval note " ++ show note)
    =<< eval (TrackLang.note_call note)

-- | Evaluate a single expression.
eval_expr :: (Derive.Derived d) => Derive.CallInfo d -> TrackLang.Expr
    -> Derive.LogsDeriver d
eval_expr cinfo expr = do
    state <- Derive.get
    let (res, logs, collect) = apply_toplevel state cinfo expr
    -- I guess this could set collect to mempty and then merge it back in,
    -- but I think this is the same with less work.
    Derive.modify $ \st -> st { Derive.state_collect = collect }
    return $ Derive.merge_logs res logs

-- * derive_track

-- | Just a spot to stick all the per-track parameters.
data TrackInfo = TrackInfo {
    -- | Either the end of the block, or the next event after the slice.
    -- These fields are take directly from 'State.TrackEvents'.
    tinfo_events_end :: !ScoreTime
    , tinfo_track_range :: !(ScoreTime, ScoreTime)
    , tinfo_shifted :: !ScoreTime
    , tinfo_sub_tracks :: !TrackTree.EventsTree
    , tinfo_events_around :: !([Event.Event], [Event.Event])
    }

type GetLastSample d =
    Maybe (RealTime, Derive.Elem d) -> d -> Maybe (RealTime, Derive.Elem d)

-- | This is the toplevel function to derive a track.  It's responsible for
-- actually evaluating each event.
--
-- There's a certain amount of hairiness in here because note and control
-- tracks are mostly but not quite the same and because calls get a lot of
-- auxiliary data in 'Derive.CallInfo'.
derive_track :: forall d. (Derive.Derived d) =>
    -- forall and ScopedTypeVariables needed for the inner 'go' signature
    Derive.State -> TrackInfo -> Parse.ParseExpr
    -> GetLastSample d -> [Event.Event]
    -> ([LEvent.LEvents d], Derive.Collect)
derive_track state tinfo parse get_last_sample events =
    go (Internal.record_track_dynamic state) Nothing "" [] events
    where
    -- This threads the collect through each event.  I would prefer to map and
    -- mconcat, but it's also quite a bit slower.
    go :: Derive.Collect -> Maybe (RealTime, Derive.Elem d)
        -> B.ByteString -> [Event.Event] -> [Event.Event]
        -> ([LEvent.LEvents d], Derive.Collect)
    go collect _ _ _ [] = ([], collect)
    go collect prev_sample repeat_call prev (cur : rest) =
        (events : rest_events, final_collect)
        where
        (result, logs, next_collect) =
            -- trace ("derive " ++ show_pos state (fst cur) ++ "**") $
            derive_event (state { Derive.state_collect = collect })
                tinfo parse prev_sample repeat_call prev cur rest
        (rest_events, final_collect) =
            go next_collect next_sample next_repeat_call (cur : prev) rest
        events = map LEvent.Log logs ++ case result of
            Right stream -> stream
            Left err -> [LEvent.Log (Derive.error_to_warn err)]
        next_sample = case result of
            Right derived ->
                case Seq.last (mapMaybe LEvent.event derived) of
                    Just elt -> get_last_sample prev_sample elt
                    Nothing -> prev_sample
            Left _ -> prev_sample
        next_repeat_call =
            repeat_call_of repeat_call (Event.event_bytestring cur)

-- Used with trace to observe laziness.
-- show_pos :: Derive.State -> ScoreTime -> String
-- show_pos state pos = stack ++ ": " ++ Pretty.pretty now
--     where
--     now = Score.warp_pos pos (Derive.state_warp state)
--     stack = Seq.join ", " $ map Stack.unparse_ui_frame $
--         Stack.to_ui (Derive.state_stack state)

derive_event :: (Derive.Derived d) =>
    Derive.State -> TrackInfo -> Parse.ParseExpr
    -> Maybe (RealTime, Derive.Elem d)
    -> B.ByteString -- ^ repeat call, substituted with @\"@
    -> [Event.Event] -- ^ previous events, in reverse order
    -> Event.Event -- ^ cur event
    -> [Event.Event] -- ^ following events
    -> (Either Derive.Error (LEvent.LEvents d), [Log.Msg], Derive.Collect)
derive_event st tinfo parse prev_sample repeat_call prev event next
    | text == "--" = (Right mempty, [], Derive.state_collect st)
    | otherwise = case parse (substitute_repeat repeat_call text) of
        Left err -> (Right mempty, [parse_error err], Derive.state_collect st)
        Right expr -> run_call expr
    where
    text = Event.event_bytestring event
    parse_error = Log.msg Log.Warn $
        Just (Stack.to_strings (Derive.state_stack (Derive.state_dynamic st)))
    run_call expr = apply_toplevel state (cinfo expr) expr
    state = st
        { Derive.state_dynamic = (Derive.state_dynamic st)
            { Derive.state_stack = Stack.add
                (region (Event.min event) (Event.max event))
                (Derive.state_stack (Derive.state_dynamic st))
            }
        }
    cinfo expr = Derive.CallInfo
        { Derive.info_expr = expr
        , Derive.info_prev_val = prev_sample
        , Derive.info_event = event
        -- Augment prev and next with the unevaluated "around" notes from
        -- 'State.tevents_around'.
        , Derive.info_prev_events = fst around ++ prev
        , Derive.info_next_events = next ++ snd around
        , Derive.info_event_end = case next of
            [] -> events_end
            event : _ -> Event.start event
        , Derive.info_track_range = track_range
        , Derive.info_sub_tracks = subs
        }
    region s e = Stack.Region (shifted + s) (shifted + e)
    TrackInfo events_end track_range shifted subs around = tinfo

-- | Replace @\"@ with the previous non-@\"@ call, if there was one.
--
-- Another approach would be to have @\"@ as a plain call that looks at
-- previous events.  However I would have to unparse the args to re-eval,
-- and would have to do the same macro expansion stuff as I do here.
substitute_repeat :: B.ByteString -> B.ByteString -> B.ByteString
substitute_repeat prev text
    | B.null prev = text
    | text == B.singleton '"' = prev
    | B.takeWhile (/=' ') text == "\"" =
        B.takeWhile (/=' ') prev <> B.drop 1 text
    | otherwise = text

repeat_call_of :: B.ByteString -> B.ByteString -> B.ByteString
repeat_call_of prev cur
    | not (B.null cur) && B.takeWhile (/=' ') cur /= "\"" = cur
    | otherwise = prev

-- | Apply a toplevel expression.
apply_toplevel :: (Derive.Derived d) => Derive.State -> Derive.CallInfo d
    -> TrackLang.Expr
    -> (Either Derive.Error (LEvent.LEvents d), [Log.Msg], Derive.Collect)
apply_toplevel state cinfo expr = case Seq.ne_viewr expr of
        (transform_calls, generator_call) -> run $
            apply_transformer cinfo transform_calls $
                apply_generator cinfo generator_call
    where
    run d = case Derive.run state d of
        (result, state, logs) -> (result, logs, Derive.state_collect state)

apply_generator :: forall d. (Derive.Derived d) => Derive.CallInfo d
    -> TrackLang.Call -> Derive.LogsDeriver d
apply_generator cinfo (TrackLang.Call call_id args) = do
    maybe_call <- Derive.lookup_callable call_id
    (call, vals) <- case maybe_call of
        Just call -> do
            vals <- mapM eval args
            return (call, vals)
        -- If I didn't find a call, look for a val call and pass its result to
        -- "".  This is what makes pitch tracks work, since scales are val
        -- calls.
        Nothing -> do
            -- Use the outer name, not val call's "val", otherwise every failed
            -- lookup says it's a failed val lookup.
            vcall <- require_call call_id name
                =<< Derive.lookup_val_call call_id
            val <- apply call_id vcall args
            -- We only do this fallback thing once.
            call <- get_call fallback_call_id
            return (call, [val])

    let args = Derive.PassedArgs vals call_id cinfo
        with_stack = Internal.with_stack_call (Derive.call_name call)
    with_stack $ case Derive.call_generator call of
        Just gen -> Derive.generator_func gen args
        Nothing -> Derive.throw $ "non-generator in generator position: "
            ++ Derive.call_name call
    where
    name = Derive.callable_name
        (error "Derive.callable_name shouldn't evaluate its argument." :: d)

apply_transformer :: (Derive.Derived d) => Derive.CallInfo d
    -> [TrackLang.Call] -> Derive.LogsDeriver d
    -> Derive.LogsDeriver d
apply_transformer _ [] deriver = deriver
apply_transformer cinfo (TrackLang.Call call_id args : calls) deriver = do
    vals <- mapM eval args
    let new_deriver = apply_transformer cinfo calls deriver
    call <- get_call call_id
    let args = Derive.PassedArgs vals call_id cinfo
        with_stack = Internal.with_stack_call (Derive.call_name call)
    with_stack $ case Derive.call_transformer call of
        Just trans -> Derive.transformer_func trans args new_deriver
        Nothing -> Derive.throw $ "non-transformer in transformer position: "
            ++ Derive.call_name call

eval :: TrackLang.Term -> Derive.Deriver TrackLang.Val
eval (TrackLang.Literal val) = return val
eval (TrackLang.ValCall (TrackLang.Call call_id terms)) = do
    call <- get_val_call call_id
    apply call_id call terms

apply :: TrackLang.CallId -> Derive.ValCall -> [TrackLang.Term]
    -> Derive.Deriver TrackLang.Val
apply call_id call args = do
    vals <- mapM eval args
    let args = Derive.PassedArgs vals call_id
            (Derive.dummy_call_info 0 1 "val-call")
    Derive.with_msg ("val call " ++ Derive.vcall_name call) $
        Derive.vcall_call call args

get_val_call :: TrackLang.CallId -> Derive.Deriver Derive.ValCall
get_val_call call_id =
    require_call call_id "val" =<< Derive.lookup_val_call call_id

get_call :: forall d. (Derive.Derived d) =>
    TrackLang.CallId -> Derive.Deriver (Derive.Call d)
get_call call_id = require_call call_id name =<< Derive.lookup_callable call_id
    where
    name = Derive.callable_name
        (error "Derive.callable_name shouldn't evaluate its argument." :: d)

require_call :: TrackLang.CallId -> String -> Maybe a -> Derive.Deriver a
require_call call_id name =
    maybe (Derive.throw (unknown_call_id name call_id)) return

unknown_call_id :: String -> TrackLang.CallId -> String
unknown_call_id name call_id =
    name ++ " call not found: " ++ TrackLang.show_val call_id

fallback_call_id :: TrackLang.CallId
fallback_call_id = TrackLang.Symbol ""
