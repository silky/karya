{- | Functions to save and restore state to and from files.
-}
module Cmd.Save where
import qualified Control.Monad.Trans as Trans
import qualified System.FilePath as FilePath

import qualified Util.Log as Log

import qualified Ui.State as State

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Edit as Edit
import qualified Cmd.Serialize as Serialize


get_save_file :: (Monad m) => Cmd.CmdT m FilePath
get_save_file = do
    dir <- fmap State.state_project_dir State.get
    ns <- State.get_project
    return $ FilePath.combine dir (map sanitize ns ++ ".state")
    where sanitize c = if FilePath.isPathSeparator c then '_' else c

cmd_save :: (Trans.MonadIO m) => FilePath -> Cmd.CmdT m ()
cmd_save fname = do
    ui_state <- State.get
    save <- Trans.liftIO $ Serialize.save_state ui_state
    Log.notice $ "write state to " ++ show fname
    -- For the moment, also serialize to plain text, since that's easier to
    -- read and edit.
    Trans.liftIO $ Serialize.serialize_text (fname ++ ".text") save
    Trans.liftIO $ Serialize.serialize fname save

cmd_load :: (Trans.MonadIO m) => FilePath -> Cmd.CmdT m ()
cmd_load fname = do
    Trans.liftIO $ Log.notice $ "load state from " ++ show fname
    try_state <- Trans.liftIO $ Serialize.unserialize fname
    state <- case try_state of
        Left exc -> Cmd.throw $
            "error unserializing " ++ show fname ++ ": " ++ show exc
        Right st -> return st
    Trans.liftIO $ Log.notice $ "state loaded from " ++ show fname

    State.modify (const (Serialize.save_ui_state state))
    Edit.initialize_state
    Edit.clear_history
