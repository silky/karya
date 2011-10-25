{-# LANGUAGE CPP, OverloadedStrings #-}
module Derive.Cache (
    caching_call
    , get_control_damage, get_tempo_damage

#ifdef TESTING
    , find_generator_cache
#endif
) where
import Control.Monad
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import Util.Control
import qualified Util.Log as Log
import qualified Util.Ranges as Ranges
import qualified Util.Seq as Seq

import Ui
import qualified Ui.Events as Events
import qualified Ui.Track as Track

import qualified Derive.Derive as Derive
import Derive.Derive
       (Cache(..), Cached(..), ScoreDamage(..), ControlDamage(..))
import qualified Derive.Deriver.Internal as Internal
import qualified Derive.LEvent as LEvent
import qualified Derive.Stack as Stack


-- * caching_call

-- | If the given generator has a cache entry, relevant derivation context is
-- the same as the cache entry's, and there is no damage under the generator,
-- I can reuse the cached values for it.  This is effectively a kind of
-- memoization.  If the generator is called, the results will be put in the
-- cache before being returned.
caching_call :: (Derive.PassedArgs d -> Derive.EventDeriver)
    -> (Derive.PassedArgs d -> Derive.EventDeriver)
caching_call call args = do
    st <- Derive.get
    let cdamage = Derive.state_control_damage (Derive.state_dynamic st)
        sdamage = Derive.state_score_damage (Derive.state_constant st)
        stack = Derive.state_stack (Derive.state_dynamic st)
    generate stack $ find_generator_cache stack
        (uncurry Ranges.range (Derive.passed_track_range args))
        sdamage cdamage (Derive.state_cache (Derive.state_constant st))
    where
    generate _ (Right (collect, cached)) = do
        Log.debug $ "using cache (" ++ show (LEvent.length cached) ++ " vals)"
        -- The cached deriver must return the same collect as it would if it
        -- had been actually derived.
        Internal.merge_collect collect
        return cached
    generate stack (Left reason) = do
        (result, collect) <- with_collect (call args)
        Log.notice $ "rederived generator because of "
            -- This destroys laziness, though I'm not sure why since the
            -- log msg shouldn't be forced until the msgs already have been
            -- forced themselves.
            -- ++ show (LEvent.length stream) ++ " vals) because of "
            ++ reason
        Internal.merge_collect $
            mempty { Derive.collect_cache = make_cache stack collect result }
        return result

    -- To get the deps of just the deriver below me, I have to clear out
    -- the local deps.  But this call is itself collecting deps for another
    -- call, so I have to merge the sub-deps back in before returning.
    with_collect deriver = do
        -- TODO Do I want to run deriver a sub derivation so I can put an
        -- empty cache if it failed?  Otherwise I think maybe a failed
        -- event will continue to produce its old value.
        (result, collect) <- Internal.with_empty_collect deriver
        Derive.modify $ \st ->
            st { Derive.state_collect = collect <> Derive.state_collect st }
        return (result, collect)

find_generator_cache :: (Derive.Derived derived) =>
    Stack.Stack -> Ranges.Ranges ScoreTime -> ScoreDamage -> ControlDamage
    -> Cache -> Either String (Derive.Collect, LEvent.LEvents derived)
find_generator_cache stack event_range score_damage
        (ControlDamage control_damage) (Cache cache) = do
    cached <- maybe (Left "not in cache") Right (Map.lookup stack cache)
    (collect, stream) <- case cached of
        Invalid -> Left "cached invalidated by score damage"
        Cached entry -> maybe (Left "cached entry has wrong type") Right
            (Derive.from_cache_entry entry)
    let Derive.GeneratorDep block_deps = Derive.collect_local_dep collect
    let damaged_blocks = Set.union
            (sdamage_track_blocks score_damage) (sdamage_blocks score_damage)
    case msum (map Stack.block_of (Stack.innermost stack)) of
        Just this_block | this_block `Set.member` damaged_blocks ->
            Left "block damage"
        _ -> return ()
    unless (Set.null (Set.intersection damaged_blocks block_deps)) $
        Left "sub-block damage"
    when (Ranges.overlapping control_damage event_range) $
        Left "control damage"
    return (collect, stream)

make_cache :: (Derive.Derived d) => Stack.Stack -> Derive.Collect
    -> LEvent.LEvents d -> Cache
make_cache stack collect stream = Cache $ Map.singleton stack (Cached entry)
    where
    -- TODO clear out other bits of cache that this overlaps with
    stripped = collect { Derive.collect_cache = mempty }
    entry = Derive.to_cache_entry (stripped, filter (not . cache_log) stream)
    -- I do want a cached chunk to retain its log msgs, since those include
    -- errors deriving.  However, it's confusing if it also includes cache
    -- msgs because then it looks like it wasn't cached after all.
    -- It's unfortunate that I have to copy the chunk, but it's either this
    -- or a more complicated filtering scheme later on, which is bound to
    -- be just a filter too.  At least this way it only happens once.
    cache_log (LEvent.Log msg) =
        prefix "using cache " || prefix "rederived generator because of"
        where prefix = (`Text.isPrefixOf` Log.msg_text msg)
    cache_log _ = False


-- * get_control_damage

-- | ControlDamage works in this manner:
--
-- ScoreDamage on a control track is expanded to include the previous to the
-- next event, since control calls generally generate samples based on their
-- previous event, and possibly the next one.  Since control tracks may depend
-- on other control tracks, controls beneath the damaged one will also expand
-- the damage to include previous and next events in the same way.
--
-- The way the damage is calculated is complicated.  Firstly, a track with
-- no ControlDamage in scope has its ControlDamage calculated from the
-- ScoreDamage (this is guaranteed to be a control track simply because this
-- function is only called by control tracks).  TODO I don't think there's
-- a particular need to do it here, it might be nicer to do it once at the top
-- and skip this step.  Secondly, given some ControlDamage, the range must be
-- expanded to the neighbor events.  This is because controls can depend on
-- other controls, so a certain range of ControlDamage may cause other
-- controls to rederived.
get_control_damage :: TrackId
    -> (ScoreTime, ScoreTime) -- ^ track_range must be passed explicitly
    -- because the event may have been sliced and shifted, but ControlDamage
    -- should be relative to the start of the track at ScoreTime 0.
    -> Derive.Deriver ControlDamage
get_control_damage track_id track_range = do
    st <- Derive.get
    let control = Derive.state_control_damage (Derive.state_dynamic st)
        score = Derive.state_score_damage (Derive.state_constant st)
    extend_damage track_id track_range $ if control == mempty
        then score_to_control track_id track_range score else control

-- | Since the warp is the integral of the tempo track, damage on the tempo
-- track will affect all events after it.
get_tempo_damage :: TrackId -> (ScoreTime, ScoreTime)
    -> Derive.Deriver ControlDamage
get_tempo_damage track_id track_range = do
    st <- Derive.get
    let control = Derive.state_control_damage (Derive.state_dynamic st)
        score = Derive.state_score_damage (Derive.state_constant st)
    return $ extend $ if control == mempty
        then score_to_control track_id track_range score else control
    where
    extend (Derive.ControlDamage ranges) = Derive.ControlDamage $
        case Ranges.extract ranges of
            Nothing -> Ranges.everything
            Just [] -> Ranges.nothing
            Just ((s, _) : _) -> Ranges.range s (snd track_range)

-- | Convert score damage directly to ControlDamage on a given track.
score_to_control :: TrackId -> (ScoreTime, ScoreTime) -> ScoreDamage
    -> ControlDamage
score_to_control track_id track_range score =
    ControlDamage $ in_range $ maybe Ranges.nothing id $
        Map.lookup track_id (Derive.sdamage_tracks score)
    where in_range = Ranges.intersection $ uncurry Ranges.range track_range

-- | Extend the given ControlDamage as described in 'get_control_damage'.
-- Somewhat tricky because I also want to clip the damage to the track range,
-- if any.  This is so a sliced control track below an unsliced one won't
-- bother figuring out damage outside its range.
extend_damage :: TrackId -> (ScoreTime, ScoreTime) -> ControlDamage
    -> Derive.Deriver ControlDamage
extend_damage track_id (track_s, track_e) (ControlDamage damage)
    | damage == mempty = return mempty
    | otherwise = do
        events <- Track.track_events <$> Derive.get_track track_id
        -- Empty tracks could not have contributed to further damage.
        return $ if events == Events.empty then ControlDamage damage
            else ControlDamage (extend events damage)
    where
    extend events = Ranges.fmap (extend1 events)
    extend1 events (s, e)
        | s >= track_s && e <= track_e =
            Just (event_at_before s events, event_after e events)
        | otherwise = Nothing
    event_at_before p events = case Events.split p events of
        (_, (at, _) : _) | p == at -> p
        ((prev, _) : _, _) -> prev
        _ -> p
    event_after p events = maybe track_e fst $ Seq.head (Events.after p events)
