-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Functions to save and restore state to and from files.

    The naming convention is that @load@ and @save@ functions either load
    the given file, replace the state with it, and set the SaveFile, or save
    the current state and set the SaveFile.  @read@ and @write@ functions
    are lower level and either read the file and return the state, or write the
    given state, without messing with the SaveFile.
-}
module Cmd.Save (
    -- * quit
    soft_quit, hard_quit
    -- * universal
    , save, load, load_force, read, read_, load_template
    , infer_save_type
    -- * state
    , save_state, save_state_as, load_state
    , read_state, read_state_, write_state
    , write_current_state
    -- ** path
    , get_state_path, state_path_for_repo, infer_state_path
    -- * git
    , save_git, save_git_as, load_git, revert
    , get_git_path
    -- * config
    , save_allocations, load_allocations
    -- * misc
    , save_views
) where
import           Prelude hiding (read)
import qualified Control.Exception as Exception
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Time as Time

import qualified System.Directory as Directory
import qualified System.FilePath as FilePath
import           System.FilePath ((</>))

import qualified Util.File as File
import qualified Util.Git as Git
import qualified Util.Lists as Lists
import qualified Util.Log as Log
import qualified Util.Serialize as Serialize
import qualified Util.Texts as Texts
import qualified Util.Thread as Thread

import qualified App.Config as Config
import qualified App.Path as Path
import qualified Cmd.Clip as Clip
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Play as Play
import qualified Cmd.SaveGit as SaveGit
import qualified Cmd.SaveGitT as SaveGitT
import qualified Cmd.Serialize

import qualified Ui.Id as Id
import qualified Ui.Transform as Transform
import qualified Ui.Ui as Ui
import qualified Ui.UiConfig as UiConfig

import           Global


-- * quit

-- | Warn and abort if there is unsaved data, otherwise quit.
soft_quit :: Cmd.CmdT IO Cmd.Status
soft_quit = check_unsaved_data >>= \case
    Just msg -> do
        Log.warn $ "refusing to quit: " <> msg
        return Cmd.Done
    Nothing -> hard_quit

check_unsaved_data :: Cmd.M m => m (Maybe Text)
check_unsaved_data = Cmd.gets Cmd.state_saved >>= \case
    Cmd.Saved Cmd.UnsavedChanges _ -> return $ Just "unsaved changes"
    Cmd.Saved _ True ->
        return $ Just "repl editor is open, possibly with unsaved changes"
    _ -> return Nothing

-- | Quit.  If there is unsaved data, it will be discarded!
hard_quit :: Cmd.CmdT IO Cmd.Status
hard_quit = Play.cmd_stop >> return Cmd.Quit

-- * universal

-- | Save to the current 'Cmd.state_save_file', or create a new git repo if
-- there is none.
save :: Cmd.CmdT IO ()
save = Cmd.gets Cmd.state_save_file >>= \case
    Nothing -> save_git
    -- Try to override Cmd.Writable on an explicit save.  If it's still
    -- read only, this should throw an exception.
    Just (_, Cmd.SaveRepo repo) -> save_git_as (Path.to_path repo)
    Just (_, Cmd.SaveState fn) -> save_state_as (Path.to_path fn)

-- | Like 'read', but replace the current state and set 'Cmd.state_save_file'.
load :: FilePath -> Cmd.CmdT IO ()
load path = check_unsaved_data >>= \case
    Just msg -> Log.warn $ "refusing to load a new score: " <> msg
    Nothing -> load_force path

load_force :: FilePath -> Cmd.CmdT IO ()
load_force path = do
    (state, save_file) <- read path
    set_loaded_state save_file state

-- | Try to guess whether the given path is a git save or state save.  If it's
-- a directory, look inside for a .git or .state save.
read :: FilePath -> Cmd.CmdT IO (Ui.State, StateSaveFile)
read path = do
    path <- expand_filename path
    save <- Cmd.require_right ("read: "<>) =<< liftIO (infer_save_type path)
    case save of
        Cmd.SaveRepo repo -> read_git (Path.to_path repo) Nothing
        Cmd.SaveState fn -> read_state (Path.to_path fn)

-- | Low level 'read'.
read_ :: FilePath -> IO (Either Text Ui.State)
read_ path = infer_save_type path >>= \case
    Left err -> return $ Left $ "read " <> showt path <> ": " <> err
    Right save -> case save of
        Cmd.SaveState fname -> first pretty <$> read_state_ (Path.to_path fname)
        Cmd.SaveRepo repo ->
            fmap extract <$> read_git_ (Path.to_path repo) Nothing
            where extract (state, _, _) = state

-- | Like 'load', but don't set SaveFile, so you can't overwrite the loaded
-- file when you save.
load_template :: FilePath -> Cmd.CmdT IO ()
load_template fn = do
    (state, _) <- read fn
    set_loaded_state Nothing state
    now <- liftIO $ Time.getCurrentTime
    Ui.modify_config $ UiConfig.meta#UiConfig.creation #= now

-- | Given a path, which is either a file or a directory, try to figure out
-- what to load.  Saves can be either a plain saved state, or a directory
-- containing either a git repo @save.git@, or a state @save.state@.  If
-- both are present, the git repo is preferred.
infer_save_type :: FilePath -> IO (Either Text Cmd.SaveFile)
infer_save_type path = fmap prepend $ condM
    [ (return $ SaveGit.is_git path,
        Right . Cmd.SaveRepo <$> Path.canonical path)
    , (is_dir path, condM
        [ (is_dir git_fn, Right . Cmd.SaveRepo <$> Path.canonical git_fn)
        , (is_file state_fn, Right . Cmd.SaveState <$> Path.canonical state_fn)
        ] $ return $ Left $ "directory contains neither " <> txt git_fn
            <> " nor " <> txt state_fn)
    , (is_file path, Right . Cmd.SaveState <$> Path.canonical path)
    ] $ return $ Left "file not found"
    where
    prepend (Left err) = Left $ txt path <> ": " <> err
    prepend (Right val) = Right val
    git_fn = path </> default_git
    state_fn = path </> default_state
    is_dir = Directory.doesDirectoryExist
    is_file = Directory.doesFileExist

-- | Like guard cases but with monadic conditions.
condM :: Monad m => [(m Bool, m a)] -> m a -> m a
condM [] consequent = consequent
condM ((condition, result) : rest) consequent =
    ifM condition result (condM rest consequent)

-- * expand path

-- | Expand `-delimited macros to make a filepath.
expand_filename :: FilePath -> Cmd.CmdT IO FilePath
expand_filename = fmap untxt . Texts.mapDelimitedM False '`' expand . txt
    where
    expand text = case lookup text filename_macros of
        Just get -> get
        Nothing -> Cmd.throw $ "unknown macro " <> showt text
            <> ", known macros are: "
            <> Text.intercalate ", " (map fst filename_macros)

filename_macros :: [(Text, Cmd.CmdT IO Text)]
filename_macros =
    [ ("y-m-d", liftIO date)
    , ("d", do
        dir <- Cmd.require "`d` requires a save dir"
            =<< Cmd.gets Cmd.state_save_dir
        return $ txt dir)
    ]

date :: IO Text
date = do
    tz <- Time.getCurrentTimeZone
    today <- Time.utcToLocalTime tz <$> Time.getCurrentTime
    return $ txt $ Time.formatTime Time.defaultTimeLocale "%y-%m-%d" today

-- * plain serialize

save_state :: Cmd.CmdT IO ()
save_state = save_state_as =<< Cmd.require "can't save, no save file"
    =<< get_state_path

-- | Save the state to the given file and set 'Cmd.state_save_file'.
--
-- The directory of the filename will become the project directory, so things
-- like the saved REPL history and the ly subdirectory will go there.
save_state_as :: FilePath -> Cmd.CmdT IO ()
save_state_as fname = do
    fname <- write_current_state fname
    set_save_file (Just (Cmd.ReadWrite, SaveState fname)) Save

write_current_state :: FilePath -> Cmd.CmdT IO FilePath
write_current_state fname = do
    fname <- expand_filename fname
    state <- Ui.get
    ((), metric) <- rethrow_io "write_current_state" $
        Thread.timeAction $ write_state fname state
    Log.notice $ "wrote state to " <> showt fname
        <> " " <> Transform.short_stats state
        <> ", took " <> Thread.showMetric metric
    return fname

write_state :: FilePath -> Ui.State -> IO ()
write_state fname state = do
    now <- Time.getCurrentTime
    void $ Serialize.serialize Cmd.Serialize.score_magic fname $
        Ui.config#UiConfig.meta#UiConfig.last_save #= now $
        Ui.clear state

load_state :: FilePath -> Cmd.CmdT IO ()
load_state fname = do
    (state, save_file) <- read_state fname
    set_loaded_state save_file state

read_state :: FilePath -> Cmd.CmdT IO (Ui.State, StateSaveFile)
read_state fname = do
    let mkmsg err = "load " <> txt fname <> ": " <> pretty err
    writable <- liftIO $ File.writable fname
    (state, metric) <- Thread.timeAction $
        Cmd.require_right mkmsg =<< liftIO (read_state_ fname)
    Log.notice $ "read state from " <> showt fname
        <> (if writable then " " else " (ro) ")
        <> Transform.short_stats state
        <> ", took " <> Thread.showMetric metric
    return (state, Just
        (if writable then Cmd.ReadWrite else Cmd.ReadOnly, SaveState fname))

-- | Low level 'read_state'.
read_state_ :: FilePath
    -> IO (Either Serialize.UnserializeError Ui.State)
read_state_ = Serialize.unserialize Cmd.Serialize.score_magic

-- | Low level 'read_git'.
read_git_ :: SaveGit.Repo -> Maybe SaveGit.Commit
    -> IO (Either Text (Ui.State, SaveGit.Commit, [Text]))
read_git_ = SaveGit.load


-- ** path

get_state_path :: Cmd.M m => m (Maybe FilePath)
get_state_path = do
    state <- Cmd.get
    return $ make_state_path . snd <$> Cmd.state_save_file state

make_state_path :: Cmd.SaveFile -> FilePath
make_state_path (Cmd.SaveState fn) = Path.to_path fn
make_state_path (Cmd.SaveRepo repo) = state_path_for_repo (Path.to_path repo)

-- | Get a state save path based on a repo path.  This is for saving a backup
-- state, or when switching from SaveRepo to SaveState.
state_path_for_repo :: SaveGit.Repo -> FilePath
state_path_for_repo repo = FilePath.replaceExtension repo ".state"

-- | Figure out a path for a save state based on the namespace.
infer_state_path :: Id.Namespace -> Cmd.State -> FilePath
infer_state_path ns state =
    Cmd.to_absolute state Config.save_dir
        </> untxt (Id.un_namespace ns)
        </> default_state

default_state :: FilePath
default_state = "save.state"

-- * git serialize

-- | Save a SavePoint to the git repo in 'Cmd.state_save_file', or start a new
-- one.  Set the 'Cmd.state_save_file' to the repo, so I'll keep saving to
-- that repo.
save_git :: Cmd.CmdT IO ()
save_git = save_git_as =<< get_git_path

save_git_as :: SaveGit.Repo -- ^ Save to this repo, or create it.
    -- 'Cmd.Undo.maintain_history' will start checkpointing to it.
    -- @.git@ is appended if it doesn't already have that suffix.
    -> Cmd.CmdT IO ()
save_git_as repo = do
    repo <- expand_filename repo
    repo <- return $ if SaveGit.git_suffix `List.isSuffixOf` repo then repo
        else repo ++ SaveGit.git_suffix
    cmd_state <- Cmd.get
    let rethrow = Cmd.require_right (("save git " <> txt repo <> ": ") <>)
    commit <- case Cmd.hist_last_commit $ Cmd.state_history_config cmd_state of
        Just commit -> return commit
        Nothing -> do
            let user = Cmd.config_git_user $ Cmd.state_config cmd_state
            state <- Ui.get
            rethrow =<< liftIO (SaveGit.checkpoint user repo
                (SaveGitT.SaveHistory state Nothing [] ["save"]))
    save <- rethrow =<< liftIO (SaveGit.set_save_tag repo commit)
    Log.notice $ "wrote save " <> showt save <> " to " <> showt repo
    set_save_file (Just (Cmd.ReadWrite, SaveRepo repo commit Nothing)) Save

load_git :: FilePath -> Maybe SaveGit.Commit -> Cmd.CmdT IO ()
load_git repo maybe_commit = do
    (state, save_file) <- read_git repo maybe_commit
    set_loaded_state save_file state

read_git :: FilePath -> Maybe SaveGit.Commit
    -> Cmd.CmdT IO (Ui.State, StateSaveFile)
read_git repo maybe_commit = do
    (state, commit, names) <- Cmd.require_right
        (("load git " <> txt repo <> ": ") <>)
        =<< liftIO (read_git_ repo maybe_commit)
    writable <- liftIO $ File.writable repo
    Log.notice $ "read from " <> showt repo <> ", at " <> pretty commit
        <> " names: " <> showt names
        <> if writable then "" else " (read-only, not setting save file)"
    return (state, Just (if writable then Cmd.ReadWrite else Cmd.ReadOnly,
        SaveRepo repo commit (Just names)))

-- | Revert to given save point, or the last one.
revert :: Maybe String -> Cmd.CmdT IO ()
revert maybe_ref = do
    save_file <- Cmd.require "can't revert when there is no save file"
        =<< Cmd.gets Cmd.state_save_file
    case save_file of
        (_, Cmd.SaveState fn) -> do
            whenJust maybe_ref $ \ref -> Cmd.throw $
                "can't revert to a commit when the save file isn't git: "
                <> txt ref
            load (Path.to_path fn)
        (_, Cmd.SaveRepo repo) -> revert_git (Path.to_path repo)
    Log.notice $ "revert to " <> showt save_file
    where
    revert_git repo = do
        save <- case maybe_ref of
            Nothing -> fmap fst $ Cmd.require "no last save"
                =<< liftIO (SaveGit.read_last_save repo Nothing)
            Just ref -> Cmd.require ("unparseable SavePoint: " <> showt ref)
                (SaveGit.ref_to_save ref)
        commit <- Cmd.require ("save ref not found: " <> showt save)
            =<< rethrow_git "revert" (SaveGit.read_save_ref repo save)
        load_git repo (Just commit)

rethrow_git :: Text -> IO a -> Cmd.CmdT IO a
rethrow_git caller io = Cmd.require_right id =<< liftIO (SaveGit.try caller io)

rethrow_io :: Text -> IO a -> Cmd.CmdT IO a
rethrow_io caller io = Cmd.require_right
    (\exc -> caller <> ": " <> showt (exc :: Exception.IOException))
        =<< liftIO (Exception.try io)

-- ** path

get_git_path :: Cmd.M m => m Git.Repo
get_git_path = do
    ns <- Ui.get_namespace
    state <- Cmd.get
    return $ make_git_path ns state

make_git_path :: Id.Namespace -> Cmd.State -> Git.Repo
make_git_path ns state = case Cmd.state_save_file state of
    Nothing -> Cmd.to_absolute state Config.save_dir
        </> untxt (Id.un_namespace ns) </> default_git
    Just (_, Cmd.SaveState fn) ->
        FilePath.replaceExtension (Path.to_path fn) SaveGit.git_suffix
    Just (_, Cmd.SaveRepo repo) -> Path.to_path repo

default_git :: FilePath
default_git = "save" ++ SaveGit.git_suffix

-- * config

save_allocations :: FilePath -> Cmd.CmdT IO ()
save_allocations fname = do
    allocs <- Ui.config#UiConfig.allocations <#> Ui.get
    fname <- expand_filename fname
    Log.notice $ "write instrument allocations to " <> showt fname
    rethrow_io "save_allocations" $ liftIO $ void $
        Serialize.serialize Cmd.Serialize.allocations_magic fname allocs

load_allocations :: FilePath -> Cmd.CmdT IO UiConfig.Allocations
load_allocations fname = do
    fname <- expand_filename fname
    Log.notice $ "load instrument allocations from " <> showt fname
    let mkmsg err = "unserializing instrument allocations " <> showt fname
            <> ": " <> pretty err
    Cmd.require_right mkmsg
        =<< liftIO (Serialize.unserialize Cmd.Serialize.allocations_magic fname)

-- * misc

-- | Git repos don't checkpoint views, but because I'm accustomed to them
-- checkpointing everything else I expect the views to always be saved.
--
-- So call this when quitting or switching away from a save file to save the
-- views.
--
-- They could theoretically checkpoint view changes, but it would be
-- complicated (they mostly come from the GUI, not diff) and inefficient
-- (scrolling emits tons of them).
save_views :: Cmd.State -> Ui.State -> IO ()
save_views cmd_state ui_state = case Cmd.state_save_file cmd_state of
    Just (Cmd.ReadWrite, Cmd.SaveRepo repo) ->
        SaveGit.save_views (Path.to_path repo) $ Ui.state_views ui_state
    _ -> return ()

-- | This is just like 'Cmd.SaveFile', except SaveRepo has more data.
data SaveFile =
    SaveState !FilePath
    -- | The Strings are the cmd name of this commit, and only set on a git
    -- load.
    | SaveRepo !SaveGit.Repo !SaveGit.Commit !(Maybe [Text])
    deriving (Show)
type StateSaveFile = Maybe (Cmd.Writable, SaveFile)

data SaveDirection = Save | Load deriving (Show)

-- | Do the necessary housekeeping after loading a new Ui.State.
set_loaded_state :: StateSaveFile -> Ui.State -> Cmd.CmdT IO ()
set_loaded_state save_file state = do
    set_save_file save_file Load
    Play.cmd_stop
    Cmd.modify $ Cmd.reinit_state (Cmd.empty_history_entry state)
    -- Names is only set on a git load.  This will cause "Cmd.Undo" to clear
    -- out the history.
    case save_file of
        Just (_, SaveRepo _ commit (Just names)) -> Cmd.modify $ \st -> st
            { Cmd.state_history = (Cmd.state_history st)
                { Cmd.hist_last_cmd = Just $ Cmd.Load (Just commit) names }
            }
        _ -> return ()
    old <- Ui.get
    Ui.put $ Ui.clear $
        Transform.replace_namespace Clip.clip_namespace old state
    root <- case UiConfig.config_root (Ui.state_config state) of
        Nothing -> return Nothing
        Just root -> Lists.head . Map.keys <$> Ui.views_of root
    -- Try to focus on the root block, for consistency.
    let focused = msum [root, Lists.head $ Map.keys (Ui.state_views state)]
    whenJust focused Cmd.focus

-- | If I switch away from a repo (either to another repo or to a plain state),
-- I have to clear out all the remains of the old repo, since its Commits are
-- no longer valid.
--
-- It's really important to call this whenever you change
-- 'Cmd.state_save_file'!
set_save_file :: StateSaveFile -> SaveDirection -> Cmd.CmdT IO ()
set_save_file save_file direction = do
    (maybe_commit, file) <- case save_file of
        Nothing -> return (Nothing, Nothing)
        Just (writable, save) -> case save of
            SaveState fname -> do
                path <- liftIO $ Path.canonical fname
                return (Nothing, Just (writable, Cmd.SaveState path))
            SaveRepo repo commit _ -> do
                path <- liftIO $ Path.canonical repo
                return (Just commit, Just (writable, Cmd.SaveRepo path))
    cmd_state <- Cmd.get
    when (file /= Cmd.state_save_file cmd_state) $ do
        ui_state <- Ui.get
        liftIO $ save_views cmd_state ui_state
        Cmd.modify $ \state -> state
            { Cmd.state_save_file = file
            , Cmd.state_history = let hist = Cmd.state_history state in hist
                { Cmd.hist_past = case direction of
                    Load -> []
                    Save -> map clear (Cmd.hist_past hist)
                , Cmd.hist_present = (Cmd.hist_present hist)
                    { Cmd.hist_commit = maybe_commit }
                , Cmd.hist_future = []
                }
            , Cmd.state_history_config = (Cmd.state_history_config state)
                { Cmd.hist_last_commit = maybe_commit }
            }
    -- This is called both when saving and loading, so it's a good place to
    -- mark that the state is synced to disk.
    Cmd.modify $ \st -> st
        { Cmd.state_saved = (Cmd.state_saved st)
            { Cmd._saved_state = case direction of
                Load -> Cmd.JustLoaded
                Save -> Cmd.SavedChanges
            }
        }
    where
    clear entry = entry { Cmd.hist_commit = Nothing }
