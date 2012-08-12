{-# LANGUAGE ViewPatterns #-}
{- | Cmds to edit a pitch track, which is a special kind of control track.

    This module creates the pitches that are later parsed by Derive.Control.
-}
module Cmd.PitchTrack where
import qualified Data.List as List

import Util.Control
import qualified Util.Seq as Seq
import qualified Util.Then as Then

import qualified Ui.Event as Event
import qualified Ui.Key as Key
import qualified Ui.State as State

import qualified Cmd.Cmd as Cmd
import qualified Cmd.EditUtil as EditUtil
import qualified Cmd.InputNote as InputNote
import qualified Cmd.ModifyEvents as ModifyEvents
import qualified Cmd.Msg as Msg
import qualified Cmd.Perf as Perf
import qualified Cmd.Selection as Selection

import qualified Derive.ParseBs as ParseBs
import qualified Derive.Scale as Scale
import qualified Derive.TrackInfo as TrackInfo
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch
import qualified App.Config as Config


-- * entry

cmd_raw_edit :: Cmd.Cmd
cmd_raw_edit = Cmd.suppress_history Cmd.RawEdit "pitch track raw edit"
    . EditUtil.raw_edit True

cmd_val_edit :: Cmd.Cmd
cmd_val_edit msg = Cmd.suppress_history Cmd.ValEdit "pitch track val edit" $ do
    EditUtil.fallthrough msg
    case msg of
        Msg.InputNote (InputNote.NoteOn _ key _) -> do
            pos <- Selection.get_insert_pos
            note <- EditUtil.parse_key key
            val_edit_at pos note
            whenM (Cmd.gets (Cmd.state_advance . Cmd.state_edit))
                Selection.advance
        Msg.InputNote (InputNote.PitchChange _ key) -> do
            pos <- Selection.get_insert_pos
            note <- EditUtil.parse_key key
            val_edit_at pos note
        (Msg.key_down -> Just (Key.Char '\'')) -> EditUtil.soft_insert "'"
        (Msg.key_down -> Just Key.Backspace) -> EditUtil.remove_event True
        _ -> Cmd.abort
    return Cmd.Done

cmd_method_edit :: Cmd.Cmd
cmd_method_edit msg = Cmd.suppress_history Cmd.MethodEdit
        "pitch track method edit" $ do
    EditUtil.fallthrough msg
    case msg of
        (EditUtil.method_key -> Just key) -> do
            pos <- Selection.get_insert_pos
            method_edit_at pos key
        _ -> Cmd.abort
    return Cmd.Done

val_edit_at :: (Cmd.M m) => State.Pos -> Pitch.Note -> m ()
val_edit_at pos note = modify_event_at pos $ \(method, _) ->
    ((Just method, Just (Pitch.note_text note)), False)

method_edit_at :: (Cmd.M m) => State.Pos -> Key.Key -> m ()
method_edit_at pos key = modify_event_at pos $ \(method, val) ->
    ((EditUtil.modify_text_key key method, Just val), False)

-- | Record the last note entered.  Should be called by 'with_note'.
cmd_record_note_status :: Cmd.Cmd
cmd_record_note_status msg = do
    case msg of
        Msg.InputNote (InputNote.NoteOn _ key _) -> do
            note <- EditUtil.parse_key key
            Cmd.set_status Config.status_note (Just (Pitch.note_text note))
        _ -> return ()
    return Cmd.Continue

-- * implementation

modify_event_at :: (Cmd.M m) => State.Pos
    -> ((String, String) -> ((Maybe String, Maybe String), Bool))
    -> m ()
modify_event_at pos f = EditUtil.modify_event_at pos True True
    (first unparse . f . parse. fromMaybe "")

-- | Modify event text.  This is not used within this module but is exported
-- for others as a more general variant of 'modify_event_at'.
modify :: ((String, String) -> (String, String)) -> Event.Event -> Event.Event
modify f event = Event.set_string text event
    where
    text = maybe "" id (process (Event.event_string event))
    process = unparse . justify . f . parse
    justify (a, b) = (Just a, Just b)

-- | Try to figure out the call part of the expression and split it from the
-- rest.
--
-- Like 'Derive.ControlTrack.parse', this is merely a heuristic.  It tries to
-- get the simple case right, but may be fooled by complex expressions.
parse :: String -> (String, String)
parse s
    | '(' `notElem` s =
        if " " `List.isSuffixOf` s then (pre, "") else ("", s)
    | otherwise = (pre, drop 1 post)
    where (pre, post) = break (==' ') s

-- | Put the parsed halves back together.  Return Nothing if the event should
-- be deleted.
unparse :: (Maybe String, Maybe String) -> Maybe String
unparse (method, val) = case (pre, post) of
        ("", "") -> Nothing
        -- If the method is gone, the note no longer needs its parens.
        -- Any args after the paren belonged to the method, and can go too.
        ("", '(':rest) -> Just (strip_right_paren rest)
        ("", _:_) -> Just post
        (_:_, "") -> Just $ pre ++ " "
        (_:_, '(':_) -> Just $ pre ++ ' ' : post
        -- And add parens if the method is new.
        (_:_, _:_) -> Just $ pre ++ ' ' : '(' : post ++ ")"
    where
    strip_right_paren text
        | ')' `elem` text = reverse $ drop 1 $ dropWhile (/=')') $ reverse text
        | otherwise = text
    pre = fromMaybe "" method
    post = fromMaybe "" val

-- | Try to figure out where the pitch call part is in event text and modify
-- that with the given function.  The function can signal failure by returning
-- Left.
--
-- This is a bit of a heuristic because by design a pitch is a normal call and
-- there's no syntactic way to tell where the pitches are in an expression.  If
-- the text is a call with a val call as its first argument, that's considered
-- the pitch call.  Otherwise, if the text is just a call, that's the pitch
-- call.  Otherwise the text is unchanged.
modify_note :: (Pitch.Note -> Either String Pitch.Note) -> String
    -> Either String String
modify_note f = modify_expr $ \note_str -> case note_str of
    '(':rest ->
        let (note, post) = break (`elem` " )") rest
        in ('(':) . (++post) . Pitch.note_text <$> f (Pitch.Note note)
    _ -> Pitch.note_text <$> f (Pitch.Note note_str)

-- | Modify the note expression, e.g. in @i (a b c)@ it would be @(a b c)@,
-- including the parens.
modify_expr :: (String -> Either String String) -> String
    -> Either String String
modify_expr f text = case ParseBs.parse_expr (ParseBs.from_string text) of
    Left _ -> Right text
    Right expr -> case expr of
        [TrackLang.Call sym (TrackLang.ValCall _ : _)]
            | sym /= TrackLang.c_equal ->
                let (pre, within) = break (=='(') text
                    (note, post) = Then.break1 (==')') within
                in (\n -> pre ++ n ++ post) <$> f note
        [TrackLang.Call sym _]
            | sym /= TrackLang.c_equal ->
                let (pre, post) = break (==' ') text
                in (++post) <$> f pre
        _ -> Right text


-- * edits

-- | Function that modifies the pitch of an event on a pitch track, or a Left
-- if the operation failed.
type ModifyPitch =
    Scale.Scale -> Maybe Pitch.Key -> Pitch.Note -> Either String Pitch.Note

transpose_selection :: (Cmd.M m) => Pitch.Octave -> Pitch.Transpose -> m ()
transpose_selection oct steps = pitches (transpose oct steps)

transpose :: Pitch.Octave -> Pitch.Transpose -> ModifyPitch
transpose octaves steps scale maybe_key note =
    case Scale.scale_transpose scale maybe_key octaves steps note of
        -- Leave non-pitches alone.
        Left Scale.UnparseableNote -> Right note
        Left err -> Left (show err)
        Right note2 -> Right note2

cycle_enharmonics :: ModifyPitch
cycle_enharmonics scale maybe_key note = show_err $ do
    enharmonics <- Scale.scale_enharmonics scale maybe_key note
    return $ fromMaybe note (Seq.head enharmonics)

pitches :: (Cmd.M m) => ModifyPitch -> m ()
pitches = ModifyEvents.tracks_sorted . pitch_tracks

-- | Apply a ModifyPitch to only pitch tracks.
pitch_tracks :: (Cmd.M m) => ModifyPitch -> ModifyEvents.Track m
pitch_tracks f =
    ModifyEvents.tracks_named TrackInfo.is_pitch_track $
        \block_id track_id events -> do
    scale_id <- Perf.get_scale_id block_id (Just track_id)
    scale <- Cmd.get_scale "PitchTrack.pitches" scale_id
    maybe_key <- Perf.get_key block_id (Just track_id)
    let modify = modify_note (f scale maybe_key)
    ModifyEvents.failable_texts modify block_id track_id events

show_err :: Either Scale.ScaleError a -> Either String a
show_err (Right x) = Right x
show_err (Left err) = Left (show err)
