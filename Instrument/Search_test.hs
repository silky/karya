-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Instrument.Search_test where
import qualified Data.Map as Map

import Util.Test
import qualified Midi.Midi as Midi
import qualified Cmd.Cmd as Cmd
import qualified Cmd.Instrument.MidiInst as MidiInst
import qualified Derive.ScoreTypes as ScoreTypes
import qualified Perform.Midi.Instrument as Instrument
import qualified Instrument.Common as Common
import qualified Instrument.Inst as Inst
import qualified Instrument.Search as Search
import qualified Instrument.Tag as Tag

import Global


test_search = do
    let f = map Inst.show_qualified . Search.search index . Search.parse
    equal (f "") t_all_insts
    equal (f "synth=") t_all_insts
    equal (f "category=key control=comb") ["z1/comb-clav"]
    equal (f "category=key control=") ["z1/comb-clav", "z1/pulse-clav"]
    equal (f "name=delg name=comb") []
    equal (f "synth=fm8") ["fm8/"]
    equal (f "!synth=z1") ["fm8/"]
    equal (f "!category=epiano !category=synth")
        ["fm8/", "z1/comb-clav", "z1/pulse-clav"]
    equal (f "!category=epiano !category=synth name=clav")
        ["z1/comb-clav", "z1/pulse-clav"]

index :: Search.Index
index = Search.make_index db

db :: Cmd.InstrumentDb
db = make_db [("fm8", fm8_patches), ("z1", z1_patches)]

t_all_insts :: [Text]
t_all_insts =
    map Inst.show_qualified (Map.keys (Search.idx_instrument_tags index))

z1_patches :: [(Instrument.Patch, Text)]
z1_patches =
    [ (mkpatch "mr-delgado" [(14, "delgado")], "synth-lead")
    , (mkpatch "studio-ep" [], "epiano")
    , (mkpatch "square-hollow" [], "synth-soft")
    , (mkpatch "dyna-expressive" [], "epiano")
    , (mkpatch "digi-clear" [], "epiano")
    , (mkpatch "comb-clav" [(15, "comb")], "keyboard")
    , (mkpatch "pulse-clav" [(16, "pe1")], "keyboard")
    ]

fm8_patches :: [(Instrument.Patch, Text)]
fm8_patches = [(mkpatch "" [], "fm")]

mkpatch :: Instrument.InstrumentName -> [(Midi.Control, ScoreTypes.Control)]
    -> Instrument.Patch
mkpatch name controls =
    Instrument.patch $ Instrument.instrument (-2, 2) name controls

make_db :: [(Inst.SynthName, [(Instrument.Patch, Text)])] -> Cmd.InstrumentDb
make_db synth_patches = fst $ Inst.db $ map make synth_patches
    where make (name, patches) = make_synth name patches

make_synth :: Inst.SynthName -> [(Instrument.Patch, Text)] -> MidiInst.Synth
make_synth name = MidiInst.synth name "Test Synth" . map make
    where
    make (patch, category) = MidiInst.Patch patch (Common.common mempty)
        { Common.common_tags = [(Tag.category, category)] }
