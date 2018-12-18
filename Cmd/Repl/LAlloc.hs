-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Functions to construct instrument allocations.  You can merge them with
-- 'LInst.replace' or 'LInst.merge'.
module Cmd.Repl.LAlloc where
import qualified Cmd.Instrument.ImInst as ImInst
import qualified Cmd.Instrument.MidiInst as MidiInst
import qualified Derive.C.Bali.Gangsa as Gangsa
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Score as Score

import qualified Instrument.Common as Common
import qualified Midi.Midi as Midi
import qualified Ui.UiConfig as UiConfig
import qualified User.Elaforge.Instrument.Kontakt.ScGamelan as ScGamelan

import Global


-- * bali

rambat_im :: UiConfig.Allocations
rambat_im =
    pasang_im "ra" BaliScales.Umbang
        "sampler/rambat-umbang" "sampler/rambat-isep"

wayang_im :: UiConfig.Allocations
wayang_im =
    pasang_im "p" BaliScales.Umbang
        "sampler/wayang-pemade-umbang" "sampler/wayang-pemade-isep"
    <> pasang_im "k" BaliScales.Umbang
        "sampler/wayang-kantilan-umbang" "sampler/wayang-kantilan-isep"

-- | Set up a gender wayang quartet.
--
-- There are two pasang instruments, which then rely on the kotekan calls to
-- split into inst-polos and inst-sangsih.  Polos has umbang.
wayang_midi :: Text -> UiConfig.Allocations
wayang_midi dev_ =
    pasang_midi dev 0 "p" BaliScales.Umbang
        "kontakt/wayang-umbang" "kontakt/wayang-isep"
    <> pasang_midi dev 2 "k" BaliScales.Umbang
        "kontakt/wayang-umbang" "kontakt/wayang-isep"
    where
    dev = Midi.write_device dev_

-- | Set up a umbang isep pair.
pasang_im :: Text -> BaliScales.Tuning -> Text -> Text -> UiConfig.Allocations
pasang_im base polos_tuning umbang_qual isep_qual =
    ImInst.allocations
        [ (inst base, "", pasang, UiConfig.Dummy)
        , (umbang, umbang_qual, id, UiConfig.Im)
        , (isep, isep_qual, id, UiConfig.Im)
        ]
    where
    umbang = inst $ base <> "-u"
    isep = inst $ base <> "-i"
    pasang = make_pasang polos_tuning umbang isep
    inst = Score.Instrument

pasang_midi :: Midi.WriteDevice -> Midi.Channel -> Text -> BaliScales.Tuning
    -> Text -> Text -> UiConfig.Allocations
pasang_midi dev chan base polos_tuning umbang_qual isep_qual =
    MidiInst.allocations
        [ (inst base, "", pasang, UiConfig.Dummy)
        , (umbang, umbang_qual, id, midi_channel 0)
        , (isep, isep_qual, id, midi_channel 1)
        ]
    where
    umbang = inst $ base <> "-u"
    isep = inst $ base <> "-i"
    pasang = make_pasang polos_tuning umbang isep
    midi_channel relative_chan =
        UiConfig.Midi (MidiInst.config1 dev (chan + relative_chan))
    inst = Score.Instrument

make_pasang :: BaliScales.Tuning -> Score.Instrument -> Score.Instrument
    -> Common.Config -> Common.Config
make_pasang polos_tuning umbang isep =
    Common.add_environ Gangsa.inst_polos polos
    . Common.add_environ Gangsa.inst_sangsih sangsih
    where
    (polos, sangsih) = case polos_tuning of
        BaliScales.Umbang -> (umbang, isep)
        BaliScales.Isep -> (isep, umbang)

kebyar :: Text -> UiConfig.Allocations
kebyar = ScGamelan.kebyar_allocations
