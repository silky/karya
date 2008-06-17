{-# OPTIONS_GHC -XDeriveDataTypeable #-}
module Ui.Block where
import qualified Foreign

import qualified Data.Generics as Generics
import qualified Data.Map as Map

import qualified Util.Seq as Seq

import Ui.Types
import qualified Ui.Color as Color
import qualified Ui.Track as Track
import qualified Ui.Ruler as Ruler

-- These would have to be hierarchical names, so if you load
-- another song you don't get ID collisions.

-- | Reference to a Block.  Use this to look up Blocks in the State.
-- Even though the constructor is exported, you should only create them
-- through the 'State.StateT' interface.
newtype BlockId = BlockId String
    deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)
-- | Reference to a View, as per 'BlockId'.
newtype ViewId = ViewId String
    deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)
-- | Reference to a schema.  Declared here instead of Deriver.Schema to avoid
-- a circular import.
newtype SchemaId = SchemaId String
    deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

-- * block model

data Block = Block {
    block_title :: String
    , block_config :: Config
    , block_ruler_track :: TracklikeId
    -- The Width here is the default if a new View is created from this Block.
    , block_tracks :: [(TracklikeId, Width)]
    , block_schema :: SchemaId
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

block title config ruler tracks schema_id =
    Block title config ruler tracks schema_id

data Config = Config {
    config_selection_colors :: [Color]
    , config_bg_color :: Color
    , config_track_box_color :: Color
    , config_sb_box_color :: Color
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

-- Tracks may have a Ruler overlay
data TracklikeId =
    TId Track.TrackId Ruler.RulerId
    | RId Ruler.RulerId
    | DId Divider
    deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

data Tracklike =
    T Track.Track Ruler.Ruler
    | R Ruler.Ruler
    | D Divider
    deriving (Show)

-- | A divider separating tracks.
-- Declared here in Block since it's so trivial.
data Divider = Divider Color
    deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

-- * block view

data View = View {
    -- | view_block should never change.
    -- TODO Views that point to a BlockId not in state_blocks should be
    -- destroyed.
    view_block :: BlockId
    , view_rect :: Rect
    , view_config :: ViewConfig
    , view_status :: Map.Map String String

    -- | Scroll and zoom
    , view_track_scroll :: Width
    , view_zoom :: Zoom

    , view_selections :: Map.Map SelNum Selection
    -- | These are the per-view settings for the tracks.  There should be one
    -- corresponding to each TracklikeId in the Block.  The StateT operations
    -- should maintain this invariant.
    , view_tracks :: [TrackView]
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

show_status :: View -> String
show_status = Seq.join " | " . map (\(k, v) -> k ++ ": " ++ v)
    . Map.assocs . view_status

-- | Return how much track is in view.
visible_view_area :: View -> TrackPos
visible_view_area view = pixels_to_track_pos (view_zoom view) height
    where
    ViewConfig { vconfig_block_title_height = blockth
        , vconfig_track_title_height = trackth
        , vconfig_sb_size = sb
        , vconfig_status_size = status } = view_config view
    -- TODO
    -- This relies on knowing how the widgets are layed out.  It would be nicer
    -- for UpdateViewResize to explicitly give the pixels in the track view,
    -- and I'd need to make sure a haskell-initiated resize gets reported in an
    -- UpdateViewResize too.
    height = snd (rect_size (view_rect view)) - blockth - trackth - sb - status

pixels_to_track_pos :: Zoom -> Int -> TrackPos
pixels_to_track_pos zoom pixels = floor $ fromIntegral pixels / zoom_factor zoom

-- | Construct a View, using default values for most of its fields.
-- Don't construct views using View directly since State.create_view overwrites
-- view_tracks, and maybe more in the future.
view block_id rect config = View block_id rect config Map.empty
    0 default_zoom Map.empty []

data TrackView = TrackView {
    track_view_width :: Width
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

data Rect = Rect {
    rect_pos :: (Int, Int)
    , rect_size :: (Int, Int)
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)
rect_right rect = fst (rect_pos rect) + fst (rect_size rect)
rect_bottom rect = snd (rect_pos rect) + snd (rect_size rect)

-- | The defaults for newly created blocks and the trackviews automatically
-- created.
data ViewConfig = ViewConfig
    { vconfig_zoom_speed :: Double
    , vconfig_block_title_height :: Int
    , vconfig_track_title_height :: Int
    , vconfig_sb_size :: Int
    , vconfig_ruler_size :: Int
    , vconfig_status_size :: Int
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

-- | View zoom and time scroll offset.
data Zoom = Zoom {
    zoom_offset :: TrackPos
    , zoom_factor :: Double
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)
default_zoom = Zoom (TrackPos 0) 1

-- TODO: remove color and put it in BlockC.SelectionC, which gets its color
-- from a BlockConfig list
data Selection = Selection
    { sel_start_track :: TrackNum
    , sel_start_pos :: TrackPos
    , sel_tracks :: TrackNum
    , sel_duration :: TrackPos
    } deriving (Eq, Ord, Show, Read, Generics.Data, Generics.Typeable)

selection tracknum start tracks dur = Just (Selection tracknum start tracks dur)

-- | A point is a selection with no duration.
point_selection :: TrackNum -> TrackPos -> Maybe Selection
point_selection tracknum pos = Just (Selection tracknum pos 1 (TrackPos 0))

-- | Index into a block's tracks.
type TrackNum = Int
-- | Width of a track in pixels.
type Width = Int
-- | Index into the the selection list.
type SelNum = Int
