{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable #-}
{- | The overall UI state is described here.  This is an immutable data
    structure that contains all the tracks, rulers, note data, and so forth.
    It exports a StateT monad for modification and access.

    Since the same block may have \>=0 views, and a single track may appear in
    \>=0 blocks, these are stored as IDs rather than directly in their
    containers.  Using explicit references introduces all the usual problems
    with pointers like invalid references and unreferenced data.  The latter is
    actually a feature (e.g. having a block with no associated view is
    perfectly normal), but the former is a pain.  To ease the pain, IDs should
    only be created via the monadic create_* interface in this module, even
    though I'm forced to export their constructors to avoid circular imports.
    There may still be problems with IDs from one State being applied to
    a different State (likely an older and newer version of the same State),
    but I'll deal with that when I get there.

    A higher level interface (e.g. "Cmd.Create") may ease this by automatically
    creating objects with automatically generated IDs.
-}
module Ui.State where
import qualified Control.Applicative as Applicative
import qualified Control.DeepSeq as DeepSeq
import Control.Monad
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.State as State
import qualified Control.Monad.Trans as Trans
import Control.Monad.Trans (lift)

import qualified Data.Generics as Generics
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Tree as Tree

import Util.Control
import qualified Util.Log as Log
import qualified Util.Logger as Logger
import qualified Util.Pretty as Pretty
import qualified Util.Rect as Rect
import qualified Util.Seq as Seq
import qualified Util.Tree as Tree

import Ui
import qualified Ui.Block as Block
import qualified Ui.Color as Color
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.Id as Id
import qualified Ui.Ruler as Ruler
import qualified Ui.Skeleton as Skeleton
import qualified Ui.Track as Track
import qualified Ui.Types as Types
import qualified Ui.Update as Update

import qualified Derive.Score as Score
import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal

import qualified App.Config as Config


data State = State {
    -- | The default namespace is used for automatically created IDs, so each
    -- project can import other projects without clashes.  The save file is
    -- also derived from the default namespace.
    state_namespace :: Id.Namespace
    -- | Save into this directory by default.
    , state_project_dir :: String
    -- | Derivation can start from any block, but it's useful to know which
    -- block represents the entire piece.  This way, given a position on some
    -- block I can determine where in the piece it lies, if anywhere.  This is
    -- useful for playing a block in proper context, or communicating with
    -- a program with a more absolute notion of time, like a DAW.
    , state_root :: Maybe BlockId
    , state_views :: Map.Map ViewId Block.View
    , state_blocks :: Map.Map BlockId Block.Block
    -- | Track data also gets a symbol table.  This is so that I can
    -- efficiently compare a track for identity, and also so I can
    -- change it here and all of its occurrances change.
    , state_tracks :: Map.Map TrackId Track.Track
    , state_rulers :: Map.Map RulerId Ruler.Ruler

    -- | This maps the midi instruments used in this State to their Addrs.
    , state_midi_config :: Instrument.Config
    , state_default :: Default
    } deriving (Read, Show, Generics.Typeable)

-- TODO "initial_state" would be more consistent
empty :: State
empty = State {
    state_namespace = "untitled"
    , state_project_dir = "save"
    , state_root = Nothing
    , state_views = Map.empty
    , state_blocks = Map.empty
    , state_tracks = Map.empty
    , state_rulers = ruler_map
    , state_midi_config = Instrument.config []
    , state_default = initial_default
    }
    where ruler_map = Map.fromList [(no_ruler, Ruler.no_ruler)]

instance DeepSeq.NFData State where
    rnf (State proj dir root views blocks tracks rulers midi_conf deflt) =
        proj `seq` dir `seq` root
        `seq` DeepSeq.rnf views `seq` DeepSeq.rnf blocks
        `seq` DeepSeq.rnf tracks `seq` DeepSeq.rnf rulers
        `seq` midi_conf `seq` DeepSeq.rnf deflt

-- | Initial values for derivation.
data Default = Default {
    -- | Automatically created pitch tracks will have this scale.  MIDI thru
    -- will also use it when a scale can't be derived from focus.
    default_scale :: Pitch.ScaleId
    -- | This instrument is present in the initial environment, so it will be
    -- the instrument in scope in abscence of any others.
    , default_instrument :: Maybe Score.Instrument
    -- | A toplevel block without a tempo track will get this tempo.
    , default_tempo :: Signal.Y
    } deriving (Read, Show, Generics.Typeable)

initial_default :: Default
initial_default = Default {
    default_scale = Pitch.ScaleId Config.default_scale_id
    , default_instrument = Nothing
    , default_tempo = 1
    }

instance DeepSeq.NFData Default where
    rnf (Default scale inst tempo) = scale `seq` inst `seq` tempo `seq` ()

-- | Since all TracklikeIds must have a ruler, all States have a special empty
-- ruler that can be used in a \"no ruler\" situation.
--
-- To enforce its global nature, this should never be renamed or deleted, which
-- is enforced by 'map_ids' and 'destroy_ruler', but it's still possible.  So
-- don't do that.
no_ruler :: RulerId
no_ruler = Types.RulerId (Id.global "_no_ruler_")

-- | A non-existent ruler, ready for inclusion into create_block's track list.
no_ruler_track :: Block.Track
no_ruler_track = Block.track (Block.RId no_ruler) 0

-- * StateT monadic access

-- | Run the given StateT with the given initial state, and return a new
-- state along with updates.  Normally updates are produced by 'Ui.Diff.diff',
-- but for efficiency updates to track data are accumulated when they are
-- actually made.  All the UI needs is a ScoreTime range to redraw in, and
-- redrawing the whole track isn't that expensive.
--
-- See the StateStack comment for more.
run :: (Monad m) =>
   State -> StateT m a -> m (Either StateError (a, State, [Update.Update]))
run state m = do
    res <- (Error.runErrorT . Logger.run . flip State.runStateT state
        . run_state_t) m
    return $ case res of
        Left err -> Left err
        Right ((val, state), updates) -> Right (val, state, updates)

eval_rethrow :: (M m) => String -> State -> StateId a -> m a
eval_rethrow msg state = throw_either msg . eval state

-- | A form of 'run' that returns only the val and automatically runs in
-- Identity.
eval :: State -> StateId a -> Either StateError a
eval state m = case result of
        Left err -> Left err
        Right (val, _, _) -> Right val
    where result = Identity.runIdentity (run state m)

exec :: State -> StateId a -> Either StateError State
exec state m = case result of
        Left err -> Left err
        Right (_, state', _) -> Right state'
    where result = Identity.runIdentity (run state m)

exec_rethrow :: (M m) => String -> State -> StateId a -> m State
exec_rethrow msg state = throw_either msg . exec state

throw_either :: (M m) => String -> Either StateError a -> m a
throw_either msg = either (throw . ((msg ++ ": ") ++) . show) return

-- | Like 'throw_either', but throw an IO exception.  Useful for tests.
error_either :: (Show a, Monad m) => String -> Either StateError a -> m a
error_either msg = either (error . ((msg ++ ": ") ++) . show) return

-- | TrackUpdates are stored directly instead of being calculated from the
-- state diff.
--
-- Is there any way they could get out of sync with the actual change?  I don't
-- see how, since the updates are stored by track_id, which should always be
-- associated with the same track, and an operation to move event positions
-- will simply generate another TrackUpdate over the whole track.  This does
-- mean TrackUpdates can overlap, so 'Ui.Sync.sync' should collapse them.
type StateStack m = State.StateT State
    (Logger.LoggerT Update.Update
        (Error.ErrorT StateError m))
newtype StateT m a = StateT (StateStack m a)
    deriving (Functor, Monad, Trans.MonadIO, Error.MonadError StateError)
run_state_t (StateT x) = x

-- | Just a convenient abbreviation.
type StateId a = StateT Identity.Identity a

instance Trans.MonadTrans StateT where
    lift = StateT . lift . lift . lift

-- | Abort is used by Cmd, so don't throw it from here.  This isn't exactly
-- modular, but ErrorT can't be composed and extensible exceptions are too
-- much bother at the moment.
data StateError = StateError String | Abort deriving (Generics.Typeable, Show)
instance Error.Error StateError where
    strMsg = StateError

instance Pretty.Pretty StateError where
    pretty (StateError msg) = msg
    pretty Abort = "(abort)"

class (Applicative.Applicative m, Monad m) => M m where
    get :: m State
    put :: State -> m ()
    update :: Update.Update -> m ()
    throw :: String -> m a

instance (Applicative.Applicative m, Monad m) => M (StateT m) where
    get = StateT State.get
    put st = StateT (State.put st)
    update upd = (StateT . lift) (Logger.log upd)
    throw msg = (StateT . lift . lift) (Error.throwError (StateError msg))

instance (Functor m, Monad m) => Applicative.Applicative (StateT m) where
    pure = return
    (<*>) = ap

gets :: (M m) => (State -> a) -> m a
gets f = fmap f get

modify :: (M m) => (State -> State) -> m ()
modify f = do
    state <- get
    put $! f state


-- * misc

-- | Unfortunately there are some invariants to protect within State.  This
-- will check the invariants, log warnings and fix them if possible (that's why
-- it returns another state), or throw an error if not.
--
-- The invariants should be protected by the modifiers in this module, but
-- this is just in case.
verify :: State -> (Either StateError State, [Log.Msg])
verify state = (fmap (\(_, s, _) -> s) result, logs)
    where (result, logs) = Identity.runIdentity (Log.run (run state do_verify))

-- TODO
-- check that all views refer to valid blocks, and all TracklikeIds have
-- referents
-- anything else?
do_verify :: StateT (Log.LogT Identity.Identity) ()
do_verify = do
    view_ids <- get_all_view_ids
    mapM_ verify_view view_ids

    block_ids <- get_all_block_ids
    blocks <- mapM get_block block_ids
    mapM_ verify_block blocks

verify_view :: ViewId -> StateT (Log.LogT Identity.Identity) ()
verify_view view_id = do
    view <- get_view view_id
    block <- get_block (Block.view_block view)
    let btracks = length (Block.block_tracks block)
        vtracks = length (Block.view_tracks view)
    when (btracks /= vtracks) $
        Trans.lift $ Log.warn $ "block has " ++ show btracks
            ++ " tracks while view has " ++ show vtracks ++ ", fixing"
    -- Add track views for all the block tracks.
    forM_ [vtracks .. btracks-1] $ \tracknum ->
        modify_view view_id $ \v -> insert_into_view tracknum 20 v

verify_block :: (M m) => Block.Block -> m ()
verify_block block = do
    mapM_ get_track (Block.block_track_ids block)
    mapM_ get_ruler (Block.block_ruler_ids block)

get_namespace :: (M m) => m Id.Namespace
get_namespace = gets state_namespace

set_namespace :: (M m) => Id.Namespace -> m ()
set_namespace ns = modify $ \st -> st { state_namespace = ns }

get_midi_config :: (M m) => m Instrument.Config
get_midi_config = gets state_midi_config

set_midi_config :: (M m) => Instrument.Config -> m ()
set_midi_config config = modify $ \st -> st { state_midi_config = config }

get_midi_alloc :: (M m) => m (Map.Map Score.Instrument [Instrument.Addr])
get_midi_alloc = Instrument.config_alloc <$> get_midi_config

get_default :: (M m) => (Default -> a) -> m a
get_default f = f <$> gets state_default

modify_default :: (M m) => (Default -> Default) -> m ()
modify_default f = modify $ \st -> st { state_default = f (state_default st) }

-- * root

lookup_root_id :: (M m) => m (Maybe BlockId)
lookup_root_id = gets state_root

set_root_id :: (M m) => BlockId -> m ()
set_root_id block_id = modify $ \st -> st { state_root = Just block_id }

-- * view

get_view :: (M m) => ViewId -> m Block.View
get_view view_id = get >>= lookup_id view_id . state_views

lookup_view :: (M m) => ViewId -> m (Maybe Block.View)
lookup_view view_id = get >>= return . Map.lookup view_id . state_views

get_all_view_ids :: (M m) => m [ViewId]
get_all_view_ids = gets (Map.keys . state_views)

-- | Create a new view.  Block.view_tracks can be left empty, since it will
-- be replaced by views generated from the the block.  If the caller uses the
-- 'Block.view' constructor, it won't have to worry about this.
--
-- Throw if the ViewId already exists.
create_view :: (M m) => Id.Id -> Block.View -> m ViewId
create_view id view = do
    block <- get_block (Block.view_block view)
    let view' = view { Block.view_tracks = initial_track_views block }
    get >>= insert (Types.ViewId id) view' state_views
        (\views st -> st { state_views = views })
initial_track_views block = map Block.TrackView widths
    where widths = map Block.track_width (Block.block_tracks block)

destroy_view :: (M m) => ViewId -> m ()
destroy_view view_id = modify $ \st ->
    st { state_views = Map.delete view_id (state_views st) }

set_view_config :: (M m) => ViewId -> Block.ViewConfig -> m ()
set_view_config view_id config =
    modify_view view_id (\view -> view { Block.view_config = config })

-- | Update @tracknum@ of @view_id@ to have width @width@.
set_track_width :: (M m) => ViewId -> TrackNum -> Types.Width -> m ()
set_track_width view_id tracknum width = do
    view <- get_view view_id
    -- Functional update still sucks.  An imperative language would have:
    -- state.get_view(view_id).tracks[tracknum].width = width
    track_views <- modify_at "set_track_width"
        (Block.view_tracks view) tracknum $ \tview ->
            tview { Block.track_view_width = width }
    update_view view_id (view { Block.view_tracks = track_views })

-- ** zoom and track scroll

get_zoom :: (M m) => ViewId -> m Types.Zoom
get_zoom view_id = fmap Block.view_zoom (get_view view_id)

set_zoom :: (M m) => ViewId -> Types.Zoom -> m ()
set_zoom view_id zoom =
    modify_view view_id (\view -> view { Block.view_zoom = clamped })
    where clamped = zoom { Types.zoom_offset = max 0 (Types.zoom_offset zoom) }

set_track_scroll :: (M m) => ViewId -> Types.Width -> m ()
set_track_scroll view_id offset =
    modify_view view_id (\view -> view { Block.view_track_scroll = offset })

set_view_rect :: (M m) => ViewId -> Rect.Rect -> m ()
set_view_rect view_id rect =
    modify_view view_id (\view -> view { Block.view_rect = rect })

-- | Only 'Cmd.Cmd.ui_update' is supposed to call this, because track_size is
-- only set from the UI.
set_track_size :: (M m) => ViewId -> (Int, Int) -> m ()
set_track_size view_id (visible_track, visible_time) =
    modify_view view_id $ \view -> view {
        Block.view_visible_track = visible_track
        , Block.view_visible_time = visible_time }

-- ** selections

-- | Get @view_id@'s selection at @selnum@, or Nothing if there is none.
get_selection :: (M m) => ViewId -> Types.SelNum -> m (Maybe Types.Selection)
get_selection view_id selnum = do
    view <- get_view view_id
    return (Map.lookup selnum (Block.view_selections view))

-- | Replace any selection on @view_id@ at @selnum@ with @sel@.
set_selection :: (M m) => ViewId -> Types.SelNum
    -> Maybe Types.Selection -> m ()
set_selection view_id selnum maybe_sel = do
    view <- get_view view_id
    let sels = case maybe_sel of
            Nothing -> Map.delete selnum (Block.view_selections view)
            Just sel -> Map.insert selnum sel (Block.view_selections view)
    update_view view_id (view { Block.view_selections = sels })

-- ** util

update_view view_id view = modify $ \st -> st
    { state_views = Map.adjust (const view) view_id (state_views st) }
modify_view view_id f = do
    view <- get_view view_id
    update_view view_id (f view)

-- * block

get_all_block_ids :: (M m) => m [BlockId]
get_all_block_ids = gets (Map.keys . state_blocks)

get_block :: (M m) => BlockId -> m Block.Block
get_block block_id = get >>= lookup_id block_id . state_blocks

lookup_block :: (M m) => BlockId -> m (Maybe Block.Block)
lookup_block block_id = get >>= return . Map.lookup block_id . state_blocks

-- | Make a new block.  If it's the first one, it will be set as the root.
--
-- Throw if the BlockId already exists.
create_block :: (M m) => Id.Id -> Block.Block -> m BlockId
create_block id block = get >>= insert (Types.BlockId id) block state_blocks
    (\blocks st -> st
        { state_blocks = blocks
        , state_root = if Map.size blocks == 1 then Just (Types.BlockId id)
            else state_root st
        })

-- | Destroy the block and all the views that display it.  If the block was
-- the root, it will be be unset.  The block's tracks are left intact.
destroy_block :: (M m) => BlockId -> m ()
destroy_block block_id = do
    views <- get_views_of block_id
    mapM_ destroy_view (Map.keys views)
    modify $ \st -> st
        { state_blocks = Map.delete block_id (state_blocks st)
        , state_root = if state_root st == Just block_id then Nothing
            else state_root st
        }

block_of :: (M m) => ViewId -> m Block.Block
block_of view_id = get_block . Block.view_block =<< get_view view_id

block_id_of :: (M m) => ViewId -> m BlockId
block_id_of view_id = Block.view_block <$> get_view view_id

set_block_config :: (M m) => BlockId -> Block.Config -> m ()
set_block_config block_id config =
    modify_block block_id (\block -> block { Block.block_config = config })

set_edit_box :: (M m) => BlockId -> Color.Color -> Char -> m ()
set_edit_box block_id color char = do
    block <- get_block block_id
    set_block_config block_id $
        (Block.block_config block) { Block.config_track_box = (color, char) }

-- | The play box doesn't use a char, so I leave that out.
set_play_box :: (M m) => BlockId -> Color.Color -> m ()
set_play_box block_id color = do
    block <- get_block block_id
    set_block_config block_id $
        (Block.block_config block) { Block.config_sb_box = (color, ' ') }

-- | Get the end of the block according to the ruler.  This means that if the
-- block has no rulers (e.g. a clipboard block) then block_ruler_end will be 0.
block_ruler_end :: (M m) => BlockId -> m ScoreTime
block_ruler_end block_id = do
    block <- get_block block_id
    case Block.block_ruler_ids block of
        [] -> return 0
        ruler_id : _ -> Ruler.time_end <$> get_ruler ruler_id

-- | Get the end of the block according to the last event of the block.
block_event_end :: (M m) => BlockId -> m ScoreTime
block_event_end block_id = do
    block <- get_block block_id
    track_ends <- mapM track_end (Block.block_track_ids block)
    return $ maximum (0 : track_ends)

-- ** skeleton

get_skeleton :: (M m) => BlockId -> m Skeleton.Skeleton
get_skeleton block_id = Block.block_skeleton <$> get_block block_id

set_skeleton :: (M m) => BlockId -> Skeleton.Skeleton -> m ()
set_skeleton block_id skel =
    modify_block block_id (\block -> block { Block.block_skeleton = skel })

-- | Toggle the given edge in the block's skeleton.  If a cycle would be
-- created, refuse to add the edge and return False.  The edge is in (parent,
-- child) order.
toggle_skeleton_edge :: (M m) => BlockId -> (TrackNum, TrackNum) -> m Bool
toggle_skeleton_edge block_id edge = do
    block <- get_block block_id
    when_just (verify_edge block edge) (throw . ("toggle: " ++))
    let skel = Block.block_skeleton block
    case Skeleton.toggle_edge edge skel of
        Nothing -> return False
        Just new_skel -> do
            set_block block_id $ block { Block.block_skeleton = new_skel }
            return True

-- | Splice the given edge into the skeleton.  That means the given child will
-- be unlinked from its parent and relinked to the given parent, and the given
-- parent will be linked to the old child's parent.
-- This is not a toggle, so it should be idempotent.
splice_skeleton :: (M m) => BlockId -> (TrackNum, TrackNum) -> m ()
splice_skeleton block_id edge = do
    block <- get_block block_id
    when_just (verify_edge block edge) (throw . ("splice: " ++))
    let skel = Block.block_skeleton block
    set_block block_id $
        block { Block.block_skeleton = Skeleton.splice edge skel }

verify_edge :: Block.Block -> (TrackNum, TrackNum) -> Maybe String
verify_edge block (from, to) = case (Seq.at tracks from, Seq.at tracks to) of
    (Just t1, Just t2) -> case (Block.tracklike_id t1, Block.tracklike_id t2) of
        (Block.TId {}, Block.TId {}) -> Nothing
        _ -> Just "edge points to non event track"
    _ -> Just "edge points to track out of range"
    where tracks = Block.block_tracks block

-- *** TrackTree

-- | A TrackTree is the Skeleton resolved to the tracks it references.
type TrackTree = Tree.Forest TrackInfo
-- | A TrackTree annotated with which tracks are muted.
type TrackTreeMutes = Tree.Forest (TrackInfo, Bool)

-- | Summary information on a Track.
data TrackInfo = TrackInfo {
    track_title :: String
    , track_id :: TrackId
    , track_tracknum :: TrackNum
    } deriving (Show)

get_track_info :: (M m) => BlockId -> m [TrackInfo]
get_track_info block_id = do
    block <- get_block block_id
    state <- get
    return [TrackInfo (Track.track_title track) tid i
        | (i, tid, track) <- _track_tree_tracks_of block (state_tracks state)]

get_track_tree :: (M m) => BlockId -> m TrackTree
get_track_tree block_id = do
    skel <- get_skeleton block_id
    tracks <- get_track_info block_id
    ntracks <- fmap (length . Block.block_tracklike_ids) (get_block block_id)
    let by_tracknum = Map.fromList $ zip (map track_tracknum tracks) tracks
    let (resolved, missing) = _track_tree_resolve by_tracknum
            (Skeleton.to_forest ntracks skel)
    -- Rulers and dividers should show up as missing.  They're ok as long as
    -- they have no edges.
    let really_missing = filter (not . Skeleton.lonely_vertex skel) missing
    unless (null really_missing) $
        throw $ "skeleton of " ++ show block_id
            ++ " names missing tracknums: " ++ show really_missing
    return resolved

get_track_tree_mutes :: (M m) => BlockId -> m TrackTreeMutes
get_track_tree_mutes block_id = do
    tree <- get_track_tree block_id
    block <- get_block block_id
    return $ track_tree_mutes (muted_tracknums block tree) tree

muted_tracknums :: Block.Block -> TrackTree -> [TrackNum]
muted_tracknums block tree
    | null solo = mute
    | otherwise = map fst tracks List.\\ soloed
    where
    tracks =
        [(i, track) | (i, track) <- Seq.enumerate (Block.block_tracks block),
            is_track track]
    is_track track = case Block.tracklike_id track of
        Block.TId {} -> True
        _ -> False
    solo = [i | (i, t) <- tracks, Block.Solo `elem` Block.track_flags t]
    mute = [i | (i, t) <- tracks, Block.Mute `elem` Block.track_flags t]
    -- A soloed track will keep all its parents and children unmuted.
    soloed = List.nub $ concat
        [ track_tracknum t : map track_tracknum (ps ++ cs)
        | (t, ps, cs) <- Tree.paths tree, track_tracknum t `elem` solo ]

track_tree_mutes :: [TrackNum] -> TrackTree -> TrackTreeMutes
track_tree_mutes muted forest = map f forest
    where
    f (Tree.Node info subs) = Tree.Node (add_mute info) (map f subs)
    add_mute info = (info, track_tracknum info `elem` muted)


_track_tree_tracks_of :: Block.Block -> Map.Map TrackId Track.Track
    -> [(TrackNum, TrackId, Track.Track)]
_track_tree_tracks_of block tracks = do
    (i, Block.TId tid _) <- Seq.enumerate (Block.block_tracklike_ids block)
    track <- maybe mzero (:[]) (Map.lookup tid tracks)
    return (i, tid, track)

_track_tree_resolve :: Map.Map TrackNum TrackInfo -> Tree.Forest TrackNum
    -> (Tree.Forest TrackInfo, [TrackNum])
_track_tree_resolve tracknums = foldr cat_tree ([], []) . map go
    where
    go (Tree.Node tracknum subs) = case Map.lookup tracknum tracknums of
        Nothing -> (Nothing, [tracknum])
        Just track_info ->
            let (subforest, missing) = _track_tree_resolve tracknums subs
            in (Just (Tree.Node track_info subforest), missing)
    cat_tree (maybe_tree, missing) (forest, all_missing) = case maybe_tree of
        Nothing -> (forest, missing ++ all_missing)
        Just tree -> (tree : forest, missing ++ all_missing)


type EventsTree = [EventsNode]
type EventsNode = Tree.Tree TrackEvents

data TrackEvents = TrackEvents {
    tevents_title :: !String
    , tevents_events :: !Events.Events
    -- | Tracks often extend beyond the end of the last event.  The derivers
    -- need to know the track end to get the controls of the last note, and for
    -- the block stretch hack.
    , tevents_end :: !ScoreTime
    -- | If this TrackEvents is from a real track, then its evaluation can
    -- generate a render signal as a side-effect.
    , tevents_track_id :: !(Maybe TrackId)
    -- | Range of the track.  This may be past the end of the last event since
    -- it's the range of the block as a whole.
    --
    -- Used by "Derive.Cache": due to inverting calls, a control track may be
    -- sliced to a shorter range.  In that case, I shouldn't bother with
    -- damage outside of its range.
    , tevents_range :: !(ScoreTime, ScoreTime)
    -- | True if this is a sliced track.  That means it's a fragment of
    -- a track and so certain track-level things, like recording a track
    -- signal, should be skipped.
    , tevents_sliced :: Bool
    } deriving (Show)

events_tree :: (M m) => ScoreTime -> TrackTree -> m EventsTree
events_tree block_end tree = mapM resolve tree
    where
    resolve (Tree.Node (TrackInfo title track_id _) subs) =
        Tree.Node <$> make title track_id <*> mapM resolve subs
    make title track_id = do
        track <- get_track track_id
        return $ TrackEvents title (Track.track_events track) block_end
            (Just track_id) (0, block_end) False

-- ** tracks

insert_track :: (M m) => BlockId -> TrackNum -> Block.Track -> m ()
insert_track block_id tracknum track = do
    block <- get_block block_id
    views <- get_views_of block_id
    let tracks = Block.block_tracks block
        tracks' = Seq.insert_at tracks tracknum track
        -- Make sure the views are up to date.
        views' = Map.map
            (insert_into_view tracknum (Block.track_width track)) views
    set_block block_id $ block
        { Block.block_tracks = tracks'
        , Block.block_skeleton =
            Skeleton.insert tracknum (Block.block_skeleton block)
        }
    modify $ \st -> st { state_views = Map.union views' (state_views st) }

remove_track :: (M m) => BlockId -> TrackNum -> m ()
remove_track block_id tracknum = do
    block <- get_block block_id
    views <- get_views_of block_id
    let tracks' = Seq.remove_at (Block.block_tracks block) tracknum
        views' = Map.map (remove_from_view tracknum) views
    set_block block_id $ block
        { Block.block_tracks = tracks'
        , Block.block_skeleton =
            Skeleton.remove tracknum (Block.block_skeleton block)
        }
    modify $ \st -> st { state_views = Map.union views' (state_views st) }

-- | Get the Track at @tracknum@, or Nothing if its out of range.
-- This is inconsistent with 'insert_track' and 'remove_track' which clip to
-- range, but is convenient in practice.
-- TODO why?
block_track_at :: (M m) => BlockId -> TrackNum -> m (Maybe Block.Track)
block_track_at block_id tracknum
    | tracknum < 0 =
        throw $ "block_track_at: negative tracknum " ++ show tracknum
    | otherwise = do
        block <- get_block block_id
        return $ Seq.at (Block.block_tracks block) tracknum

track_at :: (M m) => BlockId -> TrackNum -> m (Maybe Block.TracklikeId)
track_at block_id tracknum = do
    maybe_track <- block_track_at block_id tracknum
    return $ fmap Block.tracklike_id maybe_track

-- | Like 'track_at', but only for event tracks.
event_track_at :: (M m) => BlockId -> TrackNum -> m (Maybe TrackId)
event_track_at block_id tracknum = do
    maybe_track <- track_at block_id tracknum
    return $ Block.track_id_of =<< maybe_track

-- | Like 'track_at', but only for event tracks.  It defaults to 'no_ruler'
-- if the tracknum is out of range or doesn't have a ruler.
ruler_track_at :: (M m) => BlockId -> TrackNum -> m RulerId
ruler_track_at block_id tracknum = do
    maybe_track <- track_at block_id tracknum
    return $ Maybe.fromMaybe no_ruler $ Block.ruler_id_of =<< maybe_track

-- | Like 'event_track_at' but throws if it's not there.
get_event_track_at :: (M m) => String -> BlockId -> TrackNum -> m TrackId
get_event_track_at caller block_id tracknum =
    maybe (throw msg) return =<< event_track_at block_id tracknum
    where
    msg = caller ++ ": tracknum " ++ show tracknum ++ " not in "
        ++ show block_id

tracks :: (M m) => BlockId -> m TrackNum
tracks block_id = do
    block <- get_block block_id
    return $ length (Block.block_tracks block)

get_tracklike :: (M m) => Block.TracklikeId -> m Block.Tracklike
get_tracklike track = case track of
    Block.TId track_id ruler_id ->
        Block.T <$> get_track track_id <*> get_ruler ruler_id
    Block.RId ruler_id ->
        Block.R <$> get_ruler ruler_id
    Block.DId divider -> return (Block.D divider)

-- *** block track

get_block_track :: (M m) => BlockId -> TrackNum -> m Block.Track
get_block_track block_id tracknum = do
    block <- get_block block_id
    let msg = "State.get_block_track: bad tracknum for " ++ show block_id
            ++ ": " ++ show tracknum
    maybe (throw msg) return (Seq.at (Block.block_tracks block) tracknum)

modify_block_track :: (M m) => BlockId -> TrackNum
    -> (Block.Track -> Block.Track) -> m ()
modify_block_track block_id tracknum modify = do
    block <- get_block block_id
    btracks <- modify_at "modify_block_track"
        (Block.block_tracks block) tracknum modify
    modify_block block_id $ \b -> b { Block.block_tracks = btracks }

toggle_track_flag :: (M m) => BlockId -> TrackNum -> Block.TrackFlag -> m ()
toggle_track_flag block_id tracknum flag =
    modify_track_flags block_id tracknum toggle
    where
    toggle flags
        | flag `elem` flags = List.delete flag flags
        | otherwise = flag : flags

add_track_flag, remove_track_flag
    :: (M m) => BlockId -> TrackNum -> Block.TrackFlag -> m ()
add_track_flag block_id tracknum flag =
    modify_track_flags block_id tracknum (List.union [flag])
remove_track_flag block_id tracknum flag =
    modify_track_flags block_id tracknum (List.delete flag)

modify_track_flags :: (M m) => BlockId -> TrackNum
    -> ([Block.TrackFlag] -> [Block.TrackFlag]) -> m ()
modify_track_flags block_id tracknum f =
    modify_block_track block_id tracknum $ \btrack ->
        btrack { Block.track_flags = f (Block.track_flags btrack) }

-- | Merge the @from@ tracknum into the @to@ tracknum and collapse @from@.
merge_track :: (M m) => BlockId -> TrackNum -> TrackNum -> m ()
merge_track block_id to from = do
    from_id <- get_event_track_at "State.merge_track" block_id from
    modify_block_track block_id to $ \btrack ->
        btrack { Block.track_merged = from_id : Block.track_merged btrack }
    add_track_flag block_id from Block.Collapse

-- | Reverse 'merge_track': remove the merged tracks and expand their
-- occurrances in the given block.  \"Unmerge\" is not graceful, but at least
-- it's obviously the opposite of \"merge\".
unmerge_track :: (M m) => BlockId -> TrackNum -> m ()
unmerge_track block_id tracknum = do
    track_ids <- Block.track_merged <$> get_block_track block_id tracknum
    unmerged_tracknums <-
        concat <$> mapM (track_id_tracknums block_id) track_ids
    forM_ unmerged_tracknums $ \tracknum ->
        remove_track_flag block_id tracknum Block.Collapse
    set_merged_tracks block_id tracknum []

set_merged_tracks :: (M m) => BlockId -> TrackNum -> [TrackId] -> m ()
set_merged_tracks block_id tracknum merged =
    modify_block_track block_id tracknum $ \btrack ->
        btrack { Block.track_merged = merged }

track_id_tracknums :: (M m) => BlockId -> TrackId -> m [TrackNum]
track_id_tracknums block_id track_id = do
    block_tracks <- blocks_with_track track_id
    return [tracknum | (bid, tracks) <- block_tracks, bid == block_id,
        (tracknum, _) <- tracks]

-- *** track util

-- Insert a new track into Block.view_tracks, moving selections as
-- appropriate.  @tracknum@ is clipped to be in range.
insert_into_view tracknum width view = view
    { Block.view_tracks = Seq.insert_at (Block.view_tracks view) tracknum
        (Block.TrackView width)
    , Block.view_selections =
        Map.map (insert_into_selection tracknum) (Block.view_selections view)
    }

-- Remove @tracknum@ from Block.view_tracks, moving selections as
-- appropriate.  Ignored if @tracknum@ is out of range.
remove_from_view tracknum view = view
    { Block.view_tracks = Seq.remove_at (Block.view_tracks view) tracknum
    , Block.view_selections = Map.mapMaybe
        (remove_from_selection tracknum) (Block.view_selections view)
    }

-- If tracknum is before or at the selection, push it to the right.  If it's
-- inside, extend it.  If it's to the right, do nothing.
insert_into_selection tracknum sel
    | tracknum <= min track0 track1 = Types.sel_modify_tracks (+1) sel
    | tracknum <= max track0 track1 = Types.sel_expand_tracks 1 sel
    | otherwise = sel
    where (track0, track1) = Types.sel_track_range sel

remove_from_selection tracknum sel
    | tracknum <= min track0 track1  =
        Just $ Types.sel_modify_tracks (+(-1)) sel
    | tracknum == track0 && tracknum == track1 = Nothing
    | tracknum <= max track0 track1 = Just $ Types.sel_expand_tracks (-1) sel
    | otherwise = Just sel
    where (track0, track1) = Types.sel_track_range sel

-- ** other

set_block_title :: (M m) => BlockId -> String -> m ()
set_block_title block_id title =
    modify_block block_id (\block -> block { Block.block_title = title })

-- | Set a status variable on a view.
set_view_status :: (M m) => ViewId -> String -> Maybe String -> m ()
set_view_status view_id key val =
    modify_view view_id $ \view -> view { Block.view_status =
        Map.alter (const val) key (Block.view_status view) }

-- ** util

set_block block_id block = modify $ \st -> st
    { state_blocks = Map.adjust (const block) block_id (state_blocks st) }
modify_block block_id f = do
    block <- get_block block_id
    set_block block_id (f block)

-- * track

get_track :: (M m) => TrackId -> m Track.Track
get_track track_id = get >>= lookup_id track_id . state_tracks

lookup_track :: (M m) => TrackId -> m (Maybe Track.Track)
lookup_track track_id = get >>= return . Map.lookup track_id . state_tracks

-- | Insert the given track with the given ID.
--
-- Throw if the TrackId already exists.
create_track :: (M m) => Id.Id -> Track.Track -> m TrackId
create_track id track = get >>= insert (Types.TrackId id) track state_tracks
    (\tracks st -> st { state_tracks = tracks })

-- | Destroy the track and remove it from all the blocks it's in.
destroy_track :: (M m) => TrackId -> m ()
destroy_track track_id = do
    blocks <- blocks_with_track track_id
    forM_ blocks $ \(block_id, tracks) -> forM_ tracks $ \(tracknum, _) ->
        remove_track block_id tracknum
    modify $ \st -> st { state_tracks = Map.delete track_id (state_tracks st) }

modify_track_title :: (M m) => TrackId -> (String -> String) -> m ()
modify_track_title track_id f = _modify_track track_id $ \track ->
    track { Track.track_title = f (Track.track_title track) }

set_track_title :: (M m) => TrackId -> String -> m ()
set_track_title track_id text = modify_track_title track_id (const text)

set_track_bg :: (M m) => TrackId -> Color.Color -> m ()
set_track_bg track_id color = _modify_track track_id $ \track ->
    track { Track.track_bg = color }

modify_track_render :: (M m) => TrackId
    -> (Track.RenderConfig -> Track.RenderConfig) -> m ()
modify_track_render track_id f = _modify_track track_id $ \track ->
    track { Track.track_render = f (Track.track_render track) }

set_render_style :: (M m) => Track.RenderStyle -> TrackId -> m ()
set_render_style style track_id = modify_track_render track_id $
    \render -> render { Track.render_style = style }

modify_track_events :: (M m) => TrackId
    -> (Events.Events -> Events.Events) -> m ()
modify_track_events track_id f = do
    _modify_track track_id (Track.modify_events f)
    update $ Update.TrackUpdate track_id Update.TrackAllEvents

-- ** events

-- There are two interpretations of a range: the strict one is that when
-- start==end nothing can be selected.  A more relaxed one is that start==end
-- will still select an event at start.  The relaxed one is often convenient
-- for commands, so there are typically three variants of each ranged command:
-- select events in the strict half-open range (functions end with _range),
-- select an event at a certain point (functions use the singular), and select
-- events in the relaxed half-open range (functions use the plural).

-- | Insert events into track_id as per 'Events.insert_events'.
insert_events :: (M m) => TrackId -> [Events.PosEvent] -> m ()
insert_events track_id pos_evts =
    -- Calculating updates is easiest if it's sorted, and insert likes sorted
    -- anyway.
    insert_sorted_events track_id (Seq.sort_on fst pos_evts)

-- | Like 'insert_events', but more efficient and dangerous.
insert_sorted_events :: (M m) => TrackId -> [(ScoreTime, Event.Event)] -> m ()
insert_sorted_events track_id pos_evts = _modify_events track_id $ \events ->
    (Events.insert_sorted_events pos_evts events, _events_updates pos_evts)

insert_event :: (M m) => TrackId -> ScoreTime -> Event.Event -> m ()
insert_event track_id pos evt = insert_sorted_events track_id [(pos, evt)]

get_events :: (M m) => TrackId -> ScoreTime -> ScoreTime -> m [Events.PosEvent]
get_events track_id start end = do
    events <- Track.track_events <$> get_track track_id
    return (_events_in_range start end events)

-- | Remove any events whose starting positions fall within the half-open
-- range given, or under the point if the selection is a point.
remove_events :: (M m) => TrackId -> ScoreTime -> ScoreTime -> m ()
remove_events track_id start end
    | start == end = remove_event track_id start
    | otherwise = remove_event_range track_id start end

-- | Remove a single event at @pos@, if there is one.
remove_event :: (M m) => TrackId -> ScoreTime -> m ()
remove_event track_id pos = _modify_events track_id $ \events ->
    case Events.at pos events of
        Nothing -> (events, [])
        Just evt ->
            (Events.remove_event pos events, _events_updates [(pos, evt)])

-- | Remove any events whose starting positions strictly fall within the
-- half-open range given.
remove_event_range :: (M m) => TrackId -> ScoreTime -> ScoreTime -> m ()
remove_event_range track_id start end =
    _modify_events track_id $ \events ->
        let evts = Events.ascending (Events.in_range start end events)
        in (Events.remove_events start end events, _events_updates evts)

map_events_sorted :: (M m) => TrackId -> ScoreTime -> ScoreTime
    -> ([Events.PosEvent] -> [Events.PosEvent]) -> m ()
map_events_sorted track_id start end f = _modify_events track_id $ \events ->
    let old = _events_in_range start end events
        new = f old
        deleted = if start == end
            then Events.remove_event start events
            else Events.remove_events start end events
        starts = map Events.event_min $ Maybe.mapMaybe Seq.head [old, new]
        ends = map Events.event_max $ Maybe.mapMaybe Seq.last [old, new]
        updates = if null starts || null ends then []
            else [(minimum starts, maximum ends)]
    in (Events.insert_sorted_events new deleted, updates)

_events_in_range :: ScoreTime -> ScoreTime -> Events.Events
    -> [Events.PosEvent]
_events_in_range start end events
    | start == end = maybe [] ((:[]) . (,) start)
        (Events.at start events)
    | otherwise = Events.ascending (Events.in_range start end events)

-- | Get the end of the last event of the block.
track_end :: (M m) => TrackId -> m ScoreTime
track_end track_id =
    Events.time_end . Track.track_events <$> get_track track_id

-- | Emit track updates for all tracks.  Use this when events have changed but
-- I don't know which ones, e.g. when loading a file or restoring a previous
-- state.
update_all_tracks :: (M m) => m ()
update_all_tracks = do
    st <- get
    let updates = map (flip Update.TrackUpdate Update.TrackAllEvents)
            (Map.keys (state_tracks st))
    mapM_ update updates

-- ** util

_modify_track track_id f = do
    track <- get_track track_id
    _set_track track_id (f track)

_modify_events :: (M m) => TrackId
    -> (Events.Events -> (Events.Events, [(ScoreTime, ScoreTime)]))
    -> m ()
_modify_events track_id f = do
    track <- get_track track_id
    let (new_events, updates) = f (Track.track_events track)
    _set_track track_id (track { Track.track_events = new_events })
    mapM_ update [Update.TrackUpdate track_id (Update.TrackEvents start end)
        | (start, end) <- updates]

_events_updates :: [Events.PosEvent] -> [(ScoreTime, ScoreTime)]
_events_updates [] = []
_events_updates evts =
    [(Events.event_min (head evts), Events.event_max (last evts))]

_set_track track_id track = modify $ \st -> st
    { state_tracks = Map.adjust (const track) track_id (state_tracks st) }

-- * ruler

get_ruler :: (M m) => RulerId -> m Ruler.Ruler
get_ruler ruler_id = get >>= lookup_id ruler_id . state_rulers

lookup_ruler :: (M m) => RulerId -> m (Maybe Ruler.Ruler)
lookup_ruler ruler_id = get >>= return . Map.lookup ruler_id . state_rulers

-- | Insert the given ruler with the given ID.
--
-- Throw if the RulerId already exists.
create_ruler :: (M m) => Id.Id -> Ruler.Ruler -> m RulerId
create_ruler id ruler
        -- no_ruler is global and assumed to always exist.
    | id == Id.unpack_id no_ruler = return no_ruler
    | otherwise = get >>= insert (Types.RulerId id) ruler state_rulers
        (\rulers st -> st { state_rulers = rulers })

-- | Destroy the ruler and remove it from all the blocks it's in.
destroy_ruler :: (M m) => RulerId -> m ()
destroy_ruler ruler_id = when (ruler_id /= no_ruler) $ do
    blocks <- blocks_with_ruler ruler_id
    forM_ blocks $ \(block_id, tracks) -> do
        let tracknums = map fst tracks
            setr i = if i `elem` tracknums then Block.set_rid no_ruler else id
            deruler (i, track) = Block.modify_id track (setr i)
        modify_block block_id $ \block -> block { Block.block_tracks =
            map deruler (Seq.enumerate (Block.block_tracks block)) }
    modify $ \st -> st { state_rulers = Map.delete ruler_id (state_rulers st) }

insert_marklist :: (M m) =>
    RulerId -> Int -> (Ruler.MarklistName, Ruler.Marklist) -> m ()
insert_marklist ruler_id i marklist = modify_ruler ruler_id $ \ruler ->
    ruler { Ruler.ruler_marklists =
        Seq.insert_at (Ruler.ruler_marklists ruler) i marklist }

remove_marklist :: (M m) => RulerId -> TrackNum -> m ()
remove_marklist ruler_id n = modify_ruler ruler_id $ \ruler -> ruler
    { Ruler.ruler_marklists = Seq.remove_at (Ruler.ruler_marklists ruler) n }

modify_ruler :: (M m) => RulerId -> (Ruler.Ruler -> Ruler.Ruler) -> m ()
modify_ruler ruler_id f = do
    ruler <- get_ruler ruler_id
    modify $ \st ->
        st { state_rulers = Map.insert ruler_id (f ruler) (state_rulers st) }

-- * search

-- | Get all views of a given block.
get_views_of :: (M m) => BlockId -> m (Map.Map ViewId Block.View)
get_views_of block_id = do
    views <- gets state_views
    return $ Map.filter ((==block_id) . Block.view_block) views

-- | Get all TrackIds of the given block.
track_ids_of :: (M m) => BlockId -> m [TrackId]
track_ids_of block_id = Block.block_track_ids <$> get_block block_id

-- | Find @track_id@ in all the blocks it exists in, and return the track info
-- for each tracknum at which @track_id@ lives.  Blocks with no matching tracks
-- won't be returned, so the return track lists will always be non-null.
blocks_with_track :: (M m) =>
    TrackId -> m [(BlockId, [(TrackNum, Block.TracklikeId)])]
blocks_with_track track_id =
    find_tracks_m ((== Just track_id) . Block.track_id_of)

-- | Just like 'blocks_with_track' except for ruler_id.
blocks_with_ruler :: (M m) =>
    RulerId -> m [(BlockId, [(TrackNum, Block.TracklikeId)])]
blocks_with_ruler ruler_id =
    find_tracks_m ((== Just ruler_id) . Block.ruler_id_of)

find_tracks_m :: (M m) => (Block.TracklikeId -> Bool)
    -> m [(BlockId, [(TrackNum, Block.TracklikeId)])]
find_tracks_m f = gets (find_tracks f . state_blocks)

find_tracks :: (Block.TracklikeId -> Bool) -> Map.Map BlockId Block.Block
    -> [(BlockId, [(TrackNum, Block.TracklikeId)])]
find_tracks f blocks = do
    (bid, b) <- Map.assocs blocks
    let tracks = get_tracks b
    guard (not (null tracks))
    return (bid, tracks)
    where
    all_tracks block = Seq.enumerate (Block.block_tracks block)
    get_tracks block =
        [ (tracknum, Block.tracklike_id track)
        | (tracknum, track) <- all_tracks block, f (Block.tracklike_id track)]

-- * util

-- | Lookup @map!key@, throwing if it doesn't exist.
lookup_id :: (Ord k, Show k, M m) => k -> Map.Map k a -> m a
lookup_id key map = case Map.lookup key map of
    Nothing -> throw $ "State.lookup: unknown " ++ show key
    Just val -> return val

-- | Insert @val@ at @key@ in @get_map state@, throwing if it already exists.
-- Put the map back into @state@ by applying @set_map new_map state@ to it.
insert :: (M m, Ord k, Show k) =>
    k -> a -> (t -> Map.Map k a) -> (Map.Map k a -> t -> State) -> t -> m k
insert key val get_map set_map state = do
    when (key `Map.member` get_map state) $
        throw $ show key ++ " already exists"
    put (set_map (Map.insert key val (get_map state)) state)
    return key

-- | Modify the @i@th element of @xs@ by applying @f@ to it.
modify_at :: (M m) => String -> [a] -> Int -> (a -> a) -> m [a]
modify_at msg xs i f = case post of
    [] -> throw $ msg ++ ": can't replace index " ++ show i
        ++ " of list with length " ++ show (length xs)
    (elt:rest) -> return (pre ++ f elt : rest)
    where (pre, post) = splitAt i xs
