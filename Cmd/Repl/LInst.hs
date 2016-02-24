-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE NoMonomorphismRestriction #-}
-- | REPL Cmds dealing with instruments and MIDI config.
module Cmd.Repl.LInst where
import Prelude hiding (lookup)
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text

import qualified Util.Log as Log
import qualified Util.Seq as Seq
import qualified Midi.Interface as Interface
import qualified Midi.Midi as Midi
import qualified Ui.State as State
import qualified Ui.StateConfig as StateConfig
import qualified Ui.TrackTree as TrackTree

import qualified Cmd.Cmd as Cmd
import qualified Cmd.Info as Info
import qualified Cmd.Repl.Util as Util
import qualified Cmd.Save as Save
import qualified Cmd.Selection as Selection

import qualified Derive.Env as Env
import qualified Derive.ParseTitle as ParseTitle
import qualified Derive.RestrictedEnviron as RestrictedEnviron
import qualified Derive.Score as Score
import qualified Derive.ShowVal as ShowVal

import qualified Perform.Midi.Patch as Patch
import qualified Perform.Pitch as Pitch
import qualified Perform.Signal as Signal

import qualified Instrument.InstTypes as InstTypes
import Global
import Types


lookup :: Instrument -> Cmd.CmdL (Maybe Cmd.Inst)
lookup = Cmd.lookup_instrument . Util.instrument

-- * config

-- | Print out instrument configs all purty-like.
list :: State.M m => m Text
list = list_like ""

-- | Pretty print matching instruments:
--
-- > >pno - pianoteq/ loop1 [0..15]
-- > >syn - sampler/inst
list_like :: State.M m => Text -> m Text
list_like pattern = do
    alloc_map <- State.config#State.allocations_map <#> State.get
    return $ Text.intercalate "\n" $
        map show_alloc $ filter (matches . fst) $
        Map.toAscList alloc_map
    where
    matches inst = pattern `Text.isInfixOf` Score.instrument_name inst
    show_alloc (inst, (qualified, alloc)) = Text.unwords
        [ ShowVal.show_val inst
        , "-"
        , InstTypes.show_qualified qualified
        , case alloc of
            StateConfig.Midi config -> show_config config
            StateConfig.Im -> "音"
            StateConfig.Dummy -> "(dummy instrument)"
        ]
    show_config config = mconcat
        [ Info.show_addrs (map fst (Patch.config_addrs config))
        , show_environ (Patch.config_restricted_environ config)
        , show_controls "" (Patch.config_controls config)
        , show_flags config
        , show_controls "defaults:" (Patch.config_control_defaults config)
        ]
    show_controls msg controls
        | Map.null controls = ""
        | otherwise = " " <> msg <> pretty controls
    show_environ environ
        | environ == mempty = ""
        | otherwise = " " <> pretty environ
    show_flags config
        | null flags = ""
        | otherwise = " {" <> Text.intercalate ", " flags <> "}"
        where
        flags = ["mute" | Patch.config_mute config]
            ++ ["solo" | Patch.config_solo config]

-- | Instrument allocations.
allocations :: State.M m => m StateConfig.Allocations
allocations = State.config#State.allocations <#> State.get

-- | Rename an instrument.
rename :: State.M m => Instrument -> Instrument -> m ()
rename from to = do
    alloc <- State.require ("not found: " <> pretty from)
        =<< (State.allocation (Util.instrument from) <#> State.get)
    State.modify_config $ State.allocations %= rename alloc
    where
    rename alloc (StateConfig.Allocations allocs) = StateConfig.Allocations $
        Map.insert (Util.instrument to) alloc $
        Map.delete (Util.instrument from) allocs

-- | Allocate a new MIDI instrument.  For instance:
--
-- > LInst.add \"m\" \"kontakt/mridangam-g\" \"loop1\" [0]
--
-- This will create an instance of the @kontakt/mridangam@ instrument named
-- @>m@, and assign it to the MIDI WriteDevice @loop1@, with a single MIDI
-- channel 0 allocated.
add :: Instrument -> Qualified -> Text -> [Midi.Channel] -> Cmd.CmdL ()
add inst qualified wdev chans =
    add_config inst qualified (Patch.config (map (dev,) chans))
    where dev = Midi.write_device wdev

-- | Allocate the given channels for the instrument using its default device.
add_default :: Instrument -> Qualified -> [Midi.Channel] -> Cmd.CmdL ()
add_default inst qualified chans = do
    wdev <- device_of (Util.instrument inst)
    add_config inst qualified (Patch.config (map (wdev,) chans))

add_config :: Instrument -> Qualified -> Patch.Config -> Cmd.CmdL ()
add_config inst qualified config = do
    qualified <- parse_qualified qualified
    allocate (Util.instrument inst) qualified (StateConfig.Midi config)

-- | Allocate a new Im instrument.
add_im :: Instrument -> Qualified -> Cmd.CmdL ()
add_im inst qualified = do
    qualified <- parse_qualified qualified
    allocate (Util.instrument inst) qualified StateConfig.Im

save :: FilePath -> Cmd.CmdL ()
save = Save.save_allocations

load :: FilePath -> Cmd.CmdL ()
load = Save.load_allocations

-- | Create a dummy instrument .  This is used for instruments which are
-- expected to be converted into other instruments during derivation.  For
-- instance, pasang instruments are stand-ins for polos sangsih pairs.
add_dummy :: Instrument -> Instrument -> Cmd.CmdL ()
add_dummy inst qualified = do
    qualified <- parse_qualified qualified
    allocate (Util.instrument inst) qualified StateConfig.Dummy

-- | Remove an instrument allocation.
remove :: Instrument -> Cmd.CmdL ()
remove = deallocate . Util.instrument

-- | All allocations should go through this to verify their validity, unless
-- it's modifying an existing allocation and not changing the Qualified name.
allocate :: Cmd.M m => Score.Instrument -> InstTypes.Qualified
    -> StateConfig.Allocation -> m ()
allocate inst qualified alloc = do
    lookup_inst <- Cmd.gets Cmd.state_lookup_qualified
    allocs <- State.config#State.allocations <#> State.get
    allocs <- Cmd.require_right id $
        StateConfig.allocate lookup_inst inst qualified alloc allocs
    State.modify_config $ State.allocations #= allocs

deallocate :: Cmd.M m => Score.Instrument -> m ()
deallocate inst = State.modify_config $ State.allocations_map %= Map.delete inst

-- | Toggle and return the new value.
toggle_mute :: State.M m => Instrument -> m Bool
toggle_mute inst = modify_midi inst $ \config ->
    let mute = not $ Patch.config_mute config
    in (config { Patch.config_mute = mute }, mute)

-- | Toggle and return the new value.
toggle_solo :: State.M m => Instrument -> m Bool
toggle_solo inst = modify_midi inst $ \config ->
    let solo = not $ Patch.config_solo config
    in (config { Patch.config_solo = solo }, solo)

-- | Add an environ val to the instrument config.
add_environ :: (RestrictedEnviron.ToVal a, State.M m) =>
    Instrument -> Env.Key -> a -> m ()
add_environ inst name val = modify_midi_ inst $ Patch.add_environ name val

-- | Clear the instrument config's environ.  The instrument's built-in environ
-- from 'Patch.patch_environ' is still present.
clear_environ :: State.M m => Instrument -> m ()
clear_environ inst = modify_midi_ inst $ Patch.environ #= mempty

set_controls :: State.M m => Instrument -> [(Score.Control, Signal.Y)] -> m ()
set_controls inst controls = modify_midi_ inst $
    Patch.controls #= Map.fromList controls

set_scale :: State.M m => Instrument -> Patch.Scale -> m ()
set_scale inst scale = modify_midi_ inst $ Patch.cscale #= Just scale

set_control_defaults :: State.M m => Instrument -> [(Score.Control, Signal.Y)]
    -> m ()
set_control_defaults inst controls = modify_midi_ inst $
    Patch.control_defaults #= Map.fromList controls

get_midi_config :: State.M m => Score.Instrument
    -> m (InstTypes.Qualified, Patch.Config)
get_midi_config inst = do
    (qualified, alloc) <- State.require ("no config for " <> pretty inst)
        =<< State.allocation inst <#> State.get
    case alloc of
        StateConfig.Midi config -> return (qualified, config)
        _ -> State.throw $ "not a midi instrument: " <> pretty inst <> ": "
            <> pretty alloc

modify_midi :: State.M m => Instrument -> (Patch.Config -> (Patch.Config, a))
    -> m a
modify_midi inst_ modify = do
    let inst = Util.instrument inst_
    (qualified, config) <- get_midi_config inst
    let (new, result) = modify config
    State.modify_config $ State.allocations_map
        %= Map.insert inst (qualified, StateConfig.Midi new)
    return result

modify_midi_ :: State.M m => Instrument -> (Patch.Config -> Patch.Config)
    -> m ()
modify_midi_ inst modify = modify_midi inst (\c -> (modify c, ()))

-- | Merge the given configs into the existing one.
merge :: Cmd.M m => StateConfig.Allocations -> m ()
merge allocations@(StateConfig.Allocations allocs) = do
    lookup_inst <- Cmd.gets Cmd.state_lookup_qualified
    let errors = Maybe.catMaybes
            [ StateConfig.verify_allocation lookup_inst inst qual alloc
            | (inst, (qual, alloc)) <- Map.toList allocs
            ]
    unless (null errors) $
        Cmd.throw $ "merged allocations: " <> Text.intercalate "; " errors
    State.modify_config $ State.allocations %= (allocations<>)


-- * change_instrument

-- | Replace the instrument in the current track with the given one, and
-- 'initialize' it.  This is intended for hardware synths which need a program
-- change or sysex, and can be invoked via "Instrument.Browser".
change_instrument :: Qualified -> Cmd.CmdL ()
change_instrument new_qualified = do
    new_qualified <- parse_qualified new_qualified
    let new_inst = case new_qualified of
            InstTypes.Qualified _ name -> Score.instrument name
    track_id <- Cmd.require "must select an event track"
        =<< snd <$> Selection.track
    old_inst <- Cmd.require "must select an event track"
        =<< ParseTitle.title_to_instrument <$> State.get_track_title track_id
    (_, config) <- get_midi_config old_inst
    -- Replace the old instrument and reuse its addr.
    deallocate old_inst
    allocate new_inst new_qualified (StateConfig.Midi config)
    (wdev, chan) <- case Patch.config_addrs config of
        (addr, _) : _ -> return addr
        _ -> Cmd.throw $ "inst has no addr allocation: " <> pretty old_inst
    State.set_track_title track_id (ParseTitle.instrument_to_title new_inst)
    initialize new_inst wdev chan
    return ()

initialize :: Score.Instrument -> Midi.WriteDevice -> Midi.Channel
    -> Cmd.CmdL ()
initialize inst wdev chan = do
    patch <- Cmd.get_midi_patch inst
    send_initialize (Patch.patch_initialize patch) inst wdev chan

send_initialize :: Patch.InitializePatch -> Score.Instrument
    -> Midi.WriteDevice -> Midi.Channel -> Cmd.CmdL ()
send_initialize init inst dev chan = case init of
    Patch.InitializeMidi msgs -> do
        Log.notice $ "sending midi init: " <> pretty msgs
        mapM_ (Cmd.midi dev . Midi.set_channel chan) msgs
    Patch.InitializeMessage msg ->
        -- Warn doesn't seem quite right for this, but the whole point is to
        -- show this message, so it should be emphasized.
        Log.warn $ "initialize instrument " <> showt inst <> ": " <> msg
    Patch.NoInitialization -> return ()

block_instruments :: BlockId -> Cmd.CmdL [Score.Instrument]
block_instruments block_id = do
    titles <- fmap (map State.track_title) (TrackTree.tracks_of block_id)
    return $ mapMaybe ParseTitle.title_to_instrument titles

-- | Synths default to writing to a device with their name.  You'll have to
-- map it to a real hardware WriteDevice in the 'Cmd.Cmd.write_device_map'.
device_of :: Score.Instrument -> Cmd.CmdL Midi.WriteDevice
device_of inst = do
    InstTypes.Qualified synth _ <-
        Cmd.require ("no instrument: " <> pretty inst)
            =<< Cmd.lookup_qualified inst
    return $ Midi.write_device synth


-- * tuning

-- | Set the instrument's Scale to the given scale and send a MIDI tuning
-- message to retune the synth.  Very few synths support this.
retune :: Cmd.M m => Instrument -> Patch.Scale -> m ()
retune inst scale = do
    set_scale inst scale
    devs <- map (fst . fst) . Patch.config_addrs . snd <$>
        get_midi_config (Util.instrument inst)
    let msg = Midi.realtime_tuning $ map (second Pitch.nn_to_double) $
            Patch.scale_keys scale
    mapM_ (flip Cmd.midi msg) (Seq.unique devs)

-- * midi interface

-- | Every read device on the system, along with any aliases it may have.
read_devices :: Cmd.CmdL [(Midi.ReadDevice, [Midi.ReadDevice])]
read_devices = run_interface Interface.read_devices

-- | Every write device on the system, along with any aliases it may have.
write_devices :: Cmd.CmdL [(Midi.WriteDevice, [Midi.WriteDevice])]
write_devices = run_interface Interface.write_devices

connect_read_device :: Midi.ReadDevice -> Cmd.CmdL Bool
connect_read_device rdev =
    run_interface (flip Interface.connect_read_device rdev)

disconnect_read_device :: Midi.ReadDevice -> Cmd.CmdL Bool
disconnect_read_device rdev =
    run_interface (flip Interface.disconnect_read_device rdev)

run_interface :: (Interface.Interface -> IO a) -> Cmd.CmdL a
run_interface op = do
    interface <- Cmd.gets (Cmd.config_midi_interface . Cmd.state_config)
    liftIO (op interface)


-- * misc

-- | Send a CC MIDI message on the given device.  This is for synths that use
-- MIDI learn.
teach :: Text -> Midi.Channel -> Midi.Control -> Cmd.CmdL ()
teach dev chan cc = Cmd.midi (Midi.write_device dev) $
    Midi.ChannelMessage chan (Midi.ControlChange cc 1)

type Instrument = Text
-- | This is parsed into a 'Inst.Qualified'.
type Qualified = Text

parse_qualified :: Cmd.M m => Qualified -> m InstTypes.Qualified
parse_qualified text
    | "/" `Text.isInfixOf` text = return $ InstTypes.parse_qualified text
    | otherwise =
        Cmd.throw $ "qualified inst name lacks a /: " <> showt text
