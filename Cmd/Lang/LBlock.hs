{-# LANGUAGE NoMonomorphismRestriction #-}
-- | Block level cmds.
module Cmd.Lang.LBlock where
import qualified Control.Monad.Trans as Trans
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO

import Util.Control
import qualified Ui.Event as Event
import qualified Ui.Id as Id
import qualified Ui.State as State
import qualified Ui.Types as Types

import qualified Cmd.CallDoc as CallDoc
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.ModifyEvents as ModifyEvents
import qualified Cmd.PitchTrack as PitchTrack
import qualified Cmd.Selection as Selection

import qualified Derive.Scale as Scale
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.Twelve as Twelve

import Types


-- * doc

doc :: Cmd.CmdL Text.Text
doc = CallDoc.doc_text <$> track_doc

html_doc :: Cmd.CmdL ()
html_doc = do
    doc <- track_doc
    Trans.liftIO $ Text.IO.writeFile "build/derive_doc.html"
        (CallDoc.doc_html doc)

track_doc :: Cmd.CmdL CallDoc.Document
track_doc = do
    (block_id, _, track_id, _) <- Selection.get_insert
    CallDoc.track block_id track_id

-- * block call

-- | Rename a block and all occurrances in the current block.
--
-- It doesn't update TrackIds so they may still be named under their old block,
-- but track id names aren't supposed to carry meaning anyway.
rename :: BlockId -> BlockId -> Cmd.CmdL ()
rename = Create.rename_block

-- | Rename block calls in a single block.
replace :: BlockId -> BlockId -> Cmd.CmdL ()
replace from to = do
    block_id <- Cmd.get_focused_block
    ModifyEvents.block_tracks block_id $ ModifyEvents.track_text $
        replace_block_call from to

replace_block_call :: BlockId -> BlockId -> String -> String
replace_block_call from to text
    | text == Id.ident_name from = Id.ident_name to
    | text == Id.ident_string from = Id.ident_string to
    | otherwise = text

-- * create

-- | If the events under the cursor are a block calls, create blocks that don't
-- already exist.  Optionally use a model block.
block_for_event :: Maybe BlockId -> Cmd.CmdL ()
block_for_event model = mapM_ make =<< Selection.events
    where
    make (_, _, events) = mapM_ (make_named model . Event.event_string) events

make_named :: Maybe BlockId -> String -> Cmd.CmdL ()
make_named template name = whenM (can_create name) $ case template of
    Nothing -> do
        template_id <- Cmd.get_focused_block
        Create.block_from_template False template_id
    Just template_id -> Create.block_from_template True template_id

can_create :: (State.M m) => String -> m Bool
can_create "" = return False
can_create name = do
    ns <- State.get_namespace
    case Types.BlockId <$> Id.make ns name of
        Just block_id -> not . Map.member block_id
            <$> State.gets State.state_blocks
        Nothing -> return False

-- * pitch

simplify_block :: BlockId -> Cmd.CmdL ()
simplify_block block_id =
    ModifyEvents.block_tracks block_id simplify_enharmonics

-- | This only works for Twelve at the moment.  For it to work for any scale
-- I need a way to parse to Theory.Pitch.  Can't use scale_enharmonics because
-- I don't want to mess with ones that are already simple.
simplify_enharmonics :: (Cmd.M m) => ModifyEvents.Track m
simplify_enharmonics = PitchTrack.pitch_tracks $ \scale key note ->
    case Twelve.read_pitch note of
        Left _ -> Right note
        Right pitch
            | abs (Theory.pitch_accidentals pitch) < 2 -> Right note
            | otherwise -> case Scale.scale_enharmonics scale key note of
                Right (simpler : _) -> Right simpler
                _ -> Right note
