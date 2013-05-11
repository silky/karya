{- | Instrument DB, for converting Score.Instruments, which are just names, to
    the detailed instrument in whatever backend.

    Technically this module is supposed to be backend-independent, while
    MidiDb is specific to MIDI, but since there's only MIDI at the moment
    it doesn't matter much.

    TODO
    - Midi instruments are probably tangled with non-midi instruments, but
    I can figure that out when I have non-midi instruments.
-}
module Instrument.Db where
import qualified Data.Map as Map

import Util.Control
import qualified Midi.Midi as Midi
import qualified Derive.Score as Score
import qualified Perform.Midi.Instrument as Instrument
import qualified Instrument.MidiDb as MidiDb


-- | Static config type for the instrument db.
data Db code = Db {
    -- | Specialized version of db_lookup that returns a Midi instrument.
    db_lookup_midi :: MidiDb.LookupMidiInstrument
    -- | Lookup a score instrument.
    , db_lookup :: Score.Instrument -> Maybe (MidiDb.Info code)

    -- | Internal use.  It's probably not necessary to expose this, but it can
    -- be handy for testing.
    , db_midi_db :: MidiDb.MidiDb code
    }

empty :: Db code
empty = Db {
    db_lookup_midi = \_ _ -> Nothing
    , db_lookup = const Nothing
    , db_midi_db = MidiDb.empty
    }

-- | So Cmd.State can be showable, for debugging.
instance Show (Db code) where
    show _ = "((InstrumentDb))"

type MakeInitialize = Midi.Channel -> Instrument.InitializePatch

db :: MidiDb.MidiDb code -> Db code
db midi_db = Db
    { db_lookup_midi = MidiDb.lookup_midi midi_db
    , db_lookup = MidiDb.lookup_instrument midi_db
    , db_midi_db = midi_db
    }

-- | Number of entries in the db.
size :: Db code -> Int
size db = MidiDb.size (db_midi_db db)

-- | All the synths in the db.
synths :: Db code -> [Instrument.SynthName]
synths = Map.keys . MidiDb.midi_db_map . db_midi_db

-- | Add alias instrument names to the db.  This is used to create
-- score-specific names for instruments, and to instantiate a single instrument
-- multiple times.
with_aliases :: Map.Map Score.Instrument Score.Instrument -> Db code -> Db code
with_aliases aliases (Db midi lookup midi_db) = Db
    { db_lookup_midi = \attrs inst ->
        set_inst inst <$> midi attrs (resolve inst)
    , db_lookup = \inst -> set_info inst <$> lookup (resolve inst)
    , db_midi_db = midi_db
    }
    where
    set_inst alias (inst, attrs) = (set_name alias inst, attrs)
    set_info alias info = info
        { MidiDb.info_patch = Instrument.instrument_ %= set_name alias $
            MidiDb.info_patch info
        }
    resolve inst = Map.findWithDefault inst inst aliases

set_name :: Score.Instrument -> Instrument.Instrument -> Instrument.Instrument
set_name to inst = inst
    { Instrument.inst_name = snd (Score.split_inst to)
    , Instrument.inst_score = to
    }

