-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utility functions for derive tests.
module Derive.DeriveTest where
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import           System.FilePath ((</>))
import qualified System.IO.Unsafe as Unsafe

import qualified Util.CallStack as CallStack
import qualified Util.Debug as Debug
import qualified Util.Lists as Lists
import qualified Util.Log as Log
import qualified Util.Num as Num
import qualified Util.Ranges as Ranges
import qualified Util.Test.Testing as Testing

import qualified App.Config as Config
import qualified App.Path as Path
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Create as Create
import qualified Cmd.Instrument.MidiInst as MidiInst
import qualified Cmd.PlayUtil as PlayUtil
import qualified Cmd.SaveGitT as SaveGitT
import qualified Cmd.Simple as Simple

import qualified Derive.C.All as C.All
import qualified Derive.C.Prelude.Block as Prelude.Block
import qualified Derive.Controls as Controls
import           Derive.DDebug ()
-- just make sure it compiles
import qualified Derive.Derive as Derive
import qualified Derive.DeriveT as DeriveT
import qualified Derive.Deriver.Internal as Internal
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Eval as Eval
import qualified Derive.Expr as Expr
import qualified Derive.LEvent as LEvent
import qualified Derive.PSignal as PSignal
import qualified Derive.Scale as Scale
import qualified Derive.Scale.Scales as Scales
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Score as Score
import qualified Derive.ScoreT as ScoreT
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Stack as Stack
import qualified Derive.Stream as Stream
import           Derive.TestInstances ()
import qualified Derive.Typecheck as Typecheck

import qualified Instrument.Common as Common
import qualified Instrument.Inst as Inst
import qualified Instrument.InstT as InstT

import qualified Midi.Midi as Midi
import qualified Midi.StubMidi as StubMidi
import qualified Perform.Im.Convert as Im.Convert
import qualified Perform.Im.Patch as Im.Patch
import qualified Perform.Midi.Convert as Convert
import qualified Perform.Midi.Patch as Patch
import qualified Perform.Midi.Perform as Perform
import qualified Perform.Midi.Types as Midi.Types
import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import qualified Synth.Shared.Config as Shared.Config
import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note

import qualified Ui.Block as Block
import qualified Ui.Color as Color
import qualified Ui.Id as Id
import qualified Ui.Ruler as Ruler
import qualified Ui.Skeleton as Skeleton
import qualified Ui.Track as Track
import qualified Ui.Ui as Ui
import qualified Ui.UiConfig as UiConfig
import qualified Ui.UiTest as UiTest

import           Global
import           Types


-- | Simulate the linear interpolate call, to check deriver output that
-- involves that particular call.
--
-- Drops the first sample to make this match output from the derive call
-- interpolators.
signal_interpolate :: RealTime -> Signal.Y -> RealTime -> Signal.Y
    -> [(RealTime, Signal.Y)]
signal_interpolate x0 y0 x1 y1 =
    drop 1 [(x, project x) | x <- Lists.rangeEnd x0 x1 1]
    where
    project = Num.scale y0 y1 . Num.normalize (to_y x0) (to_y x1) . to_y
    to_y = RealTime.to_seconds

-- * run

run :: Ui.State -> Derive.Deriver a
    -> Either Text (a, Derive.State, [Log.Msg])
run ui_state m = run_ ui_state (Internal.with_stack_block bid m)
    where
    -- Make sure Derive.get_current_block_id, called by add_new_track_warp,
    -- doesn't throw.
    bid = UiTest.bid "derive-test.run-fakeblock"

-- | Run without a fake stack.
run_ :: Ui.State -> Derive.Deriver a
    -> Either Text (a, Derive.State, [Log.Msg])
run_ ui_state m = case Derive.run derive_state m of
    (Left err, _, _logs) -> Left (pretty err)
    (Right val, state, logs) -> Right (val, state, logs)
    where
    derive_state = Derive.initial_state
        (default_constant ui_state mempty mempty) default_dynamic

extract_run :: (a -> b) -> Either Text (a, Derive.State, [Log.Msg])
    -> Either Text b
extract_run _ (Left err) = Left err
extract_run extract (Right (val, _, msgs)) =
    Right $ trace_logs msgs (extract val)

run_events :: (a -> b)
    -> Either Text ([LEvent.LEvent a], Derive.State, [Log.Msg])
    -> Either Text ([b], [Text])
run_events extract = extract_run $ extract_levents extract

eval :: Ui.State -> Derive.Deriver a -> Either Text a
eval ui_state m = extract_run id (run ui_state m)

-- * perform

perform_block :: [UiTest.TrackSpec] -> ([Midi.WriteMessage], [Text])
perform_block tracks = perform_blocks [(UiTest.default_block_name, tracks)]

perform_blocks :: [UiTest.BlockSpec] -> ([Midi.WriteMessage], [Text])
perform_blocks blocks = (mmsgs, map show_log (filter interesting_log logs))
    where
    ((_, mmsgs), logs) = perform default_convert_lookup
        UiTest.default_allocations (Derive.r_events result)
    result = derive_blocks blocks

-- TODO this tosses the logs from the stream, shouldn't I collect them into
-- the output?
perform :: Lookup -> UiConfig.Allocations -> Stream.Stream Score.Event
    -> (([Midi.Types.Event], [Midi.WriteMessage]), [Log.Msg])
perform lookup allocs stream =
    ((fst (LEvent.partition perf_events), mmsgs), logs)
    where
    (perf_events, perf) = perform_stream lookup allocs stream
    (mmsgs, logs) = extract_logs perf

perform_defaults :: Stream.Stream Score.Event
    -> (([Midi.Types.Event], [Midi.WriteMessage]), [Log.Msg])
perform_defaults = perform default_convert_lookup UiTest.default_allocations

perform_stream :: Lookup -> UiConfig.Allocations -> Stream.Stream Score.Event
    -> ([LEvent.LEvent Midi.Types.Event], [LEvent.LEvent Midi.WriteMessage])
perform_stream (lookup_inst, lookup) allocs stream = (perf_events, midi)
    where
    perf_events = Convert.convert 1 lookup lookup_inst (Stream.events_of stream)
    (midi, _) = Perform.perform Perform.initial_state midi_allocs perf_events
    midi_allocs = Perform.config <$> PlayUtil.midi_configs allocs

-- | Perform events with the given instrument db.
perform_synths :: UiConfig.Allocations -> [MidiInst.Synth]
    -> Stream.Stream Score.Event
    -> (([Midi.Types.Event], [Midi.WriteMessage]), [Log.Msg])
perform_synths allocs synths =
    perform (synths_to_convert_lookup allocs synths) allocs

perform_synths_simple :: SimpleAllocations -> [MidiInst.Synth]
    -> Stream.Stream Score.Event
    -> (([Midi.Types.Event], [Midi.WriteMessage]), [Log.Msg])
perform_synths_simple allocs_ synths =
    perform (make_convert_lookup allocs db) allocs
    where
    db = synths_to_db synths
    allocs = simple_allocs allocs_

-- | Chain a 'perform' from a Derive.Result.
perform_result :: (Stream.Stream Score.Event -> (a, [Log.Msg]))
    -> Derive.Result -> (a, [Text])
perform_result perform result = (val, map show_log (derive_logs ++ perf_logs))
    where
    (events, derive_logs) = extract_logs $ Stream.to_list $
        Derive.r_events result
    (val, perf_logs) = perform (Stream.from_events events)

-- ** perform im

perform_im_synths :: SimpleAllocations -> [MidiInst.Synth]
    -> Stream.Stream Score.Event -> ([Note.Note], [Text])
perform_im_synths allocs synths =
    perform_im (fst $ make_convert_lookup ui_allocs db)
    where
    db = synths_to_db synths
    ui_allocs = im_allocs allocs

-- | Unlike 'perform', this includes the logs from the stream in the output.
-- TODO change perform?
perform_im :: (ScoreT.Instrument -> Maybe Cmd.ResolvedInstrument)
    -> Stream.Stream Score.Event -> ([Note.Note], [Text])
perform_im lookup_inst stream =
    (perf_events, mapMaybe show_interesting_log $ derive_logs ++ perf_logs)
    where
    (events, derive_logs) = Stream.partition stream
    (perf_events, perf_logs) = LEvent.partition $
        Im.Convert.convert UiTest.default_block_id lookup_inst events

-- * derive

derive_tracks :: Text -> [UiTest.TrackSpec] -> Derive.Result
derive_tracks = derive_tracks_setup mempty

-- | Derive tracks but with a linear skeleton.  Good for testing note
-- transformers since the default skeleton parsing won't create those.
derive_tracks_linear :: Text -> [UiTest.TrackSpec] -> Derive.Result
derive_tracks_linear = derive_tracks_setup with_linear

-- | Variant that lets you run setup on various states.
derive_tracks_setup :: Setup -> Text -> [UiTest.TrackSpec] -> Derive.Result
derive_tracks_setup setup title tracks = derive_blocks_setup setup
    [(UiTest.default_block_name <> " -- " <> title, tracks)]

-- ** derive block variations

-- These are all built on 'derive_block_standard', with various things
-- specialized.

-- | Create multiple blocks, and derive the first one.
derive_blocks :: [UiTest.BlockSpec] -> Derive.Result
derive_blocks = derive_blocks_setup mempty

derive_block :: Ui.State -> BlockId -> Derive.Result
derive_block = derive_block_setup mempty

derive_blocks_setup :: Setup -> [UiTest.BlockSpec] -> Derive.Result
derive_blocks_setup setup block_tracks = derive_block_setup setup ui_state bid
    where (bid : _, ui_state) = UiTest.run_mkblocks block_tracks

-- | Derive a block with the testing environ.
derive_block_setup :: Setup -> Ui.State -> BlockId -> Derive.Result
derive_block_setup setup =
    derive_block_standard (with_environ default_environ <> setup)
        default_cmd_state mempty mempty

-- | Like 'derive_block_setup', but exec the StateId.
derive_block_setup_m :: Setup -> Ui.StateId a -> BlockId -> Derive.Result
derive_block_setup_m setup create =
    derive_block_standard (with_environ default_environ <> setup)
        default_cmd_state mempty mempty (UiTest.exec Ui.empty create)

-- | Derive the results of a "Cmd.Repl.LDebug".dump_block.
derive_dump :: [MidiInst.Synth] -> Simple.State -> BlockId -> Derive.Result
derive_dump synths dump@(_, simple_allocs, _) =
    derive_block_setup (with_synths allocs synths) state
    where
    allocs = Simple.allocations simple_allocs
    state = UiTest.eval Ui.empty (Simple.load_state dump)

-- | Derive a block in the same way that the app does.
derive_block_standard :: Setup -> Cmd.State -> Derive.Cache
    -> Derive.ScoreDamage -> Ui.State -> BlockId -> Derive.Result
derive_block_standard setup cmd_state cache damage ui_state_ block_id =
    run_cmd ui_state (setup_cmd setup cmd_state) cmd
    where
    cmd = Derive.extract_result <$> PlayUtil.run cache damage deriver
    ui_state = setup_ui setup ui_state_
    deriver = setup_deriver setup $ Prelude.Block.eval_root_block block_id

perform_dump :: [MidiInst.Synth] -> Simple.State -> Derive.Result
    -> (([Midi.Types.Event], [Midi.WriteMessage]), [Log.Msg])
perform_dump synths (_, simple_allocs, _) =
    perform lookup allocs . Derive.r_events
    where
    db = synths_to_db synths
    lookup = make_convert_lookup allocs db
    allocs = Simple.allocations simple_allocs

derive :: Ui.State -> Derive.NoteDeriver -> Derive.Result
derive ui_state deriver = Derive.extract_result $
    Derive.derive (default_constant ui_state mempty mempty)
        default_dynamic deriver

-- * cmd

-- | CmdTest also has this, but I can't import it because it imports
-- DeriveTest.
run_cmd :: CallStack.Stack => Ui.State -> Cmd.State -> Cmd.CmdId a -> a
run_cmd ui_state cmd_state cmd = case result of
    Right (Just result, _, _) -> result
    Right (Nothing, _, _) -> error "DeriveTest.run_cmd: Cmd aborted"
    Left err -> error $ "DeriveTest.run_cmd: Cmd error: " <> show err
    where
    (_cstate, _midi_msgs, _logs, result) = Cmd.run_id ui_state cmd_state cmd

-- * setup

type Setup = SetupA (Stream.Stream Score.Event)

-- | This file only ever uses 'Setup', but it loses polymorphism.  To reuse
-- @with_*@ functions in a polymorphic way, I can use SetupA and pull them back
-- out with setup_deriver.
data SetupA a = Setup {
    setup_ui :: Ui.State -> Ui.State
    , setup_cmd :: Cmd.State -> Cmd.State
    , setup_deriver :: Derive.Deriver a -> Derive.Deriver a
    }

instance Semigroup (SetupA a) where
    Setup ui1 cmd1 deriver1 <> Setup ui2 cmd2 deriver2 =
        Setup (ui1 . ui2) (cmd1 . cmd2) (deriver1 . deriver2)
instance Monoid (SetupA a) where
    mempty = Setup id id id
    mappend = (<>)

with_ui :: (Ui.State -> Ui.State) -> Setup
with_ui ui = mempty { setup_ui = ui }

with_cmd :: (Cmd.State -> Cmd.State) -> Setup
with_cmd cmd = mempty { setup_cmd = cmd }

with_deriver :: (Derive.Deriver a -> Derive.Deriver a) -> SetupA a
with_deriver deriver = mempty { setup_deriver = deriver }

-- ** setup_ui

-- | Set the skeleton of the tracks to be linear, i.e. each track is the child
-- of the one to the left.  This overrides the default behaviour of figuring
-- out a skeleton by making note tracks start their own branches.
with_linear :: Setup
with_linear = with_linear_block UiTest.default_block_id

with_linear_block :: BlockId -> Setup
with_linear_block block_id =
    with_ui $ \state -> setup_ui (with_skel_block block_id (skel state)) state
    where
    -- Start at 1 to exclude the ruler.
    skel state =
        [(x, y) | (x, Just y) <- Lists.zipNext [1 .. ntracks state  - 1]]
    ntracks state = length $ maybe [] Block.block_tracks $
        Map.lookup block_id (Ui.state_blocks state)

with_skel :: [Skeleton.Edge] -> Setup
with_skel = with_skel_block UiTest.default_block_id

with_skel_block :: BlockId -> [Skeleton.Edge] -> Setup
with_skel_block block_id skel = with_ui $ \state -> UiTest.exec state $
    Ui.set_skeleton block_id (Skeleton.make skel)

with_default_ruler :: Ruler.Ruler -> Setup
with_default_ruler ruler = with_ui $
    Ui.rulers %= Map.insert UiTest.default_ruler_id ruler

-- | Set the ruler on the given block.
with_ruler :: BlockId -> Ruler.Ruler -> Setup
with_ruler block_id ruler = with_ui $ \state -> UiTest.exec state make
    where make = Create.new_ruler block_id (Id.ident_name block_id) ruler

with_tsigs :: [TrackId] -> Setup
with_tsigs = with_tsig_sources . map (, Nothing)

with_tsig_tracknums :: [TrackNum] -> Setup
with_tsig_tracknums = with_tsigs . map UiTest.mk_tid

with_tsig_sources :: [(TrackId, Maybe Track.RenderSource)] -> Setup
with_tsig_sources track_ids = with_ui $ Ui.tracks %= Map.mapWithKey enable
    where
    enable track_id track = case lookup track_id track_ids of
        Just source -> track { Track.track_render =
            Track.RenderConfig (Track.Line source) Color.blue }
        Nothing -> track

with_midi_config :: ScoreT.Instrument -> Text -> Common.Config -> Patch.Config
    -> Setup
with_midi_config inst qualified common_config midi_config = with_ui $
    Ui.config#UiConfig.allocations_map %= Map.insert inst
        (UiConfig.Allocation (InstT.parse_qualified qualified)
            common_config (UiConfig.Midi midi_config))

-- * setup_deriver

with_key :: Text -> SetupA a
with_key key = with_deriver $ Derive.with_val EnvKey.key key

with_environ :: Env.Environ -> SetupA a
with_environ env =
    with_deriver $ Internal.local $ \st -> st { Derive.state_environ = env }

-- | I'm not really supposed to do this, but should be *mostly* ok for tests.
-- It's not entirely ok because some values are baked in to e.g. lookup
-- functions.
modify_constant :: (Derive.Constant -> Derive.Constant) -> SetupA a
modify_constant f = with_deriver $ \deriver -> do
    Derive.modify $ \st ->
        st { Derive.state_constant = f (Derive.state_constant st) }
    deriver
    -- TODO replace with safe specific ones, e.g. with_damage

-- | Not supposed to do this in general, but it's ok for tests.
modify_dynamic :: (Derive.Dynamic -> Derive.Dynamic) -> Derive.Deriver ()
modify_dynamic f = Derive.modify $ \st ->
    st { Derive.state_dynamic = f (Derive.state_dynamic st) }

-- * setup multiple

with_scale :: Scale.Scale -> Setup
with_scale scale = modify_constant $ \c ->
    c { Derive.state_lookup_scale = Derive.LookupScale lookup }
    where
    lookup env scale_id
        | scale_id == Scale.scale_id scale = Just (Right scale)
        -- Fall back on the old lookup.  This is important because *twelve is
        -- the default scale so I want it to keep working.
        | otherwise = deflt env scale_id
        where Derive.LookupScale deflt = default_lookup_scale

-- | Derive with a bit of a real instrument db.  Useful for testing instrument
-- calls.
with_synths :: UiConfig.Allocations -> [MidiInst.Synth] -> Setup
with_synths allocs synths = with_instrument_db allocs (synths_to_db synths)

with_synths_im :: SimpleAllocations -> [MidiInst.Synth] -> Setup
with_synths_im allocs synths =
    with_instrument_db (im_allocs allocs) db
    where db = synths_to_db synths

with_synths_simple :: SimpleAllocations -> [MidiInst.Synth] -> Setup
with_synths_simple allocs synths =
    with_instrument_db (simple_allocs allocs) db
    where db = synths_to_db synths

-- | Add a single instrument with a MIDI patch.
with_patch :: (MidiInst.Patch -> MidiInst.Patch) -> Text -> Setup
with_patch configure_patch name =
    with_synths_simple [(name, name <> "/")] [synth]
    where
    synth = UiTest.make_synth name [patch]
    patch = configure_patch $ MidiInst.make_patch $ UiTest.make_patch ""

with_instrument_db :: UiConfig.Allocations -> Cmd.InstrumentDb -> Setup
with_instrument_db allocs db = with_allocations allocs <> with_db
    where
    with_db = with_cmd $ set_cmd_config $ \state -> state
        { Cmd.config_instrument_db = db }

-- | A further-simplified version of 'Simple.Allocations' for tests:
-- [(Instrument, Qualified)]
type SimpleAllocations = [(Text, Text)]

simple_allocs :: SimpleAllocations -> UiConfig.Allocations
simple_allocs allocs = Simple.allocations
    [ (inst, (qual, Simple.Midi [(UiTest.wdev_name, chan)]))
    | (chan, (inst, qual)) <- zip [0..] allocs
    ]

im_allocs :: SimpleAllocations -> UiConfig.Allocations
im_allocs allocs =
    Simple.allocations [(inst, (qual, Simple.Im)) | (inst, qual) <- allocs]

lookup_qualified :: Cmd.InstrumentDb -> InstT.Qualified
    -> Maybe Cmd.Inst
lookup_qualified db qual = Inst.lookup qual db

with_allocations :: UiConfig.Allocations -> Setup
with_allocations allocs =
    with_ui $ Ui.config#UiConfig.allocations %= (allocs <>)

set_cmd_config :: (Cmd.Config -> Cmd.Config) -> Cmd.State -> Cmd.State
set_cmd_config f state = state { Cmd.state_config = f (Cmd.state_config state) }

-- ** defaults

default_cmd_state :: Cmd.State
default_cmd_state = Cmd.initial_state (cmd_config UiTest.default_db)

-- | Config to initialize the Cmd.State.
cmd_config :: Cmd.InstrumentDb -> Cmd.Config
cmd_config inst_db = Cmd.Config
    { config_app_dir = Path.AppDir "."
    , config_save_dir = Path.make_canonical "."
    , config_midi_interface = Unsafe.unsafePerformIO StubMidi.interface
    , config_ky_paths = []
    , config_rdev_map = mempty
    , config_wdev_map = mempty
    , config_instrument_db = inst_db
    , config_builtins = C.All.builtins
    , config_highlight_colors = Config.highlight_colors
    , config_im = Shared.Config.Config
        { imDir = Testing.tmp_base_dir </> "im"
        , synths = Map.fromList
            [ ("im-synth", Shared.Config.Synth
                { synthName = "test-synth"
                , binary = ""
                })
            ]
        }
    , config_git_user = SaveGitT.User "name" "email"
    , config_im_play_direct = False
    }

default_im_synth :: Inst.SynthDecl Cmd.InstrumentCode
default_im_synth = im_synth "im-synth"

im_synth :: InstT.SynthName -> Inst.SynthDecl Cmd.InstrumentCode
im_synth name = Inst.SynthDecl name name [(Patch.default_name, inst)]
    where
    inst = Inst.Inst
        { inst_backend = Inst.Im $ Im.Patch.patch
            { Im.Patch.patch_controls = Map.fromList
                [ (Control.pitch, "pitch doc")
                , (Control.dynamic, "dyn doc")
                ]
            }
        , inst_common = Common.common Cmd.empty_code
        }

default_lookup_scale :: Derive.LookupScale
default_lookup_scale = Cmd.lookup_scale

default_builtins :: Derive.Builtins
default_builtins = C.All.builtins

default_constant :: Ui.State -> Derive.Cache -> Derive.ScoreDamage
    -> Derive.Constant
default_constant ui_state cache damage = Derive.initial_constant ui_state
    default_builtins default_lookup_scale
        (const (Left "DeriveTest.default_constant has no inst db")) cache
        damage

default_dynamic :: Derive.Dynamic
default_dynamic = Derive.initial_dynamic default_environ

-- | This will replace Monad.initial_dynamic state_environ entirely.
default_environ :: Env.Environ
default_environ = Env.from_list
    -- tests are easier to write and read with integral interpolation
    [ (EnvKey.srate, DeriveT.num 1)
    , (EnvKey.scale, DeriveT.VStr (Expr.scale_id_to_str Twelve.scale_id))
    , (EnvKey.attributes, DeriveT.VAttributes mempty)
    ] <> Derive.initial_environ

-- *** instrument defaults

default_convert_lookup :: Lookup
default_convert_lookup =
    make_convert_lookup UiTest.default_allocations UiTest.default_db

synths_lookup_qualified :: [MidiInst.Synth] -> InstT.Qualified
    -> Maybe Cmd.Inst
synths_lookup_qualified synth = \qualified -> Inst.lookup qualified db
    where db = synths_to_db synth

synths_to_convert_lookup :: UiConfig.Allocations -> [MidiInst.Synth] -> Lookup
synths_to_convert_lookup allocs = make_convert_lookup allocs . synths_to_db

synths_to_db :: [MidiInst.Synth] -> Cmd.InstrumentDb
synths_to_db synths = trace_logs (map (Log.msg Log.Warn Nothing) warns) db
    where (db, warns) = Inst.db synths

type Lookup =
    (ScoreT.Instrument -> Maybe Cmd.ResolvedInstrument, Convert.MidiLookup)

-- | Make a Lookp for a single patch.
make_convert_lookup_for :: ScoreT.Instrument -> Patch.Config -> Patch.Patch
    -> Lookup
make_convert_lookup_for inst patch_config patch =
    make_convert_lookup allocs inst_db
    where
    allocs = UiConfig.midi_allocations
        [(inst, (InstT.Qualified "s" "1", patch_config))]
    inst_db = UiTest.make_db [("s", [patch { Patch.patch_name = "1" }])]

make_convert_lookup :: UiConfig.Allocations -> Cmd.InstrumentDb -> Lookup
make_convert_lookup allocs db =
    run_cmd (setup_ui setup Ui.empty) (setup_cmd setup default_cmd_state) $ do
        lookup_inst <- Cmd.get_lookup_instrument
        return (lookup_inst, PlayUtil.make_midi_lookup lookup_inst)
    where setup = with_instrument_db allocs db

-- ** extract

-- *** log msgs

trace_logs :: [Log.Msg] -> a -> a
trace_logs = trace_all_logs . filter interesting_log

-- | Write log msgs with 'Debug.trace_str', for debugging.
trace_all_logs :: [Log.Msg] -> a -> a
trace_all_logs logs val
    | null logs = val
    | otherwise = Debug.trace_str
        (Text.stripEnd $ Text.unlines $ "\tlogged:" : map Log.format_msg logs)
        val

-- | Filter out low-priority logs and trace them.
trace_low_prio :: [Log.Msg] -> [Log.Msg]
trace_low_prio msgs = trace_all_logs low high
    where (high, low) = List.partition interesting_log msgs

-- | Tests generally shouldn't depend on logs below a certain priority since
-- those don't indicate anything interesting.
interesting_log :: Log.Msg -> Bool
interesting_log = (>=Log.Warn) . Log.msg_priority

quiet_filter_logs :: [Log.Msg] -> [Log.Msg]
quiet_filter_logs = filter ((>=Log.Warn) . Log.msg_priority)

-- ** extract

extract :: (Score.Event -> a) -> Derive.Result -> ([a], [Text])
extract e_event = extract_levents e_event . Stream.to_list . Derive.r_events

filter_events :: (Score.Event -> Bool) -> Derive.Result -> Derive.Result
filter_events f result =
    result { Derive.r_events = filt (Derive.r_events result) }
    where
    filt = Stream.from_sorted_list . filter (LEvent.log_or f) . Stream.to_list

filter_events_range :: RealTime -> RealTime -> Derive.Result -> Derive.Result
filter_events_range start end = filter_events $ \e ->
    start <= Score.event_start e && Score.event_start e < end

extract_events :: (Score.Event -> a) -> Derive.Result -> [a]
extract_events e_event result = trace_all_logs logs (map e_event events)
    where (events, logs) = r_split result

extract_levents :: (a -> b) -> [LEvent.LEvent a] -> ([b], [Text])
extract_levents e_event = bimap (map e_event) (map show_log) . extract_logs

extract_logs :: [LEvent.LEvent a] -> ([a], [Log.Msg])
extract_logs = second (filter interesting_log) . LEvent.partition

extract_stream :: (Score.Event -> a) -> Derive.Result -> [Either a Text]
extract_stream e_event = mapMaybe extract . Stream.to_list . Derive.r_events
    where
    extract (LEvent.Log log)
        | interesting_log log = Just $ Right $ show_log log
        | otherwise = Nothing
    extract (LEvent.Event e) = Just $ Left $ e_event e

r_split :: Derive.Result -> ([Score.Event], [Log.Msg])
r_split = second (filter interesting_log) . Stream.partition . Derive.r_events

r_logs :: Derive.Result -> [Log.Msg]
r_logs = snd . r_split

stack_to_ui :: Stack.Stack -> [Text]
stack_to_ui = map Stack.unparse_ui_frame . Stack.to_ui

r_log_strings :: Derive.Result -> [Text]
r_log_strings = snd . extract id

e_event :: Score.Event -> (RealTime, RealTime, Text)
e_event e = (Score.event_start e, Score.event_duration e, Score.event_text e)

e_start_dur :: Score.Event -> (RealTime, RealTime)
e_start_dur e = (Score.event_start e, Score.event_duration e)

e_instrument :: Score.Event -> Text
e_instrument = ScoreT.instrument_name . Score.event_instrument

e_control :: ScoreT.Control -> Score.Event -> [(RealTime, Signal.Y)]
e_control control = Lists.dropDups id
    . maybe [] (Signal.to_pairs . ScoreT.typed_val)
    . Score.event_control control

e_controls :: Score.Event -> [(ScoreT.Control, [(Signal.X, Signal.Y)])]
e_controls = map (second (Signal.to_pairs . ScoreT.typed_val)) . Map.toList
    . Score.event_controls

lookup_control :: ScoreT.Control -> Derive.Dynamic -> Maybe DeriveT.TypedSignal
lookup_control (ScoreT.Control c) =
    to_signal <=< Env.lookup c . Derive.state_environ
    where
    to_signal val = case Typecheck.val_to_signal val of
        Just (Right sig) -> Just sig
        _ -> Nothing

e_control_vals :: ScoreT.Control -> Score.Event -> [Signal.Y]
e_control_vals control = map snd . Lists.dropInitialDups fst . e_control control

e_control_constant :: ScoreT.Control -> Score.Event -> Maybe Signal.Y
e_control_constant control = Signal.constant_val . ScoreT.typed_val
    <=< Map.lookup control . Score.event_controls

e_initial_control :: ScoreT.Control -> Score.Event -> Maybe Signal.Y
e_initial_control control event = ScoreT.typed_val <$>
    Score.control_at (Score.event_start event) control event

e_dyn :: Score.Event -> [(RealTime, Signal.Y)]
e_dyn = Lists.dropDups id . e_control Controls.dynamic

e_dyn_rounded :: Score.Event -> [(RealTime, Signal.Y)]
e_dyn_rounded = Lists.dropDups id . map (second (Num.roundDigits 2))
    . e_control Controls.dynamic

-- | Like 'e_nns', but drop discontinuities.
--
-- TODO don't use this for new tests, this is just left over from pre-linear
-- segments so I don't have to update a million tests.
e_nns_old :: CallStack.Stack => Score.Event -> [(RealTime, Pitch.NoteNumber)]
e_nns_old e
    | not (null errs) = error $ "errors flattening signal: " <> show errs
    | otherwise = Lists.dropDups snd $ Lists.dropInitialDups fst sig
    where (sig, errs) = e_nns_errors e

-- | Like 'e_nns_errors', but throw an exception if there are errors.
e_nns :: CallStack.Stack => Score.Event -> [(RealTime, Pitch.NoteNumber)]
e_nns e
    | not (null errs) = error $ "errors flattening signal: " <> show errs
    | otherwise = Lists.dropDups id sig
    where (sig, errs) = e_nns_errors e

-- | Like 'e_nns', but round to cents to make comparison easier.
e_nns_rounded :: Score.Event -> [(RealTime, Pitch.NoteNumber)]
e_nns_rounded = map (second (Num.roundDigits 2)) . e_nns

e_nn_rounded :: Score.Event -> Pitch.NoteNumber
e_nn_rounded = maybe 0 (Num.roundDigits 2) . Score.initial_nn

-- | Extract pitch signal and any errors flattening it.
e_nns_errors :: Score.Event -> ([(RealTime, Pitch.NoteNumber)], [Text])
e_nns_errors =
    bimap (map (second Pitch.nn) . Signal.to_pairs) (map pretty)
    . PSignal.to_nn . Score.event_pitch . Score.normalize

flat_segments :: [(x, y)] -> [(x, y)]
flat_segments = concatMap make . Lists.zipNext
    where
    make ((x0, y), Just (x1, _)) = [(x0, y), (x1, y)]
    make (xy, Nothing) = [xy]

e_pitch :: Score.Event -> Text
e_pitch e = maybe "?" Pitch.note_text (Score.initial_note e)

-- | (start, dur, pitch), the melodic essentials of a note.
e_note :: Score.Event -> (RealTime, RealTime, Text)
e_note e = (Score.event_start e, Score.event_duration e, e_pitch e)

e_start_note :: Score.Event -> (RealTime, Text)
e_start_note e = (Score.event_start e, e_pitch e)

e_attributes :: Score.Event -> Text
e_attributes = ShowVal.show_val . Score.event_attributes

e_environ :: Env.Key -> Score.Event -> Maybe Text
e_environ name = fmap ShowVal.show_val . Env.lookup name . Score.event_environ

e_environ_like :: (Text -> Bool) -> Score.Event -> [(Env.Key, Text)]
e_environ_like f event =
    [ (k, ShowVal.show_val v)
    | (k, v) <- Env.to_list (Score.event_environ event), f k
    ]

e_environ_val :: Typecheck.Typecheck a => Env.Key -> Score.Event -> Maybe a
e_environ_val name = Env.maybe_val name . Score.event_environ

e_tsigs :: Derive.Result -> [((BlockId, TrackId), [(Signal.X, Signal.Y)])]
e_tsigs =
    filter (not . null . snd) . Map.toList . Map.map tsig
        . Derive.r_track_signals
    where tsig t = Signal.to_pairs $ Track.ts_signal t

e_tsig_logs :: Derive.Result -> [Text]
e_tsig_logs = filter ("Track signal: " `Text.isPrefixOf`) . map show_log
    . Stream.logs_of . Derive.r_events

-- ** extract log msgs

show_log_stack :: Log.Msg -> Text
show_log_stack msg = show_stack (Log.msg_stack msg) <> ": " <> show_log msg

-- | Show an abbreviated stack from the log.  This is meant to be similar to
-- how LogView does it, so that in tests I get an accurate idea of the actual
-- error.
show_stack :: Maybe Stack.Stack -> Text
show_stack =  show_stack_ True

show_stack_ :: Bool -> Maybe Stack.Stack -> Text
show_stack_ _ Nothing = ""
show_stack_ with_call (Just stack)
    | null ui = "<no stack>"
    -- This uses ': ' so 'x: *' works regardless of where in the stack x is.
    | otherwise = Text.intercalate ": " (map Stack.unparse_ui_frame_ ui)
        <> maybe "" (": "<>) (last_call stack)
    where
    ui = Stack.to_ui stack
    last_call
        | with_call = fmap (\c -> if Text.null c then "''" else c) . Lists.head
            . mapMaybe Stack.call_of . Stack.innermost
        | otherwise = const Nothing

show_log :: Log.Msg -> Text
show_log = Log.msg_text

show_interesting_log :: Log.Msg -> Maybe Text
show_interesting_log msg
    | interesting_log msg = Just (Log.msg_text msg)
    | otherwise = Nothing

-- ** extract midi msgs

note_on_vel :: [Midi.WriteMessage] -> [(Integer, Midi.Key, Midi.Velocity)]
note_on_vel msgs =
    [ (ts, nn, vel)
    | (ts, Midi.ChannelMessage _ (Midi.NoteOn nn vel)) <- extract_midi msgs
    ]

note_on :: [Midi.WriteMessage] -> [Midi.Key]
note_on msgs = [nn | (_, nn, _) <- note_on_vel msgs]

note_on_cc :: [Midi.WriteMessage]
    -> [Either Midi.Key (Midi.Control, Midi.ControlValue)]
note_on_cc = mapMaybe (extract . snd) . extract_midi
    where
    extract (Midi.ChannelMessage _ (Midi.NoteOn nn _)) = Just $ Left nn
    extract (Midi.ChannelMessage _ (Midi.ControlChange cc val)) =
        Just $ Right (cc, val)
    extract _ = Nothing

midi_channel :: [Midi.WriteMessage] -> [(Midi.Channel, Midi.ChannelMessage)]
midi_channel midi =
    [ (chan, msg)
    | Midi.ChannelMessage chan msg <- map Midi.wmsg_msg (interesting_midi midi)
    ]

extract_midi :: [Midi.WriteMessage] -> [(Integer, Midi.Message)]
extract_midi midi =
    [ (RealTime.to_milliseconds ts, msg)
    | Midi.WriteMessage _ ts msg <- interesting_midi midi
    ]

extract_midi_msg :: [Midi.WriteMessage] -> [Midi.Message]
extract_midi_msg = map snd . extract_midi

-- | Filter out boring msgs that I don't want tests to rely on.
interesting_midi :: [Midi.WriteMessage] -> [Midi.WriteMessage]
interesting_midi = filter $ \wmsg -> case Midi.wmsg_msg wmsg of
    Midi.ChannelMessage _ (Midi.PitchBend 0) -> False
    _ -> True

-- ** ui state

e_state :: Derive.Result -> Ui.State
e_state = Derive.state_ui . Derive.state_constant . Derive.r_state

-- * call

passed_args :: Derive.CallName -> [DeriveT.Val] -> Derive.PassedArgs derived
passed_args name vals = Derive.PassedArgs
    { Derive.passed_vals = vals
    , Derive.passed_call_name = name
    , Derive.passed_ctx = Derive.dummy_context 0 1 "DeriveTest"
    }

c_note :: ScoreTime -> ScoreTime -> Derive.NoteDeriver
c_note s_start dur = do
    start <- Derive.real s_start
    end <- Derive.real (s_start + dur)
    inst <- Derive.get_val EnvKey.instrument
    environ <- Derive.get_environ
    st <- Derive.gets Derive.state_dynamic
    cmap <- Derive.get_control_map
    return $! Stream.from_event $! Score.empty_event
        { Score.event_start = start
        , Score.event_duration = end - start
        , Score.event_text = "evt"
        , Score.event_pitch = Derive.state_pitch st
        , Score.event_instrument = inst
        , Score.event_environ = environ <> Env.from_controls cmap
        }

-- * scale

mkscale :: Pitch.ScaleId -> [(Text, Pitch.NoteNumber)] -> Scale.Scale
mkscale scale_id notes =
    Scales.make_scale scale_id dmap "pattern" "simple test scale"
    where
    dmap = Scales.degree_map 8 0 0 (map (Pitch.Note . fst) notes)
        (map snd notes)

-- * mkevents

-- | (start, dur, pitch12, controls, inst)
type EventSpec = (RealTime, RealTime, Text, Controls, ScoreT.Instrument)
type Controls = [(ScoreT.Control, [(RealTime, Signal.Y)])]
type ControlVals = [(ScoreT.Control, Signal.Y)]

mkevent :: CallStack.Stack => EventSpec -> Score.Event
mkevent = mkevent_scale Twelve.scale

-- | Make an event with a non-twelve scale.
mkevent_scale :: CallStack.Stack => Scale.Scale -> EventSpec -> Score.Event
mkevent_scale scale = mkevent_scale_key scale Nothing

mkevent_scale_key :: CallStack.Stack => Scale.Scale -> Maybe Text
    -> EventSpec -> Score.Event
mkevent_scale_key scale key (start, dur, pitch, controls, inst) =
    maybe id (\k -> Score.modify_environ (Env.insert_val EnvKey.key k)) key $
    Score.empty_event
        { Score.event_start = start
        , Score.event_duration = dur
        , Score.event_text = ""
        , Score.event_environ = Env.from_controls $ mkcontrols controls
        , Score.event_pitch = PSignal.from_sample start (mkpitch scale pitch)
        , Score.event_stack = fake_stack
        , Score.event_instrument = inst
        }

psignal :: [(RealTime, Text)] -> PSignal.PSignal
psignal = PSignal.from_pairs . map (second mkpitch12)

mkcontrols :: Controls -> DeriveT.ControlMap
mkcontrols cs = Map.fromList
    [(c, ScoreT.untyped (Signal.from_pairs sig)) | (c, sig) <- cs]

mkcontrols_const :: ControlVals -> DeriveT.ControlMap
mkcontrols_const cs = mkcontrols [(c, [(0, val)]) | (c, val) <- cs]

mkpitch12 :: Text -> PSignal.Pitch
mkpitch12 = mkpitch Twelve.scale

mkpitch :: CallStack.Stack => Scale.Scale -> Text -> PSignal.Pitch
mkpitch scale p = case eval Ui.empty deriver of
    Left err -> error $ "mkpitch " <> show p <> ": " <> untxt err
    Right pitch -> pitch
    where
    deriver = Derive.with_scale scale $
        Eval.eval_pitch 0 $ Expr.call0 (Expr.Symbol p)

default_scale :: Scale.Scale
default_scale = Twelve.scale

fake_stack :: Stack.Stack
fake_stack = Stack.from_outermost
    [ Stack.Block (UiTest.bid "fakeblock")
    , Stack.Track (UiTest.tid "faketrack")
    , Stack.Region 42 43
    ]

-- * create misc

make_damage :: Text -> TrackNum -> ScoreTime -> ScoreTime
    -> Derive.ScoreDamage
make_damage block tracknum s e = Derive.ScoreDamage
    (Map.singleton (UiTest.mk_tid_name block tracknum) (Ranges.range s e))
    (Set.singleton (UiTest.bid block)) mempty
