-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
module Ui.UiTest where
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text

import qualified Util.CallStack as CallStack
import qualified Util.Debug as Debug
import qualified Util.Lists as Lists
import qualified Util.Log as Log
import qualified Util.Rect as Rect
import qualified Util.Test.Testing as Testing
import qualified Util.Texts as Texts
import qualified Util.Then as Then

import qualified Midi.Midi as Midi
import qualified Ui.Block as Block
import qualified Ui.Color as Color
import qualified Ui.Event as Event
import qualified Ui.Events as Events
import qualified Ui.GenId as GenId
import qualified Ui.Id as Id
import qualified Ui.Meter.Make as Meter.Make
import qualified Ui.Meter.Meter as Meter
import qualified Ui.Ruler as Ruler
import qualified Ui.Meter.Mark as Mark
import qualified Ui.ScoreTime as ScoreTime
import qualified Ui.Sel as Sel
import qualified Ui.Skeleton as Skeleton
import qualified Ui.Track as Track
import qualified Ui.TrackTree as TrackTree
import qualified Ui.Types as Types
import qualified Ui.Ui as Ui
import qualified Ui.UiConfig as UiConfig
import qualified Ui.Zoom as Zoom

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.Instrument.MidiInst as MidiInst
import qualified Cmd.Ruler.RulerUtil as RulerUtil
import qualified Cmd.Simple as Simple
import qualified Cmd.TimeStep as TimeStep

import qualified Derive.ParseSkeleton as ParseSkeleton
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.ScoreT as ScoreT
import qualified Derive.Stack as Stack

import qualified Perform.Midi.Patch as Patch
import qualified Perform.Lilypond.Constants as Lilypond.Constants
import qualified Instrument.Inst as Inst
import qualified Instrument.InstT as InstT
import qualified App.Config as Config

import           Global
import           Types


-- Test functions do things I don't want to include in non-testing code, such
-- as freely call 'error' and define convenient but incorrect orphan instances.
-- The orphans should be protected behind an ifdef in "Derive.TestInstances",
-- but I still don't want to mix test and non-test code.
--
-- UiTest is the most fundamental of the test modules, so I should only need
-- to check here.
#ifndef TESTING
#error "don't import testing modules from non-test code"
#endif


-- | (10, 50) seems to be the smallest x,y OS X will accept.  Apparently
-- fltk's sizes don't take the menu bar into account, which is about 44 pixels
-- high, so a y of 44 is the minimum.
default_rect :: Rect.Rect
default_rect = Rect.xywh 10 50 200 200

default_divider :: Block.Divider
default_divider = Block.Divider Color.blue

-- state

mkid :: Text -> Id.Id
mkid = Id.read_short test_ns

bid :: Text -> BlockId
bid = Id.BlockId . mkid

vid :: Text -> ViewId
vid = Id.ViewId . mkid

tid :: Text -> TrackId
tid = Id.TrackId . mkid

rid :: Text -> RulerId
rid = Id.RulerId . mkid

test_ns :: Id.Namespace
test_ns = Id.namespace "test"

default_zoom :: Zoom.Zoom
default_zoom = Config.zoom

-- * fmt

-- | Visualize event ranges.  This can be used with 'Testing.equal_fmt'.
fmt_events :: [EventSpec] -> Text
fmt_events [] = ""
fmt_events events = Text.unlines
    [ fmt_ruler min_start (events_end events)
    , fmt_events_only min_start events
    ]
    where min_start = min 0 (events_start events)

fmt_ui_events :: [Event.Event] -> Text
fmt_ui_events = fmt_events . map extract_event

fmt_events_only :: Int -> [EventSpec] -> Text
fmt_events_only min_start = Text.unlines . map event
    where
    event (start, dur, text) = gap <> arrow <> label
        where
        gap = Text.replicate (to_spaces (min start (start + dur))) " "
        arrow
            | dur == 0 && ScoreTime.is_negative dur = "<"
            | dur == 0 = ">"
            | dur < 0 = "<" <> middle <> "|"
            | otherwise = "|" <> middle <> ">"
        middle = Text.replicate (time_to_spaces (abs dur) - 1) "-"
        label = if Text.null text then "" else " [" <> text <> "]"
    to_spaces t = offset + time_to_spaces t
    offset = time_to_spaces $ fromIntegral (abs min_start)

fmt_ruler :: Int -> Int -> Text
fmt_ruler start end = Text.stripEnd $ mconcatMap (space . pretty) ts
    where
    space t = t <> Text.replicate (time_to_spaces step - Text.length t) " "
    ts = Then.takeWhile1 (<end) (Lists.range_ start 1)
    step = 1

fmt_start_duration :: [(ScoreTime, ScoreTime)] -> Text
fmt_start_duration = fmt_events . map (\(s, d) -> (s, d, ""))

fmt_blocks :: [BlockSpec] -> Text
fmt_blocks = Text.strip . Text.unlines
    . concatMap (\(block, tracks) -> [block <> ":", fmt_tracks tracks])

fmt_tracks :: [TrackSpec] -> Text
fmt_tracks [] = ""
fmt_tracks tracks = Text.unlines $
    (indent <> fmt_ruler 0 (maximum (map (events_end . snd) tracks)))
    : concatMap track tracks
    where
    track (title, events) = case Text.lines (fmt_events_only 0 events) of
        [] -> []
        x : xs -> fmt_title title <> x : map (indent<>) xs
    indent = Text.replicate (title_length + 2) " "
    fmt_title title = Text.justifyLeft title_length ' ' title <> ": "
    title_length = maximum $ map (Text.length . fst) tracks

time_to_spaces :: ScoreTime -> Int
time_to_spaces = floor . (*4)

events_end :: [(ScoreTime, ScoreTime, x)] -> Int
events_end = maybe 0 ceiling . Lists.maximum .  map (\(s, d, _) -> max s (s+d))

events_start :: [(ScoreTime, ScoreTime, x)] -> Int
events_start = maybe 0 floor . Lists.minimum . map (\(s, d, _) -> min s (s+d))

-- | Extract and fmt the fst . right element.  Many DeriveTest extractors
-- return Either Error (val, [log]).
right_fst :: (a -> Text) -> Either x (a, y) -> Text
right_fst fmt = either (const "") (fmt . fst)

-- * monadic mk- functions

-- | (block_id, tracks)
--
-- If the name ends with @=ruler@, then the length of the ruler is derived from
-- the events inside, rather than being hardcoded.  This is convenient for
-- tests and lets them avoid hardcoding the default_ruler end.
--
-- Also, if the name contains @--@, the text after it becomes the block title.
type BlockSpec = (Text, [TrackSpec])

-- | (track_title, events)
type TrackSpec = (Text, [EventSpec])

-- | (start, dur, text)
type EventSpec = (ScoreTime, ScoreTime, Text)

-- | Parse a block spec, which looks like @name[=ruler] [-- title]@
parse_block_spec :: Text -> (BlockId, Text, Bool)
parse_block_spec spec = (bid block_id, Text.strip title, has_ruler)
    where
    (name, title) = Texts.split1 "--" spec
    (block_id, has_ruler) = maybe (Text.strip name, False) (, True) $
        Text.stripSuffix "=ruler" (Text.strip name)

-- | Often tests work with a single block, or a single view.  To make them
-- less verbose, there is a default block and view so functions can omit the
-- parameter if convenient.
default_block_id :: BlockId
default_block_id = bid default_block_name

default_block_name :: Text
default_block_name = "b1"

default_view_id :: ViewId
default_view_id = mk_vid default_block_id

default_ruler_id :: RulerId
default_ruler_id = rid "r0"
    -- r1 would conflict with ruler automatically generated because of the
    -- =ruler suffix

-- | Return the val and state, throwing an IO error on an exception.  Intended
-- for tests that don't expect to fail here.
run :: CallStack.Stack => Ui.State -> Ui.StateId a -> (a, Ui.State)
run state m = case result of
    Left err -> error $ "state error: " <> show err
    Right (val, state', _) -> (val, state')
    where result = Ui.run_id state m

exec :: CallStack.Stack => Ui.State -> Ui.StateId a -> Ui.State
exec state m = case Ui.exec state m of
    Left err -> error $ "state error: " <> prettys err
    Right state' -> state'

eval :: CallStack.Stack => Ui.State -> Ui.StateId a -> a
eval state m = case Ui.eval state m of
    Left err -> error $ "state error: " <> show err
    Right val -> val

run_mkview :: [TrackSpec] -> ([TrackId], Ui.State)
run_mkview tracks = run Ui.empty $ mkblock_view (default_block_name, tracks)

run_mkblocks :: [BlockSpec] -> ([BlockId], Ui.State)
run_mkblocks = run Ui.empty . mkblocks

mkblocks :: Ui.M m => [BlockSpec] -> m [BlockId]
mkblocks blocks = mapM (fmap fst . mkblock_named) blocks

mkviews :: Ui.M m => [BlockSpec] -> m [ViewId]
mkviews blocks = mapM mkview =<< mkblocks blocks

run_mkblock :: [TrackSpec] -> ([TrackId], Ui.State)
run_mkblock = run Ui.empty . mkblock

mkblock :: Ui.M m => [TrackSpec] -> m [TrackId]
mkblock = fmap snd . mkblock_named . (default_block_name,)

mkblock_named :: Ui.M m => BlockSpec -> m (BlockId, [TrackId])
mkblock_named (spec, tracks) = do
    let (block_id, title, has_ruler) = parse_block_spec spec
    ruler_id <- if has_ruler
        then do
            let len = event_end tracks
                rid = Id.id test_ns ("r" <> showt len)
            ifM (Maybe.isJust <$> Ui.lookup_ruler (Id.RulerId rid))
                (return (Id.RulerId rid))
                (Ui.create_ruler rid (mkruler_44 len 1))
        else maybe
            (Ui.create_ruler (Id.unpack_id default_ruler_id) default_ruler)
            (const (return default_ruler_id))
                =<< Ui.lookup_ruler default_ruler_id
    mkblock_ruler_id ruler_id block_id title tracks
    where
    event_end :: [TrackSpec] -> Int
    event_end = ceiling . ScoreTime.to_double . maximum . (0:)
        . concatMap (map (\(s, d, _) -> max s (s+d)) . snd)

mkblocks_skel :: Ui.M m => [(BlockSpec, [Skeleton.Edge])] -> m ()
mkblocks_skel blocks = forM_ blocks $ \(block, skel) -> do
    (block_id, track_ids) <- mkblock_named block
    Ui.set_skeleton block_id (Skeleton.make skel)
    return (block_id, track_ids)

-- | Like 'mkblock', but uses the provided ruler instead of creating its
-- own.  Important if you are creating multiple blocks and don't want
-- a separate ruler for each.
mkblock_ruler_id :: Ui.M m => RulerId -> BlockId -> Text -> [TrackSpec]
    -> m (BlockId, [TrackId])
mkblock_ruler_id ruler_id block_id title tracks = do
    Ui.set_namespace test_ns
    -- Start at 1 because track 0 is the ruler.
    tids <- forM (zip [1..] tracks) $ \(i, track) ->
        Ui.create_track (Id.unpack_id (mk_tid_block block_id i))
            (make_track track)
    create_block (Id.unpack_id block_id) "" $ (Block.RId ruler_id)
        : [Block.TId tid ruler_id | tid <- tids]
    unless (Text.null title) $
        Ui.set_block_title block_id title
    Ui.set_skeleton block_id =<< parse_skeleton block_id
    -- This ensures that any state created via these functions will have the
    -- default midi config.  This saves some hassle since all tests can assume
    -- there are some instruments defined.
    Ui.modify set_default_allocations
    return (block_id, tids)

mkblock_ruler :: Ui.M m => Ruler.Ruler -> BlockId -> Text -> [TrackSpec]
    -> m (BlockId, [TrackId])
mkblock_ruler ruler block_id title tracks = do
    ruler_id <- Create.ruler "r" ruler
    mkblock_ruler_id ruler_id block_id title tracks

create_block :: Ui.M m => Id.Id -> Text -> [Block.TracklikeId] -> m BlockId
create_block block_id title tracks =
    Ui.create_config_block block_id $ Block.block config title
        [Block.track tid 30 | tid <- tracks]
    where
    -- TODO use Implicit and remove the parse_skeleton stuff.
    config = Block.default_config { Block.config_skeleton = Block.Explicit }

parse_skeleton :: Ui.M m => BlockId -> m Skeleton.Skeleton
parse_skeleton block_id = do
    tracks <- TrackTree.tracks_of block_id
    return $ ParseSkeleton.default_parser
        [ ParseSkeleton.Track (Ui.track_tracknum t) (Ui.track_title t)
        | t <- tracks
        ]

mkview :: Ui.M m => BlockId -> m ViewId
mkview block_id = do
    block <- Ui.get_block block_id
    Ui.create_view (Id.unpack_id (mk_vid block_id)) $
        Block.view block block_id default_rect default_zoom

mkblock_view :: Ui.M m => BlockSpec -> m [TrackId]
mkblock_view block_spec = (snd <$> mkblock_named block_spec) <* mkview block_id
    where (block_id, _, _) = parse_block_spec (fst block_spec)

mk_vid :: BlockId -> ViewId
mk_vid block_id = Id.ViewId $ Id.id ns ("v." <> block_name)
    where (ns, block_name) = Id.un_id (Id.unpack_id block_id)

mk_vid_name :: Text -> ViewId
mk_vid_name = mk_vid . bid

-- | Make a TrackId as mkblock does.  This is so tests can independently come
-- up with the track IDs mkblock created just by knowing their tracknum.
mk_tid :: TrackNum -> TrackId
mk_tid = mk_tid_block default_block_id

mk_tid_block :: CallStack.Stack => BlockId -> TrackNum -> TrackId
mk_tid_block block_id i
    | i < 1 = error $ "mk_tid_block: event tracknums start at 1: " <> show i
    | otherwise = Id.TrackId $ GenId.ids_for ns block_name "t" !! (i-1)
    where (ns, block_name) = Id.un_id (Id.unpack_id block_id)

mk_tid_name :: Text -> TrackNum -> TrackId
mk_tid_name = mk_tid_block . bid

-- | Get a TrackNum back out of a 'mk_tid' call.
tid_tracknum :: TrackId -> TrackNum
tid_tracknum = parse . Lists.takeWhileEnd Char.isDigit . untxt . Id.ident_name
    where
    parse "" = -1
    parse ds = read ds

-- * actions

insert_event_in :: Ui.M m => Text -> TrackNum -> (ScoreTime, ScoreTime, Text)
    -> m ()
insert_event_in block_name tracknum (pos, dur, text) =
    Ui.insert_event (mk_tid_name block_name tracknum) (Event.event pos dur text)

insert_event :: Ui.M m => TrackNum -> (ScoreTime, ScoreTime, Text) -> m ()
insert_event = insert_event_in default_block_name

remove_event_in :: Ui.M m => Text -> TrackNum -> ScoreTime -> m ()
remove_event_in name tracknum pos =
    Ui.remove_events_range (mk_tid_name name tracknum)
        (Events.Point pos Types.Positive)

remove_event :: Ui.M m => TrackNum -> ScoreTime -> m ()
remove_event = remove_event_in default_block_name

-- ** make specs

-- | This is a simplification of 'TrackSpec' that assumes one pitch per note.
-- It hardcodes the scale to @*@ and all the control tracks are under a single
-- note track, but in exchange it's easier to write than full TrackSpecs.
--
-- @(inst, [(t, dur, pitch)], [(control, [(t, val)])])@
--
-- If the pitch looks like \"a -- 4c\" then \"a\" is the note track's event and
-- \"4c\" is the pitch track's event.  If the pitch is missing, the empty
-- pitch event is filtered out.  This doesn't happen for the note event since
-- empty note event has a meaning.
type NoteSpec = (Text, [EventSpec], [(Text, [(ScoreTime, Text)])])

note_spec :: NoteSpec -> [TrackSpec]
note_spec (inst, pitches, controls) =
    -- Filter empty tracks.  Otherwise an empty pitch track will override #=.,
    -- which will be confusing.
    filter (not . null . snd) $
        note_track : pitch_track : map control_track controls
    where
    note_track = (">" <> inst, [(t, dur, s) | (t, dur, (s, _)) <- track])
    pitch_track =
        ("*", [(t, 0, p) | (t, _, (_, p)) <- track, not (Text.null p)])
    control_track (title, events) = (title, [(t, 0, val) | (t, val) <- events])
    track = [(t, d, split s) | (t, d, s) <- pitches]
    split s
        | "--" `Text.isInfixOf` s = (note, pitch)
        | otherwise = ("", s)
        where
        (note, pitch) = bimap Text.strip Text.strip $ Texts.split1 "--" s

-- | Abbreviation for 'note_spec' where the inst and controls are empty.
note_track :: [EventSpec] -> [TrackSpec]
note_track pitches = note_spec ("", pitches, [])

-- | Like 'note_track', but all notes have a duration of 1.
note_track1 :: [Text] -> [TrackSpec]
note_track1 ps = note_track [(s, 1, p) | (s, p) <- zip (Lists.range_ 0 1) ps]

inst_note_track :: Text -> [EventSpec] -> [TrackSpec]
inst_note_track inst pitches = note_spec (inst, pitches, [])

inst_note_track1 :: Text -> [Text] -> [TrackSpec]
inst_note_track1 title pitches = note_spec (title, notes, [])
    where notes = [(s, 1, p) | (s, p) <- zip (Lists.range_ 0 1) pitches]

control_track :: [(ScoreTime, Text)] -> [EventSpec]
control_track ns = [(t, 0, s) | (t, s) <- ns]

regular_notes :: Int -> [TrackSpec]
regular_notes n = note_track $
    take n [(t, 1, p) | (t, p) <- zip (Lists.range_ 0 1) (cycle pitches)]
    where
    pitches =
        [Text.singleton o <> Text.singleton p | o <- "34567", p <- "cdefgab"]

-- | Parse a TrackSpec back out to a NoteSpec.
to_note_spec :: [TrackSpec] -> [NoteSpec]
to_note_spec =
    mapMaybe parse . Lists.splitBefore (ParseTitle.is_note_track . fst)
    where
    parse [] = Nothing
    parse ((inst, notes) : controls) =
        Just (Text.drop 1 inst, add_pitches pitches notes, [])
        where
        pitches = maybe [] snd $
            List.find (ParseTitle.is_pitch_track . fst) controls

-- | Like 'to_note_spec' but expect just notes and pitches, no controls.
to_pitch_spec :: [NoteSpec] -> [[EventSpec]]
to_pitch_spec = filter (not . null) . map (\(_, events, _) -> events)

add_pitches :: [EventSpec] -> [EventSpec] -> [EventSpec]
add_pitches = go ""
    where
    go p pitches ns@((nt, nd, n) : notes)
        | ((pt, _, nextp) : restp) <- pitches, nt >= pt = go nextp restp ns
        | otherwise = (nt, nd, add p n) : go p pitches notes
    go _ _ [] = []
    add p n = Text.intercalate " -- " $ filter (not . Text.null) [p, n]


-- * state to spec

trace_logs :: [Log.Msg] -> a -> a
trace_logs logs val
    | null logs = val
    | otherwise = Debug.trace_str
        (Text.stripEnd $ Text.unlines $ "\tlogged:" : map Log.format_msg logs)
        val

-- | Get the names and tracks of the default block.
extract_tracks :: Ui.State -> [TrackSpec]
extract_tracks = extract_tracks_of default_block_id

extract_blocks :: Ui.State -> [BlockSpec]
extract_blocks state =
    [ (Texts.join2 " -- " (Id.ident_name bid) title, tracks)
    | (bid, title, tracks) <- extract_block_ids state
    ]

extract_block_id :: BlockId -> Ui.State -> Maybe [TrackSpec]
extract_block_id block_id state = Lists.head
    [block | (bid, _, block) <- extract_block_ids state, bid == block_id]

extract_block_ids :: Ui.State -> [(BlockId, Text, [TrackSpec])]
extract_block_ids state =
    [ (block_id, Block.block_title block, extract_tracks_of block_id state)
    | (block_id, block) <- Map.toList (Ui.state_blocks state)
    ]

extract_skeleton :: Ui.State -> [(TrackNum, TrackNum)]
extract_skeleton = maybe [] (Skeleton.flatten . Block.block_skeleton)
    . Map.lookup default_block_id . Ui.state_blocks

extract_skeletons :: Ui.State -> Map BlockId [(TrackNum, TrackNum)]
extract_skeletons =
    fmap (Skeleton.flatten . Block.block_skeleton) . Ui.state_blocks

extract_track_ids :: Ui.State -> [(BlockId, [TrackId])]
extract_track_ids state =
    [(block_id, tracks_of block) | (block_id, block)
        <- Map.toList (Ui.state_blocks state)]
    where
    tracks_of = Block.track_ids_of . map Block.tracklike_id . Block.block_tracks

-- | Like 'dump_block' but strip out everything but the tracks.
extract_tracks_of :: BlockId -> Ui.State -> [TrackSpec]
extract_tracks_of block_id state = tracks
    where ((_, tracks), _) = dump_block block_id state

dump_blocks :: Ui.State -> [(BlockId, (BlockSpec, [Skeleton.Edge]))]
dump_blocks state = zip block_ids (map (flip dump_block state) block_ids)
    where block_ids = Map.keys (Ui.state_blocks state)

dump_block :: BlockId -> Ui.State -> (BlockSpec, [Skeleton.Edge])
dump_block block_id state =
    ((name <> if Text.null title then "" else " -- " <> title,
        map dump_track (Maybe.catMaybes tracks)), skel)
    where
    (id_str, title, tracks, skel) = eval state (Simple.dump_block block_id)
    name = snd $ Id.un_id $ Id.read_id id_str
    dump_track (_, title, events) = (title, map convert events)
    convert (start, dur, text) =
        (ScoreTime.from_double start, ScoreTime.from_double dur, text)

-- extract_rulers :: Ui.State -> [(RulerId, [Meter.Make.LabeledMark])]
-- extract_rulers =
--     map (second (map strip . Meter.ruler_meter)) . Map.toList . Ui.state_rulers
--     where
--     strip m = m
--         { Meter.Make.m_label = Meter.Make.strip_markup (Meter.Make.m_label m) }

-- * view

select :: Ui.M m => ViewId -> Sel.Selection -> m ()
select view_id sel = Ui.set_selection view_id Config.insert_selnum (Just sel)

select_point :: Ui.M m => ViewId -> TrackNum -> ScoreTime -> m ()
select_point view_id tracknum pos =
    select view_id (Sel.point tracknum pos Sel.Positive)

-- * non-monadic make_- functions

mkstack :: (TrackNum, ScoreTime, ScoreTime) -> Stack.Stack
mkstack (tracknum, s, e) = mkstack_block (default_block_name, tracknum, s, e)

mkstack_block :: (Text, TrackNum, ScoreTime, ScoreTime) -> Stack.Stack
mkstack_block (block, tracknum, s, e) = Stack.from_outermost
    [Stack.Block (bid block), Stack.Track (mk_tid_name block tracknum),
        Stack.Region s e]

-- ** track

make_track :: TrackSpec -> Track.Track
make_track (title, events) = Track.modify_events
    (Events.insert (map make_event events)) (empty_track title)

empty_track :: Text -> Track.Track
empty_track title = (Track.track title Events.empty)
    { Track.track_render = Track.no_render }

-- ** event

make_event :: EventSpec -> Event.Event
make_event (start, dur, text) = Event.event start dur text

extract_event :: Event.Event -> EventSpec
extract_event e = (Event.start e, Event.duration e, Event.text e)

-- ** ruler

default_ruler :: Ruler.Ruler
default_ruler = mkruler_44 32 1

default_block_end :: ScoreTime
default_block_end = Ruler.time_end default_ruler

-- | TimeStep to step by 1 ScoreTime on the default ruler.
step1 :: TimeStep.TimeStep
step1 = TimeStep.time_step
    (TimeStep.AbsoluteMark TimeStep.AllMarklists Meter.H)

-- | Create a ruler with a 4/4 "meter" marklist with the given number of marks
-- at the given distance.  Marks are rank [1, 2, 2, ...].
--
-- The end of the ruler should be at marks*dist.  An extra mark is created
-- since marks start at 0.
mkruler_44 :: Int -> ScoreTime -> Ruler.Ruler
mkruler_44 marks dist =
    mkruler 4 (fromIntegral marks * dist) (Meter.repeat 4 Meter.T)

mkruler :: TrackTime -> TrackTime -> Meter.AbstractMeter -> Ruler.Ruler
mkruler measure_dur end meter =
    Ruler.meter_ruler $ RulerUtil.meter_until meter measure_dur 4 end

-- | This makes a meter without a Meter.Meter, which cmds that look at Meter
-- will be confused by.
mkruler_marks :: [(TrackTime, Mark)] -> Ruler.Ruler
mkruler_marks marks =
    Ruler.modify_marklists (Map.insert Ruler.meter_name (Nothing, mlist))
        Ruler.empty
    where mlist = Mark.marklist $ map (second (uncurry mkmark)) marks

mkruler_ranks :: [(TrackTime, RankNum)] -> Ruler.Ruler
mkruler_ranks = mkruler_marks . map (second (, ""))

e_mark :: Mark.Mark -> Mark
e_mark m = (fromEnum (Mark.mark_rank m), mark_name m)

mark_name :: Mark.Mark -> Mark.Label
mark_name = Meter.Make.strip_markup . Mark.mark_name

mkmark :: RankNum -> Mark.Label -> Mark.Mark
mkmark rank label = Mark.Mark
    { mark_rank = toEnum rank
    , mark_width = 0
    , mark_color = Color.black
    , mark_name = label
    , mark_name_zoom_level = 0
    , mark_zoom_level = 0
    }

e_rulers :: Ui.State -> [(Text, Text)]
e_rulers state =
    [ (Id.ident_name bid, e_ruler bid state)
    | bid <- Map.keys (Ui.state_blocks state)
    ]

e_ruler :: BlockId -> Ui.State -> Text
e_ruler bid state = eval state $
    Text.unwords . map (snd . snd) . ruler_marks <$>
        (Ui.get_ruler =<< Ui.ruler_of bid)

type Mark = (RankNum, Mark.Label)
type RankNum = Int

e_meters :: Ui.State -> [(Text, [(TrackTime, Mark)])]
e_meters state =
    [ (Id.ident_name bid, e_meter bid state)
    | bid <- Map.keys (Ui.state_blocks state)
    ]

e_meter :: BlockId -> Ui.State -> [(TrackTime, Mark)]
e_meter bid state = eval state $
    ruler_marks <$> (Ui.get_ruler =<< Ui.ruler_of bid)

ruler_marks :: Ruler.Ruler -> [(TrackTime, Mark)]
ruler_marks =
    map (second e_mark) . maybe mempty (Mark.to_list . snd)
    . Map.lookup Ruler.meter_name
    . Ruler.ruler_marklists

meter_zoom :: Double -> Meter.Meter -> [(TrackTime, Mark)]
meter_zoom zoom = map (second e_mark)
    . filter ((<= zoom) . Mark.mark_name_zoom_level . snd)
    . Meter.Make.make_measures

meter_marklist :: Double -> Meter.Meter -> [(TrackTime, Mark.Label)]
meter_marklist zoom = map (second snd) . meter_zoom zoom

-- * allocations

midi_allocation :: Text -> Patch.Config -> UiConfig.Allocation
midi_allocation qualified config =
    UiConfig.allocation (InstT.parse_qualified qualified) (UiConfig.Midi config)

midi_config :: [Midi.Channel] -> Patch.Config
midi_config chans = Patch.config [((wdev, chan), Nothing) | chan <- chans]

-- | Make Simple.Allocations from (inst, qualified, [chan]).
midi_allocations :: [(Text, Text, [Midi.Channel])] -> UiConfig.Allocations
midi_allocations allocs = Simple.allocations
    [ (inst, (qualified, Simple.Midi $ map (wdev_name,) chans))
    | (inst, qualified, chans) <- allocs
    ]

mk_allocation :: (Simple.Instrument, Simple.Qualified, Maybe [Midi.Channel])
    -> (ScoreT.Instrument, UiConfig.Allocation)
mk_allocation (inst, qual, backend) = Simple.allocation
    (inst, (qual, maybe Simple.Im (Simple.Midi . map (wdev_name,)) backend))

mk_allocations :: [(Simple.Instrument, Simple.Qualified, Maybe [Midi.Channel])]
    -> UiConfig.Allocations
mk_allocations = UiConfig.Allocations . Map.fromList . map mk_allocation

set_default_allocations :: Ui.State -> Ui.State
set_default_allocations = Ui.config#UiConfig.allocations #= default_allocations

default_allocations :: UiConfig.Allocations
default_allocations = midi_allocations
    [ ("i", "s/1", [0..2])
    , ("i1", "s/1", [0..2])
    , ("i2", "s/2", [3])
    , ("i3", "s/3", [4])
    ]

modify_midi_config :: CallStack.Stack => ScoreT.Instrument
    -> (Patch.Config -> Patch.Config)
    -> UiConfig.Allocations -> UiConfig.Allocations
modify_midi_config inst modify =
    Testing.expect_right . UiConfig.modify_allocation inst modify_alloc
    where
    modify_alloc alloc = do
        config <- justErr ("not a midi alloc: " <> pretty inst) $
            UiConfig.midi_config (UiConfig.alloc_backend alloc)
        return $ alloc
            { UiConfig.alloc_backend = UiConfig.Midi (modify config) }

i1, i2, i3 :: ScoreT.Instrument
i1 = ScoreT.Instrument "i1"
i2 = ScoreT.Instrument "i2"
i3 = ScoreT.Instrument "i3"

i1_qualified :: InstT.Qualified
i1_qualified = InstT.Qualified "s" "1"

wdev :: Midi.WriteDevice
wdev = Midi.write_device wdev_name

wdev_name :: Text
wdev_name = "wdev"

-- * instrument db

default_db :: Cmd.InstrumentDb
default_db = make_db [("s", map make_patch ["1", "2", "3"])]

make_patch :: InstT.Name -> Patch.Patch
make_patch name = Patch.patch (-2, 2) name

make_db :: [(Text, [Patch.Patch])] -> Cmd.InstrumentDb
make_db synth_patches = fst $ Inst.db $ ly : map make synth_patches
    where
    make (name, patches) = make_synth name (map MidiInst.make_patch patches)
    -- Always add ly-global, lilypond tests want it, and it doesn't hurt the
    -- other ones.
    ly = Lilypond.Constants.ly_synth Cmd.empty_code

make_db1 :: MidiInst.Patch -> Cmd.InstrumentDb
make_db1 patch = fst $ Inst.db [make_synth "s" [patch]]

make_synth :: InstT.SynthName -> [MidiInst.Patch] -> MidiInst.Synth
make_synth name patches = MidiInst.synth name "Test Synth" patches

-- * misc

btrack :: TrackId -> Block.Track
btrack track_id = Block.track (Block.TId track_id default_ruler_id) 30
