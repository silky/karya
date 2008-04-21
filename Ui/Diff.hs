module Ui.Diff where
import Control.Monad
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.Writer as Writer
import qualified Data.Map as Map
import qualified Data.List as List

import qualified Ui.Block as Block

import qualified Ui.Update as Update
import qualified Ui.State as State

type DiffError = String

-- | Emit a list of the necessary 'Update's to turn @st1@ into @st2@.
diff :: State.State -> State.State -> Either DiffError [Update.Update]
diff st1 st2 = Identity.runIdentity . Error.runErrorT . Writer.execWriterT $ do
    -- Only emit updates for blocks that are actually in a displayed view.
    let visible_ids = (List.nub . map Block.view_block . Map.elems)
            (State.state_views st2)
        visible_blocks = Map.filterWithKey (\k _v -> k `elem` visible_ids)
            (State.state_blocks st2)
    mapM_ (uncurry3 diff_block)
        (zip_maps (State.state_blocks st1) visible_blocks)

    -- The block updates may delete or insert tracks.  View updates that use
    -- TrackNums will refer to the st2 TrackNum, so diff_views goes after
    -- diff_block.
    diff_views st1 st2 (State.state_views st1) (State.state_views st2)

-- ** view

diff_views st1 st2 views1 views2 = do
    change $ map (flip Update.ViewUpdate Update.DestroyView) $
        Map.keys (Map.difference views1 views2)
    change $ map (flip Update.ViewUpdate Update.CreateView) $
        Map.keys (Map.difference views2 views1)
    mapM_ (uncurry3 (diff_view st1 st2)) (zip_maps views1 views2)

diff_view st1 st2 view_id view1 view2 = do
    let view_update = Update.ViewUpdate view_id
    when (Block.view_block view1 /= Block.view_block view2) $
        throw $ show view_id ++ " changed from "
            ++ show (Block.view_block view1) ++ " to "
            ++ show (Block.view_block view2)
    when (Block.view_rect view1 /= Block.view_rect view2) $
        change [view_update $ Update.ViewSize (Block.view_rect view2)]
    when (Block.view_config view1 /= Block.view_config view2) $
        change [view_update $ Update.ViewConfig (Block.view_config view2)]

    -- The track view info (widths) is in the View, while the track data itself
    -- (Tracklikes) is in the Block.  Since one track may have been added or
    -- deleted while another's width was changed, I have to run 'edit_distance'
    -- here with the Blocks' Tracklikes to pair up the the same Tracklikes
    -- before comparing their widths.  'i' will be the TrackNum index for the
    -- tracks pre insertion/deletion, which is correct since the view is diffed
    -- and its Updates run before the Block updates.  This also means it
    -- actually matters that updates are run in order.  This is a lot of
    -- subtlety just to detect width changes!
    --
    -- 'edit_distance' is run again on the Blocks to actually delete or insert
    -- tracks.

    tracks1 <- track_info view_id view1 st1
    tracks2 <- track_info view_id view2 st2
    let pairs = indexed_pairs (\a b -> fst a == fst b) tracks1 tracks2
    forM_ pairs $ \(i2, track1, track2) -> case (track1, track2) of
        (Just (_, tview1), Just (_, tview2)) ->
            diff_track_view view_id i2 tview1 tview2
        _ -> return ()

    mapM_ (uncurry3 (diff_selection view_update))
        (pair_maps (Block.view_selections view1) (Block.view_selections view2))

diff_selection view_update selnum sel1 sel2 = when (sel1 /= sel2) $
    change [view_update $ Update.SetSelection selnum sel2]

diff_track_view view_id tracknum tview1 tview2 = do
    let width = Block.track_view_width
    when (width tview1 /= width tview2) $
        change [Update.ViewUpdate view_id
            (Update.SetTrackWidth tracknum (width tview2))]

-- | Pair the Tracklikes from the Block with the TrackViews from the View.
track_info view_id view st =
    case Map.lookup block_id (State.state_blocks st) of
        Nothing -> throw $ show block_id ++ " of " ++ show view_id
            ++ " has no referent"
        Just block -> return $ zip
            (map fst (Block.block_tracks block)) (Block.view_tracks view)
    where block_id = Block.view_block view


-- ** block

diff_block block_id block1 block2 = do
    let block_update = Update.BlockUpdate block_id
    when (Block.block_title block1 /= Block.block_title block2) $
        change [block_update $ Update.BlockTitle (Block.block_title block2)]
    when (Block.block_config block1 /= Block.block_config block2) $
        change [block_update $ Update.BlockConfig (Block.block_config block2)]

    when (Block.block_ruler_track block1 /= Block.block_ruler_track block2) $
        change [block_update $ Update.InsertTrack Block.ruler_tracknum
            (Block.block_ruler_track block2) 0]

    let pairs = indexed_pairs (\a b -> fst a == fst b)
            (Block.block_tracks block1) (Block.block_tracks block2)
    forM_ pairs $ \(i2, track1, track2) -> case (track1, track2) of
        (Just _, Nothing) -> change [block_update $ Update.RemoveTrack i2]
        (Nothing, Just (track, width)) ->
            change [block_update $ Update.InsertTrack i2 track width]
        _ -> return ()

throw = Error.throwError
change :: Monad m => [Update.Update] -> Writer.WriterT [Update.Update] m ()
change = Writer.tell

-- * util

uncurry3 f (a, b, c) = f a b c
-- | Given two maps, pair up the elements in @map1@ with a samed-keyed element
-- in @map2@, if there is one.  Elements that are only in @map1@ or @map2@ will
-- not be included in the output.
zip_maps :: (Ord k) => Map.Map k v1 -> Map.Map k v2 -> [(k, v1, v2)]
zip_maps map1 map2 =
    [(k, v1, v2) | (k, v1) <- Map.assocs map1, v2 <- Map.lookup k map2]

pair_maps :: (Ord k) => Map.Map k v -> Map.Map k v -> [(k, Maybe v, Maybe v)]
pair_maps map1 map2 = map (\k -> (k, Map.lookup k map1, Map.lookup k map2))
    (Map.keys (Map.union map1 map2))

-- | Pair @a@ elements up with @b@ elements.  If they are equal according to
-- @eq@, they'll both be Just in the result.  If an @a@ is deleted going from
-- @a@ to @b@, it will be Nothing, and vice versa for @b@.
--
-- Kind of like an edit distance.
pair_lists :: (a -> b -> Bool) -> [a] -> [b] -> [(Maybe a, Maybe b)]
pair_lists _ [] ys = [(Nothing, Just y) | y <- ys]
pair_lists _ xs [] = [(Just x, Nothing) | x <- xs]
pair_lists eq (x:xs) (y:ys)
    | x `eq` y = (Just x, Just y) : pair_lists eq xs ys
    | any (eq x) ys = (Nothing, Just y) : pair_lists eq (x:xs) ys
    | otherwise = (Just x, Nothing) : pair_lists eq xs (y:ys)

-- | This is just like 'pair_lists', except that the index of each pair in
-- the /right/ list is included.  In other words, given @(i, Nothing, Just y)@,
-- @i@ is the position of @y@ in the @b@ list.  Given @(i, Just x, Nothing)@,
-- @i@ is where @x@ was deleted from the @b@ list.
indexed_pairs :: (a -> b -> Bool) -> [a] -> [b] -> [(Int, Maybe a, Maybe b)]
indexed_pairs eq xs ys = zip3 (indexed pairs) (map fst pairs) (map snd pairs)
    where pairs = pair_lists eq xs ys
indexed pairs = scanl f 0 pairs
    where
    f i (_, Nothing) = i
    f i _ = i+1
