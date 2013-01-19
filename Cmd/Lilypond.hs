-- | Cmd-level support for the lilypond backend.
module Cmd.Lilypond where
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO

import qualified System.Directory as Directory
import qualified System.FilePath as FilePath
import System.FilePath ((</>))
import qualified System.IO as IO
import qualified System.Process as Process

import Util.Control
import qualified Util.Log as Log
import qualified Util.Process

import qualified Ui.Id as Id
import qualified Ui.State as State
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Msg as Msg
import qualified Cmd.PlayUtil as PlayUtil

import qualified Derive.Call.Block as Call.Block
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Score as Score
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Lilypond.Convert as Convert
import qualified Perform.Lilypond.Lilypond as Lilypond
import qualified Perform.Pitch as Pitch

import Types


ly_filename :: (Cmd.M m) => BlockId -> m FilePath
ly_filename block_id = do
    dir <- Cmd.require_msg "ly_filename: no save dir"
        =<< Cmd.gets Cmd.state_save_dir
    return $ dir </> "ly" </> Id.ident_name block_id ++ ".ly"

lookup_key :: Cmd.Performance -> Pitch.Key
lookup_key perf =
    fromMaybe Twelve.default_key $ msum $ map (lookup . Derive.state_environ) $
        Map.elems (Msg.perf_track_dynamic perf)
    where
    lookup environ = case TrackLang.get_val TrackLang.v_key environ of
        Right key -> Just (Pitch.Key key)
        Left _ -> Nothing

-- | Run a derivation in lilypond context, which will cause certain calls to
-- behave differently.
derive :: (Cmd.M m) => Derive.Lilypond -> BlockId -> m Derive.Result
derive config block_id = do
    state <- (State.config#State.default_#State.tempo #= 1) <$> State.get
    global_transform <- State.config#State.global_transform <#> State.get
    Derive.extract_result <$> PlayUtil.run_ui state with_ly mempty mempty
        (Call.Block.eval_root_block global_transform block_id)
    where with_ly constant = constant { Derive.state_lilypond = Just config }

compile_ly :: FilePath -> Lilypond.TimeConfig -> Lilypond.Title
    -> [Score.Event] -> IO (Either String Cmd.StackMap, [Log.Msg])
compile_ly ly_filename config title events = do
    let (result, logs) = make_ly config title events
    (flip (,) logs) <$> case result of
        Left err -> return $ Left err
        Right (ly, stack_map) -> do
            Directory.createDirectoryIfMissing True
                (FilePath.takeDirectory ly_filename)
            IO.withFile ly_filename IO.WriteMode $ \hdl ->
                mapM_ (Text.IO.hPutStr hdl) ly
            Util.Process.logged $ Process.proc "lilypond"
                ["-o", FilePath.dropExtension ly_filename, ly_filename]
            return $ Right stack_map

make_ly :: Lilypond.TimeConfig -> Lilypond.Title -> [Score.Event]
    -> (Either String ([Text.Text], Cmd.StackMap), [Log.Msg])
make_ly (Lilypond.TimeConfig quarter quantize_dur) title score_events =
    (Lilypond.make_ly (Lilypond.default_config quarter) title
        (postproc quantize_dur events), logs)
    where
    (events, logs) = LEvent.partition $
        Convert.convert quarter (map LEvent.Event score_events)

-- * postproc

postproc :: Lilypond.Duration -> [Lilypond.Event] -> [Lilypond.Event]
postproc quantize_dur = Convert.quantize quantize_dur . normalize

normalize :: [Lilypond.Event] -> [Lilypond.Event]
normalize [] = []
normalize events@(e:_)
    | Lilypond.event_start e == 0 = events
    | otherwise = map (move (Lilypond.event_start e)) events
    where move n e = e { Lilypond.event_start = Lilypond.event_start e - n }
