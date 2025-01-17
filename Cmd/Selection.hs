-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Commands dealing with selection and cursor movement.

    As is typical, when it comes to selecting events, the selection represents
    a half-open range.  However, reflecting the orientation of events,
    a negative event at the start of the range won't be included, and
    a negative event at he end of the range will be included.  This is natural
    for events with negative duration, since they are weighted at the end.

    This behaviour is actually implemented in the low level "Ui.Events"
    functions.
-}
module Cmd.Selection where
import           Prelude hiding (lookup)
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified Util.Lists as Lists
import qualified Util.Num as Num
import qualified App.Config as Config
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Msg as Msg
import qualified Cmd.Perf as Perf
import qualified Cmd.TimeStep as TimeStep

import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.Warp as Warp
import qualified Midi.Midi as Midi
import qualified Midi.Mmc as Mmc
import qualified Perform.RealTime as RealTime
import qualified Perform.Transport as Transport
import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.ScoreTime as ScoreTime
import qualified Ui.Sel as Sel
import qualified Ui.TrackTree as TrackTree
import qualified Ui.Types as Types
import qualified Ui.Ui as Ui
import qualified Ui.UiMsg as UiMsg
import qualified Ui.Zoom as Zoom

import           Global
import           Types


-- * cmds

get_view :: Cmd.M m => ViewId -> m Sel.Selection
get_view = Cmd.abort_unless <=< lookup_view

lookup_view :: Ui.M m => ViewId -> m (Maybe Sel.Selection)
lookup_view view_id = Ui.get_selection view_id Config.insert_selnum

set_view :: Ui.M m => ViewId -> Maybe Sel.Selection -> m ()
set_view view_id = Ui.set_selection view_id Config.insert_selnum

{- | Set or unset the selection.

    This is the Cmd level of Ui.set_selection and should be called by
    any Cmd that wants to set the selection.

    The insert selnum always has an orientation, so if 'Sel.orientation' is
    'Sel.None', default to 'Cmd.state_note_orientation'.  Otherwise, update
    the note orientation, so the visible orientation and actual orientation stay
    in sync.
-}
set :: Cmd.M m => ViewId -> Maybe Sel.Selection -> m ()
set view_id maybe_sel = do
    record_history
    set_selnum view_id Config.insert_selnum maybe_sel
    record_history

set_without_history :: Cmd.M m => ViewId -> Maybe Sel.Selection -> m ()
set_without_history view_id = set_selnum view_id Config.insert_selnum

set_selnum :: Cmd.M m => ViewId -> Sel.Num -> Maybe Sel.Selection -> m ()
set_selnum view_id selnum maybe_sel
    | selnum == Config.insert_selnum = do
        -- If the new selection has an opinion about orientation, update
        -- Cmd.state_note_orientation.
        maybe_sel <- flip traverse maybe_sel $ \sel ->
            case Sel.orientation sel of
                Sel.None -> do
                    o <- get_orientation
                    return $ sel { Sel.orientation = o }
                Sel.Positive -> do
                    Cmd.modify_edit_state $ \state ->
                        state { Cmd.state_note_orientation = Types.Positive }
                    return sel
                Sel.Negative -> do
                    Cmd.modify_edit_state $ \state ->
                        state { Cmd.state_note_orientation = Types.Negative }
                    return sel
        Ui.set_selection view_id selnum maybe_sel
        whenJust maybe_sel $ \sel -> when (Sel.is_point sel) $ do
            set_subs view_id sel
            whenJustM (Cmd.gets (Cmd.state_sync . Cmd.state_play)) $
                mmc_goto_sel view_id sel
    | otherwise = Ui.set_selection view_id selnum maybe_sel

get_orientation :: Cmd.M m => m Sel.Orientation
get_orientation =
    Cmd.gets $ convert . Cmd.state_note_orientation . Cmd.state_edit
    where
    convert Types.Positive = Sel.Positive
    convert Types.Negative = Sel.Negative

mmc_goto_sel :: Cmd.M m => ViewId -> Sel.Selection -> Cmd.SyncConfig -> m ()
mmc_goto_sel view_id sel sync = do
    block_id <- Ui.block_id_of view_id
    maybe_track_id <- Ui.event_track_at block_id (Sel.cur_track sel)
    whenJustM (root_realtime block_id maybe_track_id (Sel.cur_pos sel)) $
        Cmd.midi (Cmd.sync_device sync) . mmc_goto sync

mmc_goto :: Cmd.SyncConfig -> RealTime -> Midi.Message
mmc_goto sync pos = Mmc.encode (Cmd.sync_device_id sync) $
    Mmc.goto_seconds (Cmd.sync_frame_rate sync) (RealTime.to_seconds pos)

-- | Set a selection in the current view.
set_current :: Cmd.M m => Sel.Num -> Maybe Sel.Selection -> m ()
set_current selnum maybe_sel = do
    view_id <- Cmd.get_focused_view
    set_selnum view_id selnum maybe_sel

-- | For point selections, set a play position selection on the equivalent
-- time in sub-blocks.  This makes it easier to edit the super-block relative
-- to the sub-block.
--
-- TODO if multiple calls overlap, I should draw multiple selections, but
-- Ui.set_selection doesn't support that, even though the underlying
-- BlockC.set_selection does.
set_subs :: Cmd.M m => ViewId -> Sel.Selection -> m ()
set_subs view_id sel = do
    view_ids <- Ui.all_view_ids
    forM_ view_ids $ \vid ->
        Ui.set_selection vid Config.play_position_selnum Nothing
    block_id <- Ui.block_id_of view_id
    maybe_track_id <- Ui.event_track_at block_id (Sel.cur_track sel)
    whenJust maybe_track_id $ \track_id ->
        mapM_ (uncurry set_block) =<<
            Perf.sub_pos block_id track_id (Sel.cur_pos sel)

set_block :: Ui.M m => BlockId -> [(TrackId, TrackTime)] -> m ()
set_block _ [] = return ()
set_block block_id ((_, pos) : _) = do
    view_ids <- Map.keys <$> Ui.views_of block_id
    forM_ view_ids $ \view_id ->
        Ui.set_selection view_id Config.play_position_selnum $ Just $
            Sel.Selection
                { start_track = 0, start_pos = pos
                , cur_track = 999, cur_pos = pos
                , orientation = Sel.Positive
                }

-- ** modify existing selection

-- | Update the selection's orientation to match 'Cmd.state_note_orientation'.
update_orientation :: Cmd.M m => m ()
update_orientation = whenJustM lookup_context $ \(Context view_id _ sel) ->
    set view_id $ Just $ sel { Sel.orientation = Sel.None }

-- | Collapse the selection to a point at its (cur_track, cur_pos).
to_point :: Cmd.M m => Bool -> m ()
to_point to_cur_pos = do
    (view_id, old) <- get_view_sel
    selectable <- Ui.selectable_tracks <$>
        (Ui.get_block =<< Ui.block_id_of view_id)
    let closest = fromMaybe (Sel.cur_track old) $
            find_at_before (Sel.cur_track old) selectable
    let new
            | to_cur_pos = old
                { Sel.start_track = closest, Sel.cur_track = closest
                , Sel.start_pos = Sel.cur_pos old
                }
            | otherwise = old
                { Sel.start_track = closest, Sel.cur_track = closest
                , Sel.cur_pos = Sel.start_pos old
                }
    -- auto_scroll doesn't scroll if Sel.cur_pos hasn't moved, but in this
    -- case I do want it to move, so I jump to it when collapsing to_cur_pos.
    -- So trick auto_scroll by pretending the old cur_pos was different.
    let old2 = if Sel.cur_pos old == Sel.cur_pos new
        then old { Sel.cur_pos = Sel.start_pos old } else old
    auto_scroll view_id (Just old2) new
    set view_id (Just new)

find_at_before :: Ord a => a -> [a] -> Maybe a
find_at_before n = Lists.last . takeWhile (<=n)

-- | Advance the insert selection by the current step, which is a popular thing
-- to do.
advance :: Cmd.M m => m ()
advance = step TimeStep.Advance default_move

-- | How to move a selection.
data Move =
    Extend -- ^ Extend the existing selection.
    | Move -- ^ Move the existing selection by the step amount.
    | Replace -- ^ Replace the existing selection with a point selection.
    deriving (Show)

-- | Use this Move mode when you don't have a more specific idea.
default_move :: Move
default_move = Move

-- | Advance the given selection by the current step.
--
-- The selection will maintain its current track span, be set to a point, and
-- advance to the next relevant mark.  "next relevant mark" is the next visible
-- mark in the ruler to the left.
step :: Cmd.M m => TimeStep.Direction -> Move -> m ()
step dir move = do
    st <- Cmd.get_current_step
    step_with (TimeStep.direction dir) move st

step_with :: Cmd.M m => Int -> Move -> TimeStep.TimeStep -> m ()
step_with steps move step = do
    view_id <- Cmd.get_focused_view
    old@(Sel.Selection start_track start_pos cur_track cur_pos _) <-
        get_view view_id
    new_pos <- step_from cur_track cur_pos steps step
    let new_sel = case move of
            Extend -> Sel.Selection
                { start_track = start_track, start_pos = start_pos
                , cur_track = cur_track, cur_pos = new_pos
                , orientation = Sel.None
                }
            Move -> Sel.move (new_pos - cur_pos) old
            Replace -> Sel.point cur_track new_pos Sel.None
    set_without_history view_id (Just new_sel)
    auto_scroll view_id (Just old) new_sel

-- | Move the selection across tracks by @shift@, possibly skipping non-event
-- tracks and collapsed tracks.
shift :: Cmd.M m => Bool -> Move -> Int -> m ()
shift skip_unselectable move shift = modify $ \block old ->
    let new = Ui.shift_selection skip_unselectable block shift old
    in case move of
        Extend -> Sel.merge old new
        Move -> new
        Replace -> Sel.point (Sel.cur_track new) (Sel.cur_pos new)
            (Sel.orientation new)

-- | Unlike 'shift', this uses 'Sel.union', which means that the selection will
-- always expand, instead of only expanding if the current track is moving away
-- from the start track.  This is because I use this as a way to expand the
-- selection rather than move it.
jump_to_track :: Cmd.M m => Move -> TrackNum -> m ()
jump_to_track move tracknum = modify $ \_ old ->
    let new = Sel.modify_tracks (+ (tracknum - Sel.cur_track old)) old
    in case move of
        Extend -> Sel.union old (Sel.modify_tracks (const tracknum) old)
        Move -> new
        Replace -> Sel.point (Sel.cur_track new) (Sel.cur_pos new)
            (Sel.orientation new)

modify :: Cmd.M m => (Block.Block -> Sel.Selection -> Sel.Selection) -> m ()
modify f = do
    view_id <- Cmd.get_focused_view
    block <- Ui.block_of view_id
    sel <- get_view view_id
    let new = f block sel
    set_without_history view_id (Just new)
    auto_scroll view_id (Just sel) new

data Direction = R | L deriving (Eq, Show)

find_note_track :: Cmd.M m => Direction -> Bool -> m (Maybe TrackNum)
find_note_track dir one_before  = do
    tracks <- get_tracks_from_selection one_before dir
    return $ Ui.track_tracknum <$>
        find (ParseTitle.is_note_track . Ui.track_title) tracks
    where
    find f
        | one_before = if dir == R then find_before f else List.find f
        | otherwise = List.find f

-- | Find the element before the predicate matches, or the last element if it
-- never matches.
find_before :: (a -> Bool) -> [a] -> Maybe a
find_before p = go
    where
    go (x1 : xs@(x2 : _))
        | p x2 = Just x1
        | otherwise = go xs
    go [x] = Just x
    go [] = Nothing

-- | Get tracks either starting from the right of the selection, or the left.
-- Unselectable tracks are omitted.
get_tracks_from_selection :: Cmd.M m => Bool -- ^ If True, start from the R or
    -- L edge of the selection, rather than 'Sel.cur_track'.
    -> Direction -> m [Ui.TrackInfo]
get_tracks_from_selection from_edge dir = do
    (view_id, sel) <- get_view_sel
    let tracknum = if from_edge
            then (if dir == R then snd else fst) (Sel.track_range sel)
            else Sel.cur_track sel
    block_id <- Ui.block_id_of view_id
    tracks <- filter (Block.track_selectable . Ui.track_block) <$>
        TrackTree.tracks_of block_id
    return $ case dir of
        R -> dropWhile ((<= tracknum) . Ui.track_tracknum) tracks
        L -> dropWhile ((>= tracknum) . Ui.track_tracknum) (reverse tracks)

-- | Progressive selection: select the rest of the track, then the entire
-- track, then the whole block.
--
-- TrackNum 0, assumed to be a ruler, is omitted, since selecting the ruler is
-- not only not useful, it tends to make cmds that want to get a TrackId abort.
cmd_track_all :: Cmd.M m => m ()
cmd_track_all = do
    (view_id, sel) <- get_view_sel
    block_id <- Ui.block_id_of view_id
    block_end <- Ui.block_end block_id
    tracks <- Ui.track_count block_id
    set view_id $ Just (select_track_all block_end tracks sel)

select_track_all :: TrackTime -> TrackNum -> Sel.Selection -> Sel.Selection
select_track_all block_end tracks sel
    | sel == select_tracks = select_all
    | sel == select_rest = select_tracks
    | otherwise = select_rest
    where
    select_rest = until_end $ sel { Sel.cur_pos = Sel.min sel }
    select_tracks = until_end $ sel { Sel.cur_pos = 0 }
    select_all = until_end $ track_selection 1 (tracks - 1)
    until_end = select_until_end block_end
    track_selection from to = Sel.Selection
        { start_track = from, start_pos = 0
        , cur_track = to, cur_pos = 0
        , orientation = Sel.orientation sel
        }

-- | Extend the selection horizontally to encompass all tracks.  If it already
-- does, reset the track selection to the previous one.
cmd_toggle_extend_tracks :: Cmd.M m => m ()
cmd_toggle_extend_tracks = do
    (view_id, sel) <- get_view_sel
    tracks <- Ui.track_count =<< Ui.block_id_of view_id
    let expanded = sel { Sel.cur_track = 1, Sel.start_track = tracks - 1 }
    if sel /= expanded
        then set view_id $ Just expanded
        else previous_selection False

-- ** set selection from clicks

-- | Select clicked on track.
cmd_select_track :: Cmd.M m => Types.MouseButton -> Msg.Msg -> m ()
cmd_select_track btn msg = do
    view_id <- Cmd.get_focused_view
    ((down_tracknum, _), (mouse_tracknum, _)) <- mouse_drag btn msg
    select_tracks view_id down_tracknum mouse_tracknum

select_tracks :: Cmd.M m => ViewId -> TrackNum -> TrackNum -> m ()
select_tracks view_id from to = do
    block_end <- Ui.block_end =<< Ui.block_id_of view_id
    set view_id $ Just $ select_until_end block_end $
        Sel.Selection
            { start_track = from, start_pos = 0
            , cur_track = to, cur_pos = 0
            , orientation = Sel.Positive
            }

-- | Extend the selection to the end of then block.  This sets 'Sel.start_pos',
-- with the assumption that 'Sel.cur_pos' is onscreen.  This is so
-- 'auto_scroll' won't jump to the bottom of the block.
select_until_end :: TrackTime -> Sel.Selection -> Sel.Selection
select_until_end block_end sel =
    sel { Sel.start_pos = block_end + ScoreTime.eta }
    -- Without ScoreTime.eta, a select-all won't include an event at the end of
    -- the block.

-- | Set the selection based on a click or drag.
cmd_mouse_selection :: Cmd.M m => Types.MouseButton -> Bool -> Msg.Msg -> m ()
cmd_mouse_selection btn extend msg = do
    ((down_tracknum, down_pos), (mouse_tracknum, mouse_pos))
        <- mouse_drag_pos btn msg
    view_id <- Cmd.get_focused_view
    old_sel <- lookup_view view_id
    let (start_tracknum, start_pos) = case (extend, old_sel) of
            (True, Just (Sel.Selection tracknum pos _ _ _)) -> (tracknum, pos)
            _ -> (down_tracknum, down_pos)
    when (Msg.mouse_down msg) record_history
    let sel = Sel.Selection
            { start_track = start_tracknum, start_pos = start_pos
            , cur_track = mouse_tracknum, cur_pos = mouse_pos
            , orientation = Sel.None
            }
    set_and_scroll view_id sel

-- | Like 'cmd_mouse_selection', but snap the selection to the current time
-- step.
cmd_snap_selection :: Cmd.M m => Types.MouseButton -> Bool -> Msg.Msg -> m ()
cmd_snap_selection btn extend msg = do
    ((down_tracknum, _), (mouse_tracknum, mouse_pos)) <- mouse_drag_pos btn msg
    block_id <- Cmd.get_focused_block
    step <- Cmd.get_current_step
    view_id <- Cmd.get_focused_view
    old_sel <- lookup_view view_id
    snap_pos <- TimeStep.snap step block_id mouse_tracknum
        (Sel.cur_pos <$> old_sel) mouse_pos
    snap_pos <- snap_over_threshold view_id block_id mouse_pos snap_pos
    let sel = case old_sel of
            _ | old_sel == Nothing || Msg.mouse_down msg && not extend ->
                Sel.Selection
                    { start_track = down_tracknum, start_pos = snap_pos
                    , cur_track = mouse_tracknum, cur_pos = snap_pos
                    , orientation = Sel.None
                    }
            Just (Sel.Selection tracknum pos _ _ _) -> Sel.Selection
                { start_track = tracknum, start_pos = pos
                , cur_track = mouse_tracknum, cur_pos = snap_pos
                , orientation = Sel.None
                }
            -- ghc doesn't realize it is exhaustive
            _ -> error "Cmd.Selection: not reached"
    when (Msg.mouse_down msg) record_history
    set_and_scroll view_id sel
    where
    -- If I'm dragging, only snap if I'm close to a snap point.  Otherwise,
    -- it's easy for the selection to jump way off screen while dragging.
    snap_over_threshold view_id block_id pos snap = do
        zoom <- Ui.get_zoom view_id
        let over = Zoom.to_pixels zoom (abs (snap - pos)) > threshold
        -- Don't go past the end of the ruler.  Otherwise it's easy to
        -- accidentally select too much by dragging to the end of the block.
        end <- Ui.block_ruler_end block_id
        return $ if not (Msg.mouse_down msg) && over && pos < end
            then pos else snap
    threshold = 20

-- | Like 'mouse_drag' but specialized for drags on the track.
mouse_drag_pos :: Cmd.M m => Types.MouseButton -> Msg.Msg
    -> m ((TrackNum, TrackTime), (TrackNum, TrackTime))
mouse_drag_pos btn msg = do
    ((num1, t1), (num2, t2)) <- mouse_drag btn msg
    case (t1, t2) of
        (UiMsg.Track p1, UiMsg.Track p2) -> return ((num1, p1), (num2, p2))
        _ -> Cmd.abort

-- | Get the clicked or dragged range, or abort if this isn't a drag Msg.
-- This accepts clicks as well, and considers them an empty range.
mouse_drag :: Cmd.M m => Types.MouseButton -> Msg.Msg
    -> m ((TrackNum, UiMsg.Track), (TrackNum, UiMsg.Track))
    -- ^ (mouse down at, mouse currently at)
mouse_drag btn msg = do
    (is_down, mod, mouse_at) <- Cmd.abort_unless (mouse_mod msg)
    msg_btn <- Cmd.abort_unless (Cmd.mouse_mod_btn mod)
    -- The button down should be the same one as expected.
    when (msg_btn /= btn) Cmd.abort
    keys_down <- Cmd.keys_down
    let mouse_down = Map.lookup (Cmd.strip_modifier mod) keys_down
    let down_at = case (is_down, mouse_down) of
            (False, Just (Cmd.MouseMod _ (Just track))) -> track
            -- If it's not already held down, it starts here.
            _ -> mouse_at
    -- MsgCollector is back to clamping at track-1, but leave this in in
    -- case I change my mind again.
    -- -- Clip a drag past the last track to the last track, callers here treat
    -- -- it as the same.
    -- tracks <- Ui.track_count =<< Cmd.get_focused_block
    -- let clamp (tnum, track) = (min (tracks-1) tnum, track)
    -- return (clamp down_at, clamp mouse_at)
    return (down_at, mouse_at)

-- * implementation

-- ** auto scroll

-- | Figure out how much to scroll to keep the selection visible and with
-- reasonable space around it.
--
-- Anyone who wants to set a selection and automatically scroll the window to
-- follow the selection should use this function.
set_and_scroll :: Cmd.M m => ViewId -> Sel.Selection -> m ()
set_and_scroll view_id sel = do
    old <- lookup_view view_id
    auto_scroll view_id old sel
    set view_id (Just sel)

-- | If the selection has scrolled off the edge of the window, automatically
-- scroll it so that the \"current\" end of the selection is in view.
auto_scroll :: Cmd.M m => ViewId -> Maybe Sel.Selection -> Sel.Selection -> m ()
auto_scroll view_id old new = do
    view <- Ui.get_view view_id
    block <- Ui.get_block (Block.view_block view)
    end <- Ui.block_end (Block.view_block view)
    let time_offset = Num.clamp 0 (end - Block.visible_time view) $
            auto_time_scroll view (Sel.cur_pos <$> old) (Sel.cur_pos new)
        track_offset = auto_track_scroll block view new
    Ui.modify_zoom view_id $ \zoom -> zoom { Zoom.offset = time_offset }
    Ui.set_track_scroll view_id track_offset

-- TODO this scrolls too fast when dragging.  Detect a drag and scroll at
-- a rate determined by how far past the bottom the pointer is.
auto_time_scroll :: Block.View -> Maybe TrackTime -> TrackTime -> TrackTime
auto_time_scroll view prev_pos pos
    -- Don't scroll if the cur pos hasn't changed.  Otherwise, selecting the
    -- whole track and shifting tracks scrolls the block down to the bottom.
    | Just pos == prev_pos = view_start
    | pos >= view_end = pos - visible + space
    | pos < view_start = pos - space
    | otherwise = view_start
    where
    visible = Block.visible_time view
    view_start = Zoom.offset (Block.view_zoom view)
    view_end = view_start + visible
    space = ScoreTime.from_double $
        visible_pixels / Zoom.factor (Block.view_zoom view)
    visible_pixels = 30

-- | Find the track scroll that would put the given selection into view.
auto_track_scroll :: Block.Block -> Block.View -> Sel.Selection -> Types.Width
auto_track_scroll block view sel
    | track_end > view_end = track_end - visible
    | track_start < view_start = track_start
    | otherwise = view_start
    where
    -- Pesky ruler track doesn't count towards the track scroll.
    widths = map Block.display_track_width (drop 1 (Block.block_tracks block))
    track_start = Num.sum (take (cur_tracknum-1) widths)
    track_end = Num.sum (take cur_tracknum widths)
    view_start = Block.view_track_scroll view
    view_end = view_start + visible
    -- Visible does include the pesky ruler.
    visible = Block.visible_track view - maybe 0
        Block.display_track_width (Lists.head (Block.block_tracks block))
    cur_tracknum = Sel.cur_track sel


-- ** mouse

-- | (mouse_down, mouse_modifier, (mouse_track, mouse_pos))
mouse_mod :: Msg.Msg -> Maybe (Bool, Cmd.Modifier, (TrackNum, UiMsg.Track))
mouse_mod msg = do
    mouse <- Msg.mouse msg
    (down, btn) <- case UiMsg.mouse_state mouse of
        UiMsg.MouseDown btn -> Just (True, btn)
        UiMsg.MouseDrag btn -> Just (False, btn)
        UiMsg.MouseUp btn -> Just (False, btn)
        _ -> Nothing
    track <- Msg.context_track msg
    return (down, Cmd.MouseMod btn (Just track), track)

-- * util

step_from :: Cmd.M m => TrackNum -> TrackTime -> Int -> TimeStep.TimeStep
    -> m TrackTime
step_from tracknum pos steps step = do
    block_id <- Cmd.get_focused_block
    end <- max <$> Ui.block_ruler_end block_id <*> Ui.block_event_end block_id
    next <- TimeStep.step_from steps step block_id tracknum pos
    return $ case next of
        Just next | 0 <= next && next <= end -> next
        _ -> pos

-- | Get the ruler that applies to the given track.  Search left for the
-- closest ruler that has all the given marklist names.  This includes ruler
-- tracks and the rulers of event tracks.
relevant_ruler :: Block.Block -> TrackNum -> Maybe RulerId
relevant_ruler block tracknum = Lists.at (Block.ruler_ids_of in_order) 0
    where
    in_order = map (Block.tracklike_id . snd) $ dropWhile ((/=tracknum) . fst) $
        reverse $ zip [0..] (Block.block_tracks block)

-- * get selection info

{- Getting the selection may seem pretty simple, but there are a number of
    orthogonal flavors:

    - Return a raw Sel.Selection, or return its
    (ViewId, BlockId, TrackId, TrackTime) context.

    - Get a single point from a selection, or a range on a single track, or
    a range of tracks.

    - Get an arbitrary Sel.Num or use the Config.insert_selnum.

    - Return a Maybe or abort on Nothing.

    - Return for any track, or return a TrackId and abort if it's not an event
    track.

    - Used an arbitrary ViewId, BlockId, or use the focused view.

    And then there is a whole other dimension of converting selections, which
    are in TrackTime, to RealTime.  The selection can be converted either
    relative to its block's tempo, or relative to a calling block's tempo,
    namely the root block.

    Also, when a selection is interpreted as a point (for instance, for
    operations like \"play from selection\"), there is a choice of taking the
    point from the beginning of the selection, the end, or the 'sel_cur_pos',
    which is the dragged-to point.  The convention, established by
    'sel_point' and 'sel_point_track', is to use the active end of the
    selection.
-}

-- | Get the \"point\" position of a Selection.
sel_point :: Sel.Selection -> TrackTime
sel_point = Sel.cur_pos

-- | When multiple tracks are selected, only one can be the point.  This
-- is 'Sel.cur_track', and in fact must be, because 'Sel.start_track' may
-- be an invalid tracknum.  That is so a selection can maintain its shape even
-- if it momentarily goes out of bounds.
sel_point_track :: Sel.Selection -> TrackNum
sel_point_track = Sel.cur_track

-- | A point on a track.
type Point = (BlockId, TrackNum, TrackId, TrackTime)
type AnyPoint = (BlockId, TrackNum, TrackTime)

-- | Get the "insert position", which is the start track and position of the
-- insert selection.  Abort if it's not an event track.
get_insert :: Cmd.M m => m Point
get_insert = Cmd.abort_unless =<< lookup_insert

lookup_insert :: Cmd.M m => m (Maybe Point)
lookup_insert = fmap (fmap snd) $ lookup_selnum_insert Config.insert_selnum

lookup_selnum_insert :: Cmd.M m => Sel.Num -> m (Maybe (ViewId, Point))
lookup_selnum_insert selnum =
    justm (lookup_any_selnum_insert selnum) $
    \(view_id, (block_id, tracknum, pos)) ->
    justm (Ui.event_track_at block_id tracknum) $ \track_id ->
    return $ Just (view_id, (block_id, tracknum, track_id, pos))

-- | Return the leftmost tracknum and trackpos, even if it's not an event
-- track.
get_any_insert :: Cmd.M m => m (ViewId, AnyPoint)
get_any_insert = Cmd.abort_unless =<< lookup_any_insert

lookup_any_insert :: Cmd.M m => m (Maybe (ViewId, AnyPoint))
lookup_any_insert = lookup_any_selnum_insert Config.insert_selnum

-- | The most general insertion point function.
lookup_any_selnum_insert :: Cmd.M m => Sel.Num -> m (Maybe (ViewId, AnyPoint))
lookup_any_selnum_insert selnum =
    justm (lookup_context_selnum selnum) $ \(Context view_id block_id sel) ->
        return $ Just (view_id, (block_id, sel_point_track sel, sel_point sel))

-- | Given a block, get the selection on it, if any.  If there are multiple
-- views, take the one with the alphabetically first ViewId.
--
-- I'm not sure how to choose, but the first one seems reasonable for now.
lookup_block_insert :: Ui.M m => BlockId -> m (Maybe Point)
lookup_block_insert block_id = do
    view_ids <- Map.keys <$> Ui.views_of block_id
    case view_ids of
        [] -> return Nothing
        view_id : _ ->
            justm (lookup_view view_id) $ \sel ->
            justm (sel_track block_id sel) $ \track_id ->
            return $ Just
                (block_id, sel_point_track sel, track_id, sel_point sel)

-- | Get the point track of a selection.
sel_track :: Ui.M m => BlockId -> Sel.Selection -> m (Maybe TrackId)
sel_track block_id sel = Ui.event_track_at block_id (sel_point_track sel)

-- ** plain Selection

-- | The selection is in the Ui.State, but focused view is in Cmd.State.
-- Extracting it out lets me depend only on Ui.M, not Cmd.M.  Also it decouples
-- selection functions from the current Ui.State and Cmd.State.
data Context = Context {
    ctx_view_id :: !ViewId
    , ctx_block_id :: !BlockId
    , ctx_selection :: !Sel.Selection
    } deriving (Show)

ctx_view_selection :: Context -> (ViewId, Sel.Selection)
ctx_view_selection ctx = (ctx_view_id ctx, ctx_selection ctx)

context :: Cmd.M m => m Context
context = context_selnum Config.insert_selnum

context_selnum :: Cmd.M m => Sel.Num -> m Context
context_selnum selnum = Cmd.abort_unless =<< lookup_context_selnum selnum

lookup_context :: Cmd.M m => m (Maybe Context)
lookup_context = lookup_context_selnum Config.insert_selnum

lookup_context_selnum :: Cmd.M m => Sel.Num -> m (Maybe Context)
lookup_context_selnum selnum =
    justm Cmd.lookup_focused_view $ \view_id ->
    justm (Ui.get_selection view_id selnum) $ \sel -> do
        block_id <- Ui.block_id_of view_id
        return $ Just $ Context view_id block_id sel

get :: Cmd.M m => m Sel.Selection
get = Cmd.abort_unless =<< lookup

lookup :: Cmd.M m => m (Maybe Sel.Selection)
lookup = fmap ctx_selection <$> lookup_context

get_view_sel :: Cmd.M m => m (ViewId, Sel.Selection)
get_view_sel = ctx_view_selection <$> context

range :: Cmd.M m => m Events.Range
range = Events.selection_range <$> get

point :: Cmd.M m => m TrackTime
point = sel_point <$> get

start, end :: Cmd.M m => m TrackTime
start = Sel.min <$> get
end = Sel.max <$> get

-- ** selections in RealTime

-- | Get the real time range of the focused selection.  If there's a root
-- block, then it will be in relative to that root, otherwise it's equivalent
-- to 'local_realtime'.
realtime :: Cmd.M m => m (BlockId, RealTime, RealTime)
realtime = do
    maybe_root_id <- Ui.lookup_root_id
    case maybe_root_id of
        Nothing -> local_realtime
        Just root_id -> do
            (s, e) <- relative_realtime root_id
            return (root_id, s, e)

-- | RealTime of the given ScoreTime, relative to the root block.  This is
-- the closest we get to an absolute real time.
root_realtime :: Cmd.M m => BlockId -> Maybe TrackId -> ScoreTime
    -> m (Maybe RealTime)
root_realtime block_id maybe_track_id pos =
    Ui.get_root_id >>= \root_block ->
    justm (Cmd.lookup_performance root_block) $ \perf ->
    Perf.lookup_realtime perf block_id maybe_track_id pos

-- | This is like 'get_insert', except get the selection on the root block,
-- falling back to the current one if there is none.
get_root_insert :: Cmd.M m => m Point
get_root_insert = maybe get_insert return =<< rootsel
    where
    rootsel = justm Ui.lookup_root_id $ \root_id ->
        lookup_block_insert root_id

-- | Get the current selection in RealTime relative to another block.
--
-- If a block is called in multiple places, a score time on it may occur at
-- multiple real times.  Pick the real time from the given selection which is
-- closest to the real time of the selection on the given root block.
--
-- If there's no selection on the root block then return the RealTime from the
-- block's first occurrance.
relative_realtime :: Cmd.M m => BlockId -> m (RealTime, RealTime)
relative_realtime root_id = do
    (view_id, sel) <- get_view_sel
    block_id <- Ui.block_id_of view_id
    track_id <- Cmd.abort_unless =<< sel_track block_id sel
    maybe_root_sel <- lookup_block_insert root_id
    perf <- Cmd.get_performance root_id
    let root_pos = point_to_real (Cmd.perf_tempo perf) maybe_root_sel
    let warp = Cmd.perf_closest_warp perf block_id track_id root_pos
    let (start, end) = Sel.range sel
    return (Warp.warp warp start, Warp.warp warp end)

-- | Get the RealTime range of the current selection, as derived from current
-- selection's block.  This means that the top should be 0.
local_realtime :: Cmd.M m => m (BlockId, RealTime, RealTime)
local_realtime = do
    (view_id, sel) <- get_view_sel
    block_id <- Ui.block_id_of view_id
    track_id <- Cmd.abort_unless =<< sel_track block_id sel
    perf <- Cmd.get_performance block_id
    let (start, end) = Sel.range sel
    let warp = Cmd.perf_closest_warp perf block_id track_id 0
    return (block_id, Warp.warp warp start, Warp.warp warp end)

-- | This is like 'relative_realtime' but gets a RealTime relative to a Point,
-- not a range.
relative_realtime_point :: Cmd.Performance -> Maybe Point -> Point -> RealTime
relative_realtime_point perf maybe_root_sel (block_id, _, track_id, pos) =
    Warp.warp warp pos
    where
    root_pos = point_to_real (Cmd.perf_tempo perf) maybe_root_sel
    warp = Cmd.perf_closest_warp perf block_id track_id root_pos

point_to_real :: Transport.TempoFunction -> Maybe Point -> RealTime
point_to_real _ Nothing = 0
point_to_real tempo (Just (block_id, _, track_id, pos)) =
    fromMaybe 0 $ Lists.head $ tempo block_id track_id pos

-- ** select events

-- | Selected events per track.  Gives events before, within, and after the
-- selection.  As usual, previous events are in descending order.
type SelectedAround = [(TrackId, ([Event.Event], [Event.Event], [Event.Event]))]
type SelectedEvents = [(TrackId, [Event.Event])]

around_to_events :: SelectedAround -> SelectedEvents
around_to_events = map $ \(track_id, (_, within, _)) -> (track_id, within)

-- | All selected events.  'events_around' is the default selection behaviour.
events :: Cmd.M m => m SelectedEvents
events = ctx_events =<< context

ctx_events :: Ui.M m => Context -> m SelectedEvents
ctx_events ctx = around_to_events <$> ctx_events_around ctx

-- | Like 'events', but only for the 'sel_point_track'.
track_events :: Cmd.M m => m (TrackId, [Event.Event])
track_events = ctx_track_events =<< context

ctx_track_events :: Ui.M m => Context -> m (TrackId, [Event.Event])
ctx_track_events ctx = do
    events <- around_to_events <$> ctx_events_around ctx
    Ui.require "ctx_events_around output should be 1:1 with TrackIds" $
        Lists.head events

events_around :: Cmd.M m => m SelectedAround
events_around = ctx_events_around =<< context

-- | Get events exactly at the point.  This gets both positive and negative
-- events, so each track may have up to 2 events.
events_at_point :: Cmd.M m => m SelectedEvents
events_at_point = do
    track_ids <- track_ids
    pos <- point
    fmap (filter (not . null . snd)) $ forM track_ids $ \track_id -> do
        events <- Ui.get_events track_id
        return $ (track_id,) $
            maybe [] (:[]) (Events.at pos Types.Negative events)
            ++ maybe [] (:[]) (Events.at pos Types.Positive events)

-- -- | Like 'event_around', but select as if the selection were a point.
-- -- Suitable for cmds that logically only work on a single event per-track.
-- events_around_point :: Cmd.M m => m SelectedAround
-- events_around_point = do
--     ctx <- context
--     let sel = ctx_selection ctx
--     ctx_events_around $ ctx
--         { ctx_selection = sel
--             { Sel.start_pos = sel_point sel
--             , Sel.cur_pos = sel_point sel
--             }
--         }

-- | Get events in the selection, but if no events are selected, expand it
-- to include a neighboring event, as documented in 'select_neighbor'.
--
-- Normally the range is half-open by event orientation, so a positive event at
-- the end of the selection won't be included.  But there's a special hack
-- where if the end of the selection happens to be the end of the block,
-- a positive event there will be included anyway.  Otherwise it's annoying to
-- select a final event (unless it's negative).
--
-- This is the standard definition of a selection, and should be used in all
-- standard selection using commands.
ctx_events_around :: Ui.M m => Context -> m SelectedAround
ctx_events_around ctx = do
    (block_id, _, track_ids, _) <- ctx_tracks ctx
    block_end <- Ui.block_end block_id
    extend block_end . zip track_ids . map (split_events_around sel) <$>
            mapM Ui.get_events track_ids
    where
    extend block_end
        | block_end == Sel.max sel = map until_end
        | otherwise = id
    sel = ctx_selection ctx
    until_end (track_id, (pre, within, post)) =
        (track_id, (pre, within ++ post, []))

split_events_around :: Sel.Selection -> Events.Events
    -> ([Event.Event], [Event.Event], [Event.Event])
split_events_around sel events
    | null within = select_neighbor sel (pre, post)
    | otherwise = (pre, within, post)
    where
    (pre, within, post) =
        (Events.descending pre, Events.ascending within, Events.ascending post)
        where
        (pre, within, post) =
            Events.split_range (Events.selection_range sel) events

select_neighbor :: Sel.Selection -> ([Event.Event], [Event.Event])
    -> ([Event.Event], [Event.Event], [Event.Event])
select_neighbor sel pair = case pair of
    -- Always pick an overlapping event.
    (pre:pres, posts) | Event.overlaps p pre -> (pres, [pre], posts)
    (pres, post:posts) | Event.overlaps p post -> (pres, [post], posts)
    --  |--->    <---| => take based on orientation
    (pre:pres, post:posts)
        | Event.is_positive pre && Event.is_negative post -> case orient of
            Types.Positive -> (pres, [pre], post:posts)
            Types.Negative -> (pre:pres, [post], posts)
    --  |--->          => take pre
    (pre:pres, posts) | Event.is_positive pre -> (pres, [pre], posts)
    --           <---| => take post
    (pres, post:posts) | Event.is_negative post -> (pres, [post], posts)
    --  <---|    |---> => in the middle, do nothing
    (pres, posts) -> (pres, [], posts)
    where
    p = sel_point sel
    orient = Sel.event_orientation sel

-- | This is similar to 'events_around', except that the direction is reversed:
-- it favors the next positive event, or the previous negative one.  Also this
-- assumes a point selection and only selects one event per track.
opposite_neighbor :: Cmd.M m => m [(TrackId, Event.Event)]
opposite_neighbor = do
    tids <- track_ids
    sel <- get
    events <- forM tids $ \track_id ->
        select_opposite_neighbor (sel_point sel) (Sel.event_orientation sel) <$>
            Ui.get_events track_id
    return [(track_id, event) | (track_id, Just event) <- zip tids events]

select_opposite_neighbor :: ScoreTime -> Types.Orientation -> Events.Events
    -> Maybe Event.Event
select_opposite_neighbor pos orient events =
    case Events.split_lists pos events of
        -- TODO should select overlapping like before
        -- except this messes up zero dur
        -- How did this work before?  It didn't!
        -- (pre:_, _) | Event.overlaps pos pre -> Just pre
        -- (_, post:_) | Event.overlaps pos post -> Just post
        (pre:_, post:_)
            | Event.is_positive post && Event.is_negative pre -> case orient of
                Types.Positive -> Just post
                Types.Negative -> Just pre
        (_, post:_) | Event.is_positive post -> Just post
        (pre:_, _) | Event.is_negative pre -> Just pre
        _ -> Nothing

-- ** select tracks

-- | Per-track selection info.
--
-- The TrackNums are sorted, and the TrackIds are likewise in left-to-right
-- order.  Only TrackNums for event tracks are returned, so both lists should
-- have the same length and correspond if you zip them up.
type Tracks = (BlockId, [TrackNum], [TrackId], Events.Range)

-- | Get selected event tracks along with the selection.  The tracks are
-- returned in ascending order.  Only event tracks are returned, and tracks
-- merged into the selected tracks are included.
tracks :: Cmd.M m => m Tracks
tracks = ctx_tracks =<< context

-- | Just the TrackIds part of 'tracks'.
track_ids :: Cmd.M m => m [TrackId]
track_ids = do
    (_, _, track_ids, _) <- tracks
    return track_ids

tracknums :: Cmd.M m => m (BlockId, [TrackNum])
tracknums = do
    (block_id, tracknums, _, _) <- tracks
    return (block_id, tracknums)

event_track :: Cmd.M m => m (BlockId, TrackId)
event_track = ctx_event_track =<< context

ctx_event_track :: Ui.M m => Context -> m (BlockId, TrackId)
ctx_event_track ctx = do
    (block_id, mb_track_id) <- ctx_track ctx
    track_id <- Ui.require "must select an event track" mb_track_id
    return (block_id, track_id)

track :: Cmd.M m => m (BlockId, Maybe TrackId)
track = ctx_track =<< context

ctx_track :: Ui.M m => Context -> m (BlockId, Maybe TrackId)
ctx_track ctx = do
    let block_id = ctx_block_id ctx
    maybe_track_id <-
        Ui.event_track_at block_id (sel_point_track (ctx_selection ctx))
    return (block_id, maybe_track_id)

-- | Selected tracks, including merged tracks.
ctx_tracks :: Ui.M m => Context -> m Tracks
ctx_tracks ctx = do
    (block_id, tracknums, track_ids, range) <- ctx_strict_tracks ctx
    tracks <- mapM (Ui.get_block_track_at block_id) tracknums
    let merged_track_ids = mconcatMap Block.track_merged tracks
    block <- Ui.get_block block_id
    let merged = tracknums_of block (Set.toList merged_track_ids)
    let (all_tracknums, all_track_ids) = unzip $ Lists.uniqueSort $
            merged ++ zip tracknums track_ids
    return (block_id, all_tracknums, all_track_ids, range)

-- | Selected tracks, not including merged tracks.
ctx_strict_tracks :: Ui.M m => Context -> m Tracks
ctx_strict_tracks ctx = do
    let block_id = ctx_block_id ctx
    tracks <- Ui.track_count block_id
    let tracknums = Sel.tracknums tracks (ctx_selection ctx)
    tracklikes <- mapM (Ui.track_at block_id) tracknums
    (tracknums, track_ids) <- return $ unzip
        [ (i, track_id)
        | (i, Just (Block.TId track_id _)) <- zip tracknums tracklikes
        ]
    return
        ( block_id, tracknums, track_ids
        , Events.selection_range (ctx_selection ctx)
        )

tracknums_of :: Block.Block -> [TrackId] -> [(TrackNum, TrackId)]
tracknums_of block track_ids = do
    (tracknum, Block.TId tid _) <-
        zip [0..] (Block.block_tracklike_ids block)
    guard (tid `elem` track_ids)
    return (tracknum, tid)

-- * history

-- | Keep only this many selection history entries.  This is hardcoded and low
-- since I'm probably not interested in ancient selections.
keep_history :: Int
keep_history = 10

record_history :: Cmd.M m => m ()
record_history =
    whenJustM lookup_context (modify_history . record . ctx_view_selection)
    where
    -- Only record the current position if it has changed.
    record view_sel hist
        | take 1 (Cmd.sel_past hist) /= [view_sel] = Cmd.SelectionHistory
            { sel_past = take keep_history $ view_sel : Cmd.sel_past hist
            , sel_future = []
            }
        | otherwise = hist

previous_selection :: Cmd.M m => Bool -> m ()
previous_selection change_views = do
    old_view_id <- Cmd.get_focused_view
    cur <- fmap ctx_view_selection <$> lookup_context
    hist <- Cmd.gets Cmd.state_selection_history
    case dropWhile ((==cur) . Just) $ Cmd.sel_past hist of
        (view_id, sel) : past | change_views || view_id == old_view_id -> do
            modify_history $ \hist -> hist
                { Cmd.sel_past = past
                , Cmd.sel_future = maybe id (:) cur (Cmd.sel_future hist)
                }
            set_without_history view_id (Just sel)
            when (view_id /= old_view_id) $ Cmd.focus view_id
        _ -> return ()

next_selection :: Cmd.M m => Bool -> m ()
next_selection change_views = do
    old_view_id <- Cmd.get_focused_view
    cur <- fmap ctx_view_selection <$> lookup_context
    hist <- Cmd.gets Cmd.state_selection_history
    case dropWhile ((==cur) . Just) $ Cmd.sel_future hist of
        (view_id, sel) : future | change_views || view_id == old_view_id -> do
            modify_history $ \hist -> hist
                { Cmd.sel_past = maybe id (:) cur (Cmd.sel_past hist)
                , Cmd.sel_future = future
                }
            set_without_history view_id (Just sel)
            when (view_id /= old_view_id) $ Cmd.focus view_id
        _ -> return ()

modify_history :: Cmd.M m => (Cmd.SelectionHistory -> Cmd.SelectionHistory)
    -> m ()
modify_history f = Cmd.modify $ \state -> state
    { Cmd.state_selection_history = f (Cmd.state_selection_history state) }
