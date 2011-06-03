{- | Take Updates, which are generated by 'Ui.Diff', and send them to the UI.

    The C++ level and BlockC have no notion of "blocks" which may be shared
    between block views.  The haskell State does have this notion, so it's this
    module's job to distribute an operation on a block to all of the C++ block
    views that are displaying that block.

    So if this module has a bug, two views of one block could get out of sync
    and display different data.  Hopefully that won't happen.

    Implementation of merged tracks:

    They need to be implemented in two places: 1. when a block is updated with
    changed merged tracks, and 2. when a track is updated they should be
    preserved.  It's tricky because unlike normal track events, they are block
    level, not track level, so the same track in different blocks may be merged
    with different events.  I don't actually see a lot of use-case for the same
    track in different blocks, but as long as I have it, it makes sense that it
    can have different merges in different blocks, since it's really
    a display-level effect.

    This is a hassle because case 1 has to go hunt down the event info and case
    2 has to go hunt down the per-block info, but such is life.
-}
module Ui.Sync (
    sync
    , set_track_signals
    , set_play_position, clear_play_position
) where
import Control.Monad
import qualified Control.Monad.Trans as Trans
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe

import Util.Control
import qualified Util.Log as Log
import qualified Util.Seq as Seq

import Ui
import qualified Ui.Block as Block
import qualified Ui.BlockC as BlockC
import qualified Ui.State as State
import qualified Ui.Track as Track
import qualified Ui.Types as Types
import qualified Ui.Ui as Ui
import qualified Ui.Update as Update

import qualified App.Config as Config


-- | Sync with the ui by applying the given updates to it.
sync :: State.State -> [Update.Update] -> IO (Maybe State.StateError)
sync state updates = do
    -- TODO: TrackUpdates can overlap.  Merge them together here.
    -- Technically I can also cancel out all TrackUpdates that only apply to
    -- newly created views, but this optimization is probably not worth it.
    result <- State.run state $ do_updates (Update.sort updates)
    -- Log.timer $ "synced updates: " ++ show (length updates)
    return $ case result of
        Left err -> Just err
        -- I reuse State.StateT for convenience, but run_update should
        -- not modify the State and hence shouldn't produce any updates.
        -- TODO Try to split StateT into ReadStateT and ReadWriteStateT to
        -- express this in the type?
        Right _ -> Nothing

do_updates :: [Update.Update] -> State.StateT IO ()
do_updates updates = do
    actions <- mapM run_update updates
    -- Trans.liftIO $ putStrLn ("run updates: " ++ show updates)
    Trans.liftIO (Ui.send_action (sequence_ actions))

set_track_signals :: State.State -> Track.TrackSignals -> IO ()
set_track_signals state track_signals = do
    case State.eval state tracknums of
        Left err ->
            -- This could happen if track_signals had a stale track_id.  That
            -- could happen if I deleted a track before the deriver came back
            -- with its signal.
            -- TODO but I should just filter out the bad track_id in that case
            Log.warn $ "getting tracknums of track_signals: " ++ show err
        Right val -> Ui.send_action $ forM_ val $
            \(view_id, tracknum, tsig) ->
                BlockC.set_track_signal view_id tracknum tsig
    where
    tracknums :: State.StateId [(ViewId, TrackNum, Track.TrackSignal)]
    tracknums =
        fmap concat $ forM (Map.assocs track_signals) $ \(track_id, tsig) ->
            tracknums_of track_id tsig
    tracknums_of track_id tsig = do
        blocks <- State.blocks_with_track track_id
        fmap concat $ forM blocks $ \(block_id, tracks) -> do
            view_ids <- Map.keys <$> State.get_views_of block_id
            return [(view_id, tracknum, tsig)
                | (tracknum, Block.TId tid _) <- tracks,
                    tid == track_id, view_id <- view_ids]

-- | The play position selection bypasses all the usual State -> Diff -> Sync
-- stuff for a direct write to the UI.
--
-- This is because it happens asynchronously and would be noisy and inefficient
-- to work into the responder loop, and isn't part of the usual state that
-- should be saved anyway.
set_play_position :: [(ViewId, [(TrackNum, Maybe ScoreTime)])] -> IO ()
set_play_position block_sels = Ui.send_action $ sequence_
    [ BlockC.set_track_selection False view_id
        Config.play_position_selnum tracknum (sel_at pos)
    | (view_id, track_pos) <- block_sels, (tracknum, pos) <- track_pos
    ]
    where
    sel_at maybe_pos = case maybe_pos of
        Nothing -> Nothing
        Just pos -> Just $ BlockC.CSelection Config.play_position_color
            (Types.Selection 0 pos 0 pos)

clear_play_position :: ViewId -> IO ()
clear_play_position view_id = Ui.send_action $
    BlockC.set_selection False view_id Config.play_position_selnum Nothing


-- * run_update

-- There's a fair amount of copy and paste in here, since CreateView subsumes
-- the functions of InsertTrack and many others.  For example, the merged
-- events of a given track are calculated in 4 separate places.  It's nasty
-- error-prone imperative code.  I'd like to factor it better but I don't know
-- how.
--
-- It's also a little confusing in that this function runs in StateT, but
-- returns an IO action to be run in the UI thread, so there are two monads
-- here.

-- | Generate an IO action that applies the update to the UI.
--
-- CreateView Updates will modify the State to add the ViewPtr.
run_update :: Update.Update -> State.StateT IO (IO ())
run_update (Update.ViewUpdate view_id Update.CreateView) = do
    view <- State.get_view view_id
    block <- State.get_block (Block.view_block view)

    let dtracks = Block.block_display_tracks block
    tracklikes <- mapM (State.get_tracklike . Block.dtracklike_id . fst) dtracks
    titles <- mapM track_title (Block.block_tracklike_ids block)

    let sels = Block.view_selections view
    csels <- mapM (\(selnum, sel) -> to_csel view_id selnum (Just sel))
        (Map.assocs sels)
    ustate <- State.get
    -- I manually sync the new empty view with its state.  It might reduce
    -- repetition to let Diff.diff do that by diffing against a state with an
    -- empty view, but this way seems less complicated if more error-prone.
    -- Sync: title, tracks, selection, skeleton
    return $ do
        let title = block_window_title view_id (Block.view_block view)
        BlockC.create_view view_id title (Block.view_rect view)
            (Block.view_config view) (Block.block_config block)

        let track_info = List.zip4 [0..] dtracks tracklikes titles
        forM_ track_info $ \(tracknum, (dtrack, width), tracklike, title) -> do
            let merged = events_of_track_ids ustate (Block.dtrack_merged dtrack)
            BlockC.insert_track view_id tracknum tracklike merged width
            unless (null title) $
                BlockC.set_track_title view_id tracknum title
            BlockC.set_display_track view_id tracknum dtrack

        unless (null (Block.block_title block)) $
            BlockC.set_title view_id (Block.block_title block)
        BlockC.set_skeleton view_id (Block.block_skeleton block)
        forM_ (zip (Map.keys sels) csels) $ \(selnum, csel) ->
            BlockC.set_selection True view_id selnum csel
        BlockC.set_status view_id (Block.show_status view)
        BlockC.set_zoom view_id (Block.view_zoom view)
        BlockC.set_track_scroll view_id (Block.view_track_scroll view)

run_update (Update.ViewUpdate view_id update) = do
    case update of
        -- The previous equation matches CreateView, but ghc warning doesn't
        -- figure that out.
        Update.CreateView -> error "run_update: notreached"
        Update.DestroyView -> return (BlockC.destroy_view view_id)
        Update.ViewSize rect -> return (BlockC.set_size view_id rect)
        Update.ViewConfig config -> return
            (BlockC.set_view_config view_id config)
        Update.Status status -> return (BlockC.set_status view_id status)
        Update.TrackScroll offset ->
            return (BlockC.set_track_scroll view_id offset)
        Update.Zoom zoom -> return (BlockC.set_zoom view_id zoom)
        Update.TrackWidth tracknum width -> return $
            BlockC.set_track_width view_id tracknum width
        Update.Selection selnum maybe_sel -> do
            csel <- to_csel view_id selnum maybe_sel
            return $ BlockC.set_selection True view_id selnum csel
        Update.BringToFront -> return $ BlockC.bring_to_front view_id

-- Block ops apply to every view with that block.
run_update (Update.BlockUpdate block_id update) = do
    view_ids <- fmap Map.keys (State.get_views_of block_id)
    case update of
        Update.BlockTitle title -> return $
            mapM_ (flip BlockC.set_title title) view_ids
        Update.BlockConfig config -> return $
            mapM_ (flip BlockC.set_model_config config) view_ids
        Update.BlockSkeleton skel -> return $
            mapM_ (flip BlockC.set_skeleton skel) view_ids
        Update.RemoveTrack tracknum -> return $
            mapM_ (flip BlockC.remove_track tracknum) view_ids
        Update.InsertTrack tracknum width dtrack -> do
            let tid = Block.dtracklike_id dtrack
            ctrack <- State.get_tracklike tid
            ustate <- State.get
            return $ forM_ view_ids $ \view_id -> do
                let merged = events_of_track_ids ustate
                        (Block.dtrack_merged dtrack)
                BlockC.insert_track view_id tracknum ctrack merged width
                case ctrack of
                    -- Configure new track.  This is analogous to the initial
                    -- config in CreateView.
                    Block.T t _ -> do
                        unless (null (Track.track_title t)) $
                            BlockC.set_track_title view_id tracknum
                                (Track.track_title t)
                        BlockC.set_display_track view_id tracknum dtrack
                    _ -> return ()
        Update.DisplayTrack tracknum dtrack -> do
            let tracklike_id = Block.dtracklike_id dtrack
            tracklike <- State.get_tracklike tracklike_id
            ustate <- State.get
            return $ forM_ view_ids $ \view_id -> do
                BlockC.set_display_track view_id tracknum dtrack
                let merged = events_of_track_ids ustate
                        (Block.dtrack_merged dtrack)
                -- This is unnecessary if I just collapsed the track, but
                -- no big deal.
                BlockC.update_entire_track view_id tracknum tracklike merged
        Update.TrackFlags -> return (return ())

run_update (Update.TrackUpdate track_id update) = do
    blocks <- State.blocks_with_track track_id
    let track_info = [(block_id, tracknum, tid)
            | (block_id, tracks) <- blocks, (tracknum, tid) <- tracks]
    -- lookup DisplayTrack and pair with the tracks
    fmap sequence_ $ forM track_info $ \(block_id, tracknum, tracklike_id) -> do
        view_ids <- fmap Map.keys (State.get_views_of block_id)
        tracklike <- State.get_tracklike tracklike_id

        ustate <- State.get
        block <- State.get_block block_id
        let merged = case Seq.at (Block.block_tracks block) tracknum of
                Just track ->
                    events_of_track_ids ustate (Block.track_merged track)
                Nothing -> []
        fmap sequence_ $ forM view_ids $ \view_id -> case update of
            Update.TrackEvents low high ->
                return $ BlockC.update_track view_id tracknum tracklike
                    merged low high
            Update.TrackAllEvents ->
                return $ BlockC.update_entire_track view_id tracknum tracklike
                    merged
            Update.TrackTitle title ->
                return $ BlockC.set_track_title view_id tracknum title
            Update.TrackBg ->
                -- update_track also updates the bg color
                return $ BlockC.update_track view_id tracknum tracklike
                    merged 0 0
            Update.TrackRender ->
                return $ BlockC.update_entire_track view_id tracknum tracklike
                    merged

run_update (Update.RulerUpdate ruler_id) = do
    blocks <- State.blocks_with_ruler ruler_id
    let track_info = [(block_id, tracknum, tid)
            | (block_id, tracks) <- blocks, (tracknum, tid) <- tracks]
    fmap sequence_ $ forM track_info $ \(block_id, tracknum, tracklike_id) -> do
        view_ids <- fmap Map.keys (State.get_views_of block_id)
        tracklike <- State.get_tracklike tracklike_id
        -- A ruler track doesn't have merged events so don't bother to look for
        -- them.
        fmap sequence_ $ forM view_ids $ \view_id -> return $
            BlockC.update_entire_track view_id tracknum tracklike []

track_title (Block.TId track_id _) =
    fmap Track.track_title (State.get_track track_id)
track_title _ = return ""

-- | Generate the title for block windows.
block_window_title :: ViewId -> BlockId -> String
block_window_title view_id block_id = show block_id ++ " -- " ++ show view_id

events_of_track_ids :: State.State -> [TrackId] -> [Track.TrackEvents]
events_of_track_ids ustate track_ids = Maybe.mapMaybe events_of track_ids
    where
    events_of track_id = fmap Track.track_events (Map.lookup track_id tracks)
    tracks = State.state_tracks ustate

to_csel :: ViewId -> Types.SelNum -> Maybe (Types.Selection)
    -> State.StateT IO (Maybe BlockC.CSelection)
to_csel view_id selnum maybe_sel = do
    view <- State.get_view view_id
    block <- State.get_block (Block.view_block view)
    let color = Seq.at_err "selection colors"
            (Block.config_selection_colors (Block.block_config block))
            selnum
    return $ fmap (BlockC.CSelection color) maybe_sel
