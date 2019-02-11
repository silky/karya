-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | This module manages the performance of music, specifically the creation
    of performance threads.

    Performance is relative to a toplevel block, so each block has its own set
    of caches.  Since performance is lazy, a separate thread will force it
    asynchronously.
-}
module Cmd.Performance (
    SendStatus, update_performance, derive_blocks, performance, derive
    , Process, evaluate_im
) where
import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.Chan as Chan
import qualified Control.Monad.State.Strict as Monad.State

import qualified Data.Map.Strict as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Text.IO as Text.IO
import qualified Data.Vector as Vector

import qualified System.IO as IO

import qualified Util.Control as Control
import qualified Util.Log as Log
import qualified Util.Map as Map
import qualified Util.Process
import qualified Util.Thread as Thread
import qualified Util.Vector

import qualified App.Config
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Msg as Msg
import qualified Cmd.PlayUtil as PlayUtil

import qualified Derive.Derive as Derive
import qualified Derive.Score as Score
import qualified Derive.Stream as Stream

import qualified Instrument.Inst as Inst
import qualified Perform.Im.Convert as Im.Convert
import qualified Perform.RealTime as RealTime
import qualified Synth.Shared.Config as Config
import qualified Ui.Block as Block
import qualified Ui.Track as Track
import qualified Ui.Ui as Ui
import qualified Ui.UiConfig as UiConfig

import           Global
import           Types


type SendStatus = BlockId -> Msg.DeriveStatus -> IO ()
type StateM = Monad.State.StateT Cmd.State IO ()

{- | Update the performances by rederiving if necessary.  This means figuring
    out ScoreDamage, and if there has been damage, killing any in-progress
    derivation and starting derivation.  This updates performances for the root
    block and all visible blocks.

    The majority of the calls here will bring neither score damage nor
    a changed view id, and thus this will do nothing.

    This is tricky, and I've gotten it wrong in the past, so here's a detailed
    description:

    Merge ui damage with each perf's damage.  Then for each perf, if it's
    'Cmd.state_current_performance' has damage, kill its thread, and remove its
    entry in 'Cmd.state_performance_threads'.  The lack of a thread entry,
    whether because was removed or never existed, means that a block should be
    rederived.  Derivation creates a new 'Cmd.Performance' and an evaluate
    thread, and puts them into 'Cmd.state_current_performance' and
    'Cmd.state_performance_threads' respectively, but due to laziness, no actual
    derivation happens unless someone (like play) happens to look at the
    performance.  This all happens synchronously, so the next time
    'update_performance' is called, it sees a nice clean new Performance with
    no damage.

    Meanwhile, the evaluate thread asynchronously waits for a bit, then
    forces the contents of the Performance, and then sends it back to the
    responder so it can stash it in 'Cmd.state_performance'.  If a new change
    comes in while it's waiting it'll get killed off, and the out-of-date
    derivation will never happen.  Yay for laziness!
-}
update_performance :: SendStatus -> Ui.State -> Cmd.State
    -> Derive.ScoreDamage -> IO Cmd.State
update_performance send_status ui_state cmd_state damage =
    -- The update will be modifying Cmd.State, especially PlayState.
    Monad.State.execStateT (run_update send_status ui_state)
        (insert_damage damage cmd_state)

run_update :: SendStatus -> Ui.State -> StateM
run_update send_status ui_state = do
    kill_threads
    mapM_ (try_generate_performance send_status ui_state)
        (derive_blocks ui_state)

-- | Which blocks should get derived?
derive_blocks :: Ui.State -> Set BlockId
derive_blocks ui_state = Set.fromList $ maybe id (:) root_id visible
    where
    root_id = Ui.config_root (Ui.state_config ui_state)
    visible = map Block.view_block $ Map.elems $ Ui.state_views ui_state

try_generate_performance :: SendStatus -> Ui.State -> BlockId -> StateM
try_generate_performance send_status ui_state block_id = do
    state <- Monad.State.get
    when (needs_generate state block_id) $
        generate_performance ui_state (derive_wait state block_id)
            send_status block_id

-- | Theoretically I should be able to do away with the wait, but in practice
-- deriving constantly causes UI latency.
derive_wait :: Cmd.State -> BlockId -> Thread.Seconds
derive_wait cmd_state block_id
    | block_id `Set.member` Cmd.state_derive_immediately cmd_state = 0
    | otherwise = App.Config.default_derive_wait

-- | Since caches are stored per-performance, score damage is also
-- per-performance.  It accumulates in an existing performance and is cleared
-- when a new performance is created from the old one.
insert_damage :: Derive.ScoreDamage -> Cmd.State -> Cmd.State
insert_damage damage = modify_play_state $ \st -> st
    -- Damage update is tricky.  Damage in 'Cmd.state_current_performance'
    -- is a signal that the performance for that block is out of date and needs
    -- to be updated.  Technically all I need is a Bool since it just checks
    -- (damage /= mempty).  But this signal has to go in the current
    -- performance, since it's updated (and hence the damage is cleared)
    -- synchronously, and otherwise I'd get stuck in a loop killing and
    -- starting new derivations.
    --
    -- However, the derivation is relative to 'Cmd.state_performance', so the
    -- damage is also relative to it.  So this damage is actually used for
    -- derivation, not as a out-of-date flag.  When state_current_performance
    -- is promoted to state_performance, the damage is also cleared.
    { Cmd.state_current_performance =
        Map.map update (Cmd.state_current_performance st)
    , Cmd.state_performance = Map.map update (Cmd.state_performance st)
    }
    where
    update perf = perf { Cmd.perf_damage = damage <> Cmd.perf_damage perf }

-- | Kill all performance threads with damage.  If they are still deriving
-- they're now out of date and should stop.
kill_threads :: StateM
kill_threads = do
    play_state <- Monad.State.gets Cmd.state_play
    let threads = Cmd.state_performance_threads play_state
        perfs = Cmd.state_current_performance play_state
        with_damage =
            [ block_id | (block_id, perf) <- Map.toList perfs
            , Cmd.perf_damage perf /= mempty
            ]
        kill = filter ((`elem` with_damage) . fst) $ Map.toList threads
    liftIO $ mapM_ (Concurrent.killThread . snd) kill
    Monad.State.modify $ modify_play_state $ const $ play_state
        { Cmd.state_performance_threads = Map.delete_keys (map fst kill)
            (Cmd.state_performance_threads play_state)
        }


-- * performance evaluation

-- | True if this BlockId should be regenerated.  This happens if there is
-- no performance, which means either there never was one, or it was deleted
-- by 'kill_threads' thanks to ScoreDamage.
--
-- I use 'Cmd.state_performance_threads' and not
-- 'Cmd.state_current_performance', because the thread is filled in
-- synchronously, while the current performance is filled in later.
needs_generate :: Cmd.State -> BlockId -> Bool
needs_generate state block_id = not (Map.member block_id perfs)
    where perfs = Cmd.state_performance_threads $ Cmd.state_play state

-- | Start a new performance thread.
--
-- Pull previous caches from the existing performance, if any.  Use them to
-- generate a new performance, kick off a thread for it, and insert the new
-- thread into 'Cmd.state_performance_threads' and performance into
-- 'Cmd.state_current_performance'.  It will be promoted to
-- 'Cmd.state_performance' when 'evaluate_performance' completes.
generate_performance :: Ui.State -> Thread.Seconds -> SendStatus -> BlockId
    -> StateM
generate_performance ui_state wait send_status block_id = do
    cmd_state <- Monad.State.get
    let (perf, logs) = derive ui_state cmd_state block_id
    mapM_ Log.write logs
    thread_id <- liftIO $ Thread.start $ do
        let allocs = Ui.config#Ui.allocations #$ ui_state
            im_config = Cmd.config_im (Cmd.state_config cmd_state)
        let lookup_inst = either (const Nothing) Just
                . Cmd.state_resolve_instrument ui_state cmd_state
        evaluate_performance
            (if im_allocated allocs then Just im_config else Nothing)
            lookup_inst wait send_status (Cmd.score_path cmd_state)
            (Cmd.state_play_multiplier (Cmd.state_play cmd_state)) block_id perf
    Monad.State.modify $ modify_play_state $ \st -> st
        { Cmd.state_performance_threads = Map.insert block_id
            thread_id (Cmd.state_performance_threads st)
        , Cmd.state_current_performance = Map.insert block_id
            perf (Cmd.state_current_performance st)
        }
    -- If the derivation somehow failed, then the old performance will remain,
    -- and since there is no thread, this will try again the next time around.

derive :: Ui.State -> Cmd.State -> BlockId -> (Cmd.Performance, [Log.Msg])
derive ui_state cmd_state block_id = (perf, logs)
    where
    perf = case cmd_result of
        Left err -> broken_performance $
            "derivation for " <> showt block_id <> " failed: " <> pretty err
        Right (derive_result, _, _) -> case derive_result of
            Nothing -> broken_performance $
                "derivation for " <> showt block_id <> " aborted"
            Just result -> performance ui_state result
    -- The previous cache comes from the fully evaluated performance, since
    -- otherwise there's no point killing the 'evaluate_performance' thread if
    -- the cache makes all derivation serialized.
    prev_cache = maybe mempty Cmd.perf_derive_cache $ Map.lookup block_id $
        Cmd.state_performance $ Cmd.state_play cmd_state
    -- The damage also comes from the current performance, since that's where
    -- the performance is deriving from.
    damage = maybe mempty Cmd.perf_damage $ Map.lookup block_id $
        Cmd.state_performance $ Cmd.state_play cmd_state
    (_state, _midi, logs, cmd_result) = Cmd.run_id ui_state cmd_state $
        PlayUtil.derive_block prev_cache damage block_id

evaluate_performance :: Maybe Config.Config
    -> (Score.Instrument -> Maybe Cmd.ResolvedInstrument)
    -> Thread.Seconds -> SendStatus -> FilePath -> RealTime -> BlockId
    -> Cmd.Performance -> IO ()
evaluate_performance im_config lookup_inst wait send_status score_path
        play_multiplier block_id perf = do
    send_status block_id Msg.OutOfDate
    Thread.delay wait
    send_status block_id Msg.Deriving
    -- I just force the logs here, and wait for a play to actually write them.
    ((), cpu_secs, wall_secs) <- Thread.timeAction $
        return $! Msg.force_performance perf
    when (wall_secs > 1) $
        Log.notice $ "derived " <> showt block_id <> " in "
            <> pretty cpu_secs <> " cpu, " <> pretty wall_secs <> " wall"
    (procs, events) <-  case im_config of
        Nothing -> return ([], Cmd.perf_events perf)
        Just config -> evaluate_im config lookup_inst score_path
            play_multiplier block_id (Cmd.perf_events perf)
    send_status block_id $ Msg.DeriveComplete
        (perf { Cmd.perf_events = events })
        (if null procs then Msg.ImUnnecessary else Msg.ImStarted)
    failed <- case im_config of
        Just config -> watch_subprocesses config score_path
            (send_status block_id . Msg.ImStatus) (Set.fromList procs)
        Nothing -> return False
    unless (null procs) $
        send_status block_id $ Msg.ImStatus $ Msg.ImComplete failed

type Process = (FilePath, [String])

-- | Watch each subprocess, return when they all exit.
watch_subprocesses :: Config.Config -> FilePath -> (Msg.ImStatus -> IO ())
    -> Set Process -> IO Bool
watch_subprocesses config score_path send_status procs
    | Set.null procs = return False
    | otherwise = Util.Process.multipleOutput (Set.toList procs) $ \chan ->
        Control.loop1 (procs, False) $ \loop (procs, failed) -> if
            | Set.null procs -> return failed
            | otherwise -> do
                ((cmd, args), out) <- Chan.readChan chan
                loop =<< process procs failed (cmd, args) out
    where
    process procs failure (cmd, args) = \case
        Util.Process.Stderr line ->
            put line >> return (procs, failure)
        Util.Process.Stdout line -> do
            failed <- progress line
            return (procs, failed || failure)
        Util.Process.Exit code -> do
            when (code /= Util.Process.ExitCode 0) $
                Log.warn $ "subprocess " <> txt cmd <> " "
                    <> showt args <> " returned " <> showt code
            return (Set.delete (cmd, args) procs, failure)

    progress line
        | Just progress <- Config.parseProgress line = do
            send_status $ Msg.ImProgress $
                im_progress (Config.imDir config) score_path progress
            return False
        | Just (block_id, track_ids, err) <- Config.parseFailure line = do
            Log.warn $ "im failure: " <> pretty block_id <> ": "
                <> pretty track_ids <> ": " <> err
            return True
        | otherwise = do
            put $ "couldn't parse: " <> line
            return False
    -- These get called concurrently, so avoid jumbled output.
    put line = Log.with_stdio_lock $ Text.IO.hPutStrLn IO.stdout line

im_progress :: FilePath -> FilePath -> Config.Progress -> Msg.ImProgressT
im_progress im_dir score_path (Config.Progress block_id track_ids instrument
        renderedPrevChunk chunknum (start, end)) =
    Msg.ImProgressT
        { im_block_id = block_id
        , im_track_ids = track_ids
        , im_start = start
        , im_end = end
        , im_chunknum = chunknum
        , im_prev_waveform = case mb_filename of
            Nothing -> Nothing
            Just filename -> Just $ Track.WaveformChunk
                { _filename = filename
                -- TODO I need inv_tempo_map
                , _start = RealTime.to_score $
                    start - fromIntegral Config.chunkSeconds
                , _ratios = [1]
                }
        }
        where
        -- If the prev chunk was just re-rendered, infer the chunk path
        -- and stash it in 'Msg.ImProgressT' so I can have the UI display
        -- it.
        mb_filename
            | renderedPrevChunk = Just $
                Config.chunkPath im_dir score_path block_id instrument
                    (chunknum - 1)
            | otherwise = Nothing

-- | If there are im events, serialize them and return a Processes to render
-- them, and the non-im events.
evaluate_im :: Config.Config
    -> (Score.Instrument -> Maybe Cmd.ResolvedInstrument)
    -> FilePath -> RealTime -> BlockId -> Vector.Vector Score.Event
    -> IO ([Process], Vector.Vector Score.Event)
evaluate_im config lookup_inst score_path play_multiplier block_id events = do
    cmds <- Maybe.catMaybes <$> mapM write_notes by_synth
    return (cmds, fromMaybe mempty $ lookup Nothing by_synth)
    where
    by_synth = Util.Vector.partition_on im_synth events
    im_synth event = case lookup_inst (Score.event_instrument event) of
        Just inst -> case Cmd.inst_instrument inst of
            Inst.Inst (Inst.Im {}) _ -> Just (Cmd.inst_synth inst)
            _ -> Nothing
        Nothing -> Nothing

    write_notes (Just synth_name, events) = do
        case Map.lookup synth_name (Config.synths config) of
            Just synth -> do
                let notes_file = Config.notesFilename (Config.imDir config)
                        score_path block_id synth
                    output_dir = Config.outputDirectory (Config.imDir config)
                        score_path block_id
                -- TODO It would be better to not reach this point at all if
                -- the block hasn't changed, but until then at least I can
                -- skip running the binary if the notes haven't changed.
                changed <- Im.Convert.write play_multiplier block_id
                    lookup_inst notes_file events
                let binary = Config.binary synth
                return $ if null binary || not changed then Nothing
                    else Just (binary, [notes_file, output_dir])
            Nothing -> do
                Log.warn $ "unknown im synth " <> showt synth_name <> " with "
                    <> showt (Vector.length events) <> " events"
                return Nothing
    write_notes (Nothing, _) = return Nothing

-- | If there are no UiConfig.Im instruments, then I don't need to bother to
-- partition out its events.  However, it means I won't get errors if there
-- happen to be any, but I'll worry about that if it becomes a problem.
im_allocated :: UiConfig.Allocations -> Bool
im_allocated (UiConfig.Allocations allocs) =
    any ((==UiConfig.Im) . UiConfig.alloc_backend) (Map.elems allocs)

-- | Make a broken performance with just an error msg.  This ensures that
-- the msg is logged when you try to play, but will still suppress further
-- performance, so you don't get a million msgs.
broken_performance :: Text -> Cmd.Performance
broken_performance msg = Cmd.Performance
    { perf_derive_cache = mempty
    , perf_events = mempty
    , perf_logs = [Log.msg Log.Warn Nothing msg]
    , perf_logs_written = False
    , perf_track_dynamic = mempty
    , perf_integrated = mempty
    , perf_damage = mempty
    , perf_warps = mempty
    , perf_track_signals = mempty
    , perf_ui_state = Ui.empty
    }

-- | Constructor for 'Cmd.Performance'.
performance :: Ui.State -> Derive.Result -> Cmd.Performance
performance state result = Cmd.Performance
    { perf_derive_cache = Derive.r_cache result
    , perf_events = Vector.fromList events
    , perf_logs = logs
    , perf_logs_written = False
    , perf_track_dynamic = Derive.r_track_dynamic result
    , perf_integrated = Derive.r_integrated result
    , perf_damage = mempty
    , perf_warps = Derive.r_track_warps result
    , perf_track_signals = Derive.r_track_signals result
    , perf_ui_state = state
    }
    where (events, logs) = Stream.partition (Derive.r_events result)

modify_play_state :: (Cmd.PlayState -> Cmd.PlayState) -> Cmd.State -> Cmd.State
modify_play_state modify state =
    state { Cmd.state_play = modify (Cmd.state_play state) }
