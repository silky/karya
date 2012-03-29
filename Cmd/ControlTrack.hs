{-# LANGUAGE ViewPatterns #-}
module Cmd.ControlTrack where
import qualified Data.List as List
import qualified Data.Maybe as Maybe

import Util.Control
import qualified Ui.State as State
import qualified Cmd.Cmd as Cmd
import qualified Cmd.EditUtil as EditUtil
import qualified Cmd.Selection as Selection

import qualified Derive.TrackLang as TrackLang
import qualified Perform.Signal as Signal


cmd_raw_edit :: Cmd.Cmd
cmd_raw_edit = EditUtil.raw_edit True

cmd_val_edit :: Cmd.Cmd
cmd_val_edit msg = do
    EditUtil.fallthrough msg
    case msg of
        (EditUtil.val_key -> Just key) -> modify_event $ \(method, val) ->
            case EditUtil.modify_text_key key val of
                Nothing -> ((Nothing, Nothing), null val)
                Just new_val -> ((Just method, Just new_val), False)
        _ -> Cmd.abort
    return Cmd.Done

cmd_method_edit :: Cmd.Cmd
cmd_method_edit msg = do
    EditUtil.fallthrough msg
    case msg of
        (EditUtil.method_key -> Just key) -> modify_event $ \(method, val) ->
            ((EditUtil.modify_text_key key method, Just val), False)
        _ -> Cmd.abort
    return Cmd.Done


-- * implementation

val_edit_at :: (Cmd.M m) => State.Pos -> Signal.Y -> m ()
val_edit_at pos val = modify_event_at pos $ \(method, _) ->
    ((Just method, Just (TrackLang.show_val val)), False)

modify_event :: (Cmd.M m) =>
    ((String, String) -> ((Maybe String, Maybe String), Bool)) -> m ()
modify_event f = do
    pos <- Selection.get_insert_pos
    modify_event_at pos f

modify_event_at :: (Cmd.M m) => State.Pos
    -> ((String, String) -> ((Maybe String, Maybe String), Bool)) -> m ()
modify_event_at pos f = EditUtil.modify_event_at pos True True
    (first unparse . f . parse . Maybe.fromMaybe "")

-- | Try to figure out the call part of the expression and split it from the
-- rest.
--
-- I don't use Derive.TrackLang.parse because this is likely to be dealing with
-- incomplete strings that don't parse at all.
--
-- I use a trailing space to tell the difference between a method and a val.
parse :: String -> (String, String)
parse s
    | null post = if " " `List.isSuffixOf` pre then (pre, "") else ("", pre)
    | otherwise = (pre, tail post)
    where (pre, post) = break (==' ') s

unparse :: (Maybe String, Maybe String) -> Maybe String
unparse (method, val) = case (pre, post) of
        ("", "") -> Nothing
        ("", _:_) -> Just post
        -- Disambiguate a bare method with a trailing space.
        _ -> Just (pre ++ ' ' : post)
    where
    pre = Maybe.fromMaybe "" method
    post = Maybe.fromMaybe "" val
