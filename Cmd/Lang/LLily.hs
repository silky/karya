-- | Lilypond compiles are always kicked off manually.
--
-- I used to have some support for automatically reinvoking lilypond after
-- changes to a block, but it didn't seem too useful, since any useful amount
-- of lilypond score takes quite a while to compile.
module Cmd.Lang.LLily where
import qualified Control.Monad.Trans as Trans
import qualified Data.Map as Map
import qualified System.FilePath as FilePath
import qualified System.Process as Process

import Util.Control
import qualified Util.Log as Log
import qualified Util.Process

import qualified Ui.Id as Id
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Lilypond
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score

import qualified Perform.Lilypond.Convert as Convert
import qualified Perform.Lilypond.Lilypond as Lilypond
import qualified Perform.Pitch as Pitch

import Types


pipa :: Derive.Events -> Cmd.CmdL ()
pipa = from_events "c-maj" "4/4" config . clean
    where
    config = Cmd.Lilypond.TimeConfig 0.125 Lilypond.D16
    clean = filter_inst ["fm8/pipa", "fm8/dizi", "ptq/yangqin"]
        . LEvent.events_of
        -- . filter_inst ["ptq/yangqin"]

bloom :: BlockId -> Cmd.CmdL ()
bloom block_id = do
    score <- make_score "a-maj" "5/4" block_id
    let config = Cmd.Lilypond.TimeConfig 0.5 Lilypond.D16
    block score config block_id

events :: BlockId -> Cmd.CmdL Derive.Events
events block_id = Derive.r_events <$> Cmd.Lilypond.derive block_id

ly_events :: RealTime -> Derive.Events -> ([Lilypond.Event], [Log.Msg])
ly_events quarter = LEvent.partition . Convert.convert quarter

filter_inst :: [String] -> [Score.Event] -> [Score.Event]
filter_inst inst_s = filter ((`elem` insts) . Score.event_instrument)
    where insts = map Score.Instrument inst_s

block :: Lilypond.Score -> Cmd.Lilypond.TimeConfig -> BlockId -> Cmd.CmdL ()
block score config block_id = do
    (events, logs) <- LEvent.partition . Derive.r_events <$>
        Cmd.Lilypond.derive block_id
    mapM_ Log.write logs
    filename <- Cmd.Lilypond.ly_filename block_id
    stack_map <- Trans.liftIO $
        Cmd.Lilypond.compile_ly filename config score events
    Cmd.modify_play_state $ \st -> st
        { Cmd.state_lilypond_stack_maps = Map.insert block_id
            stack_map (Cmd.state_lilypond_stack_maps st)
        }

from_events :: String -> String -> Cmd.Lilypond.TimeConfig -> [Score.Event]
    -> Cmd.CmdL ()
from_events key time_sig config events = do
    block_id <- Cmd.get_focused_block
    score <- make_score key time_sig block_id
    filename <- Cmd.Lilypond.ly_filename block_id
    stack_map <- Trans.liftIO $
        Cmd.Lilypond.compile_ly filename config score events
    Cmd.modify_play_state $ \st -> st
        { Cmd.state_lilypond_stack_maps = Map.insert block_id
            stack_map (Cmd.state_lilypond_stack_maps st)
        }

view_pdf :: BlockId -> Cmd.CmdL ()
view_pdf block_id = do
    filename <- Cmd.Lilypond.ly_filename block_id
    Trans.liftIO $ Util.Process.logged $
        (Process.proc "open" [FilePath.replaceExtension filename ".pdf"])
    return ()

make_score :: (Cmd.M m) => String -> String -> BlockId -> m Lilypond.Score
make_score key_str time_sig block_id = either Cmd.throw return $ do
    key <- Lilypond.parse_key (Pitch.Key key_str)
    tsig <- Lilypond.parse_time_signature time_sig
    return $ Lilypond.Score
        { Lilypond.score_title = Id.ident_name block_id
        , Lilypond.score_time = tsig
        , Lilypond.score_key = key
        }
