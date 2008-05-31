{- | Convert from the Derive events to MIDI performer specific events.

Since this module depends on both the Derive and Perform.Midi layers, it should
be called from Derive or Cmd, not Perform.Midi, even though it's physically
located in Perform.Midi.
-}
module Perform.Midi.Convert where
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set

import qualified Util.Seq as Seq

import qualified Derive.Score as Score

import qualified Perform.Timestamp as Timestamp
import qualified Perform.Warning as Warning
import qualified Perform.Midi.Controller as Controller
import qualified Perform.Midi.Perform as Perform
import qualified Perform.Midi.Instrument as Instrument
import qualified Perform.Midi.InstrumentDb as InstrumentDb


-- | Events that don't have enough info to be converted to MIDI Events will be
-- returned as Warnings.
convert :: [Score.Event] -> ([Perform.Event], [Warning.Warning])
convert events = (Maybe.catMaybes midi_events, concat warns)
    where (warns, midi_events) = unzip (map convert_event events)

verify :: Instrument.Config -> [Perform.Event] -> [String]
verify config events =
    (map show . unique . Maybe.catMaybes . map (verify_event allocated)) events
    where allocated = Set.fromList (Map.elems (Instrument.config_alloc config))

unique = Set.toList . Set.fromList

verify_event allocated event
    | inst `Set.notMember` allocated = Just (Instrument.inst_name inst)
    | otherwise = Nothing
    where
    inst = Perform.event_instrument event

convert_event event = case do_convert_event event of
    Left warn -> ([warn], Nothing)
    Right (warns, evt) -> (warns, Just evt)

do_convert_event :: Score.Event
    -> Either Warning.Warning ([Warning.Warning], Perform.Event)
do_convert_event event = do
    let req = require event
    inst <- req "instrument" (Score.event_instrument event)
    midi_inst <- req ("midi instrument in instrument db: " ++ show inst)
        (InstrumentDb.lookup inst)
    pitch <- req "pitch" (Score.event_pitch event)
    let (cwarns, controls) = convert_controls (Score.event_controls event)
        controller_warns = map
            (\w -> w { Warning.warn_event = Score.event_stack event })
            cwarns
        start = Timestamp.from_track_pos (Score.event_start event)
        dur = Timestamp.from_track_pos (Score.event_duration event)
    return (controller_warns,
        Perform.Event midi_inst start dur pitch controls
            (Score.event_stack event))

convert_controls controls = (warns, Map.fromList ok)
    where
    (warns, ok) = Seq.partition_either
        (map convert_control (Map.assocs controls))

convert_control (Score.Controller c, sig)  = case Controller.controller c of
    Nothing -> Left $
        Warning.warning ("unknown controller: " ++ show c) [] Nothing
    Just cont -> Right (cont, sig)

require event msg Nothing = Left $
    Warning.warning ("event requires " ++ msg) (Score.event_stack event)
        Nothing
require _event _msg (Just x) = Right x
