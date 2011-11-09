{- | Simple Events are supposed to be easy to read, and easy to serialize to
    text and load back again.  Functions here convert them to and from text
    form, stashing converted simple blocks in the clipboard.
-}
module Cmd.Simple where
import qualified Control.Monad.Trans as Trans
import qualified Data.Tree as Tree

import Ui
import qualified Ui.Block as Block
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.Id as Id
import qualified Ui.ScoreTime as ScoreTime
import qualified Ui.Skeleton as Skeleton
import qualified Ui.State as State
import qualified Ui.Track as Track

import qualified Cmd.Clip as Clip
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Selection as Selection

import qualified Derive.Score as Score
import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.Midi.Perform as Perform
import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import qualified App.Config as Config


-- | TODO should it have a ruler?  Otherwise they come in without a ruler...
-- but copy and paste can't copy and paste the ruler.
--
-- (id_name, title, tracks, skeleton)
type Block = (String, String, [Track], [(Int, Int)])

-- | (id_name, title, events)
type Track = (String, String, [Event])

-- | (start, duration, text)
type Event = (Double, Double, String)

-- | (start, duration, text, initial_pitch)
type ScoreEvent = (Double, Double, String, Pitch.Degree)

-- | (inst, start, duration, initial_pitch)
type PerfEvent = (String, Double, Double, Pitch.NoteNumber)

from_score :: ScoreTime -> Double
from_score = ScoreTime.to_double

from_real :: RealTime -> Double
from_real = RealTime.to_seconds

event :: Events.PosEvent -> Event
event (start, event) = (from_score start,
    from_score (Event.event_duration event), Event.event_string event)

score_event :: Score.Event -> ScoreEvent
score_event evt = (from_real (Score.event_start evt),
    from_real (Score.event_duration evt),
    Score.event_string evt, Score.initial_pitch evt)

perf_event :: Perform.Event -> PerfEvent
perf_event evt =
    ( Instrument.inst_name (Perform.event_instrument evt)
    , from_real start
    , from_real (Perform.event_duration evt)
    , Pitch.nn (Signal.at start (Perform.event_pitch evt))
    )
    where start = Perform.event_start evt

dump_block :: (State.M m) => BlockId -> m Block
dump_block block_id = do
    block <- State.get_block block_id
    let track_ids = Block.block_track_ids block
    tracks <- mapM dump_track track_ids
    tree <- State.get_track_tree block_id
    return (Id.id_string block_id, Block.block_title block, tracks,
        to_skel tree)
    where
    to_skel = concatMap go
        where
        go (Tree.Node track subs) =
            [(num track, num (Tree.rootLabel sub)) | sub <- subs]
            ++ to_skel subs
    num = State.track_tracknum

dump_track :: (State.M m) => TrackId -> m Track
dump_track track_id = do
    track <- State.get_track track_id
    return (simplify_track track_id track)

simplify_track :: TrackId -> Track.Track -> Track
simplify_track track_id track =
    (Id.id_string track_id, Track.track_title track, map event events)
    where events = Events.ascending (Track.track_events track)

dump_selection :: Cmd.CmdL [(TrackId, [Event])]
dump_selection = do
    track_events <- Selection.events
    return [(track_id, map event events)
        | (track_id, _, events) <- track_events]

-- * load

load_block :: FilePath -> Cmd.CmdL ()
load_block fn = read_block fn >>= Clip.state_to_clip

read_block :: FilePath -> Cmd.CmdL State.State
read_block fn = do
    simple_block <- Trans.liftIO (readIO =<< readFile fn :: IO Block)
    convert_block simple_block

convert_block :: (Cmd.M m) => Block -> m State.State
convert_block block = do
    config <- Cmd.block_config
    State.exec_rethrow "convert block" State.empty (make_block config block)

make_block :: (State.M m) => Block.Config -> Block -> m BlockId
make_block config (id_name, title, tracks, skel) = do
    tracks <- mapM convert_track tracks
    block_id <- State.create_block (Id.read_id id_name)
        (Block.block config title tracks)
    State.set_skeleton block_id (Skeleton.make skel)
    return block_id

convert_track :: (State.M m) => Track -> m Block.Track
convert_track (id_name, title, events) = do
    let pos_events = map convert_event events
    track_id <- State.create_track (Id.read_id id_name) $
        Track.track title pos_events
    return $ Block.track (Block.TId track_id State.no_ruler) Config.track_width

convert_event :: Event -> Events.PosEvent
convert_event (start, dur, text) =
    (ScoreTime.double start, Event.event text (ScoreTime.double dur))
