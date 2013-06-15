-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Cmds that affect global block config but don't fit into any of the
-- more specefic modules.
module Cmd.BlockConfig where
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Text as Text

import Util.Control
import qualified Util.Log as Log
import qualified Util.Seq as Seq

import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Skeleton as Skeleton
import qualified Ui.State as State
import qualified Ui.TrackTree as TrackTree

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.Info as Info
import qualified Cmd.Msg as Msg
import qualified Cmd.NoteTrack as NoteTrack
import qualified Cmd.Selection as Selection
import qualified Cmd.ViewConfig as ViewConfig

import qualified Derive.TrackInfo as TrackInfo
import Types


-- * block

cmd_toggle_edge :: (Cmd.M m) => Msg.Msg -> m ()
cmd_toggle_edge msg = do
    (block_id, sel_tracknum, _, _) <- Selection.get_insert
    clicked_tracknum <- Cmd.require $ clicked_track msg
    -- The click order goes in the arrow direction, caller-to-callee.
    let edge = (sel_tracknum, clicked_tracknum)
    success <- State.toggle_skeleton_edge block_id edge
    unless success $
        Log.warn $ "refused to add cycle-creating edge: " ++ show edge
    -- The shift below is incorrect.  Anyway, a common case is to splice
    -- a track above and then delete the unwanted edges, and moving the
    -- selection makes that inconvenient.
    -- let shift = clicked_tracknum - sel_tracknum
    -- if success
    --     then Selection.cmd_shift_selection Config.insert_selnum shift False
    --     else Log.warn $ "refused to add cycle-creating edge: " ++ show edge

clicked_track :: Msg.Msg -> Maybe TrackNum
clicked_track msg = case (Msg.mouse_down msg, Msg.context_track msg) of
    (True, Just (tracknum, _)) -> Just tracknum
    _ -> Nothing

-- | Merge all adjacent note/pitch pairs.  If they're already all merged,
-- unmerge them all.
toggle_merge_all :: (State.M m) => BlockId -> m ()
toggle_merge_all block_id = do
    tracks <- Info.block_tracks block_id
    let note_pitches = do
            Info.Track note (Info.Note controls) <- tracks
            pitch <- maybe [] (:[]) $ List.find
                (TrackInfo.is_pitch_track . State.track_title) controls
            return (State.track_tracknum note, State.track_tracknum pitch)
    ifM (andM [track_merged block_id tracknum | (tracknum, _) <- note_pitches])
        (mapM_ (State.unmerge_track block_id . fst) note_pitches)
        (mapM_ (uncurry (State.merge_track block_id)) note_pitches)

track_merged :: (State.M m) => BlockId -> TrackNum -> m Bool
track_merged block_id tracknum = not . null . Block.track_merged <$>
    State.get_block_track_at block_id tracknum

cmd_open_block :: (Cmd.M m) => m ()
cmd_open_block = do
    ns <- State.get_namespace
    let call_of = NoteTrack.block_call ns
    sel <- Selection.events
    forM_ sel $ \(_, _, events) -> forM_ events $ \event ->
        when_just (call_of (Event.event_text event)) $ \block_id ->
            whenM (Maybe.isJust <$> State.lookup_block block_id) $ do
                views <- State.views_of block_id
                maybe (Create.view block_id >> return ())
                    ViewConfig.bring_to_front (Seq.head (Map.keys views))

cmd_add_block_title :: (Cmd.M m) => Msg.Msg -> m ()
cmd_add_block_title _ = do
    block_id <- Cmd.get_focused_block
    title <- State.get_block_title block_id
    when (Text.null title) $
        State.set_block_title block_id " "

-- * collapse / expand tracks

-- | Collapse all the children of this track.
collapse_children :: (State.M m) => BlockId -> TrackId -> m ()
collapse_children block_id track_id = do
    children <- State.require ("no children: " ++ show track_id)
        =<< TrackTree.children_of block_id track_id
    forM_ children $ \track -> State.add_track_flag
        block_id (State.track_tracknum track) Block.Collapse

-- | Expand all collapsed children of this track.  Tracks that were merged
-- when they were collapsed will be left merged.
expand_children :: (State.M m) => BlockId -> TrackId -> m ()
expand_children block_id track_id = do
    children <- State.require ("no children: " ++ show track_id)
        =<< TrackTree.children_of block_id track_id
    merged <- Set.fromList . concatMap Block.track_merged . Block.block_tracks
        <$> State.get_block block_id
    forM_ children $ \track ->
        when (Set.member (State.track_id track) merged) $
            State.remove_track_flag
                block_id (State.track_tracknum track) Block.Collapse

-- * merge blocks

append :: (State.M m) => BlockId -> BlockId -> m ()
append dest source = do
    -- By convention the first track is just a ruler.
    tracks <- drop 1 . Block.block_tracks <$> State.get_block source
    tracknum <- State.track_count dest
    tracknum <- if tracknum <= 1 then return tracknum else do
        State.insert_track dest tracknum Block.divider
        return (tracknum + 1)
    forM_ (zip [tracknum..] tracks) $ \(i, track) ->
        State.insert_track dest i track
    skel <- State.get_skeleton dest
    edges <- Skeleton.flatten <$> State.get_skeleton source
    let offset = tracknum - 1 -- -1 because I dropped the first track.
    skel <- State.require "couldn't add edges to skel" $
        Skeleton.add_edges [(s+offset, e+offset) | (s, e) <- edges] skel
    State.set_skeleton dest skel

-- * track

cmd_toggle_flag :: (Cmd.M m) => Block.TrackFlag -> m ()
cmd_toggle_flag flag = do
    (block_id, tracknums, _, _, _) <- Selection.tracks
    forM_ tracknums $ \tracknum ->
        State.toggle_track_flag block_id tracknum flag

cmd_toggle_flag_clicked :: (Cmd.M m) => Block.TrackFlag -> Msg.Msg -> m ()
cmd_toggle_flag_clicked flag msg = do
    tracknum <- Cmd.require $ clicked_track msg
    block_id <- Cmd.get_focused_block
    State.toggle_track_flag block_id tracknum flag

-- | Enable Solo on the track and disable Mute.  It's bound to a double click
-- so when this cmd fires I have to do undo the results of the single click.
-- Perhaps mute and solo should be exclusive in general.
cmd_set_solo :: (Cmd.M m) => Msg.Msg -> m ()
cmd_set_solo msg = do
    tracknum <- Cmd.require $ clicked_track msg
    block_id <- Cmd.get_focused_block
    State.remove_track_flag block_id tracknum Block.Mute
    State.toggle_track_flag block_id tracknum Block.Solo

-- | Unset solo if it's set, otherwise toggle the mute flag.
cmd_mute_or_unsolo :: (Cmd.M m) => Msg.Msg -> m ()
cmd_mute_or_unsolo msg = do
    block_id <- Cmd.get_focused_block
    tracknum <- Cmd.require $ clicked_track msg
    flags <- State.track_flags block_id tracknum
    if Block.Solo `Set.member` flags
        then State.remove_track_flag block_id tracknum Block.Solo
        else State.toggle_track_flag block_id tracknum Block.Mute

cmd_expand_track :: (Cmd.M m) => Msg.Msg -> m ()
cmd_expand_track msg = do
    block_id <- Cmd.get_focused_block
    tracknum <- Cmd.require (clicked_track msg)
    State.remove_track_flag block_id tracknum Block.Collapse

-- | Move selected tracks to the left of the clicked track.
cmd_move_tracks :: (Cmd.M m) => Msg.Msg -> m ()
cmd_move_tracks msg = do
    (block_id, tracknums, _, _, _) <- Selection.tracks
    clicked <- Cmd.require $ clicked_track msg
    move_tracks block_id tracknums clicked
    -- Shift from the max tracknum or the minimum tracknum, depending on
    -- the move direction.
    when_just (Seq.minimum_on abs $ map (clicked-) tracknums) $
        Selection.shift False

move_tracks :: (State.M m) => BlockId -> [TrackNum] -> TrackNum -> m ()
move_tracks block_id sources dest =
    mapM_ (uncurry (State.move_track block_id)) moves
    where
    moves -- Start at the last source, then insert at the dest counting down.
        | any (<dest) sources =
            zip (reverse (List.sort sources)) [dest, dest-1 ..]
        -- Start at the first source, then insert at the dest counting up.
        | otherwise = zip (List.sort sources) [dest ..]
