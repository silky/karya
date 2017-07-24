-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Sonic Couture's Gamelan Bali sample set.
module Local.Instrument.Kontakt.ScGamelan where
import qualified Data.List as List

import qualified Midi.Key2 as Key2
import qualified Midi.Midi as Midi
import qualified Ui.UiConfig as UiConfig
import qualified Cmd.Instrument.Bali as Bali
import qualified Cmd.Instrument.CUtil as CUtil
import qualified Cmd.Instrument.Drums as Drums
import qualified Cmd.Instrument.MidiInst as MidiInst

import qualified Derive.Attrs as Attrs
import qualified Derive.BaseTypes as BaseTypes
import qualified Derive.Call.Bali.Gangsa as Gangsa
import qualified Derive.EnvKey as EnvKey
import qualified Derive.RestrictedEnviron as RestrictedEnviron
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Scale.Legong as Legong
import qualified Derive.Score as Score

import qualified Perform.Midi.Patch as Patch
import qualified Instrument.Common as Common
import qualified Instrument.InstTypes as InstTypes
import Global


synth_name :: InstTypes.SynthName
synth_name = "kontakt"

patches :: [MidiInst.Patch]
patches = map add_doc $
    CUtil.simple_drum Nothing gong_notes (sc_patch "gong")
    : CUtil.simple_drum Nothing kempli_kajar_notes (sc_patch "kempli")
    : reyong_ks (ranged_patch Legong.reyong_range "reyong")
    : ranged_patch Legong.trompong_range "trompong"
    : concat
    [ pasang True (range_of Legong.jegog) "jegog"
    , pasang True (range_of Legong.calung) "calung"
    , pasang True (range_of Legong.penyacah) "penyacah"
    , tunggal False Legong.ugal_range "ugal"
    , pasang False (range_of Legong.pemade) "pemade"
    , pasang False (range_of Legong.kantilan) "kantilan"
    ]
    where
    pasang wrap_octaves range name =
        tunggal wrap_octaves range name ++
        [ MidiInst.code #= (Bali.pasang_code <> Bali.gangsa_note wrap) $
            ranged_patch range (name <> "-pasang")
        ]
        where wrap = if wrap_octaves then Just range else Nothing
    tunggal wrap_octaves range name =
        [ MidiInst.code #= Bali.gangsa_note wrap $
            gangsa_ks $ ranged_patch range name
        ]
        where wrap = if wrap_octaves then Just range else Nothing

    range_of = BaliScales.instrument_range
    ranged_patch range = MidiInst.range range . sc_patch
    sc_patch name =
        MidiInst.patch
            %= MidiInst.add_flags [Patch.ConstantPitch, Patch.UseFinalNoteOff] $
        MidiInst.named_patch (-2, 2) ("sc-" <> name) []
    add_doc = MidiInst.doc
        %= ("Sonic Couture's Balinese gamelan sample set. " <>)
    gangsa_ks = MidiInst.attribute_map #= Patch.single_keyswitches
        [(Attrs.mute, Key2.cs1), (mempty, Key2.c1)]
    reyong_ks = MidiInst.attribute_map #= Patch.single_keyswitches
        [(Attrs.attr "cek", Key2.cs1), (mempty, Key2.c1)]
    gong_notes =
        [ (n 'z' "O" (gong <> wadon),   Key2.b1)
        , (n 'x' "o" (gong <> lanang),  Key2.c2)
        , (n 'q' "p" kempur,            Key2.a2)
        , (n 'w' "m" kemong,            Key2.a3)
        ]
        where n = Drums.note
    kempli_kajar_notes =
        [ (n 'z' "+"    kempli,                 Key2.d3)
        , (n 'a' "`O+`" (kempli <> open),       Key2.ds3)
        , (n 'x' "+1"   (kempli <> Attrs.v1),   Key2.f3)
        , (n 'c' "+2"   (kempli <> Attrs.v2),   Key2.g3)
        , (n 'v' "+3"   (kempli <> Attrs.v3),   Key2.a3)
        , (n 'b' "b"    bebende,                Key2.d4)
        , (n 'g' "B"    (bebende <> open),      Key2.ds4)
        , (n 'q' "o"    kajar,                  Key2.f4)
        , (n 'w' "+"    (kajar <> Attrs.rim <> open), Key2.fs4)
        -- The Sonic Couture kajar doesn't have this.
        , (n 'e' "P"    (kajar <> Attrs.rim),   Key2.g4)
        -- Soniccouture also has a low kajar variant.
        ]
        where n = Drums.note
    open = Attrs.open

gong = Attrs.attr "gong"
kemong = Attrs.attr "kemong"
kempur = Attrs.attr "kempur"
bebende = Attrs.attr "bebende"
wadon = Attrs.attr "wadon"
lanang = Attrs.attr "lanang"
kempli = Attrs.attr "kempli"
kajar = Attrs.attr "kajar"

kebyar_allocations :: Text -> UiConfig.Allocations
kebyar_allocations dev_ = make_config $ concat
    [ pasang "jegog"
    , pasang "calung"
    , pasang "penyacah"
    , pasang "pemade"
    , pasang "kantilan"
    , [ umbang_patch "ugal" "ugal"
      , isep_patch "reyong" "reyong"
      , umbang_patch "trompong" "trompong"
      , patch "gong"
      , patch "kempli"
      ]
    ]
    where
    -- (inst, qualified, gets_chan, environ, scale)
    make_config :: [(Text, Text, Bool,
            [(BaseTypes.Key, RestrictedEnviron.Val)], Maybe Patch.Scale)]
        -> UiConfig.Allocations
    make_config = MidiInst.allocations . snd . List.mapAccumL allocate 0
        where
        allocate chan (inst, qualified, gets_chan, environ, scale) =
            ( next_chan
            , (inst, qualified, set_config, backend)
            )
            where
            next_chan = if gets_chan then chan+1 else chan
            backend
                | gets_chan = UiConfig.Midi $
                    Patch.settings#Patch.scale #= scale $
                    MidiInst.config1 dev chan
                -- Pasang instruments don't get an allocation.  Otherwise they
                -- don't have the right tuning.
                | otherwise = UiConfig.Dummy
            set_config = Common.cenviron #= RestrictedEnviron.make environ
    dev = Midi.write_device dev_

    -- Actually pemade and kantilan have an umbang isep pair for both polos and
    -- sangsih, but since I don't have that many sample sets I have
    -- a mini-ensemble with only one pair of each gangsa.
    pasang name =
        [ (name, sc_qualified name <> "-pasang", False, polos_sangsih name,
            Nothing)
        , umbang_patch (name <> "-p") name
        , isep_patch (name <> "-s") name
        ]
    sc_qualified name = synth_name <> "/sc-" <> name
    polos_sangsih name =
        [ (Gangsa.inst_polos, to_val $ Score.instrument $ name <> "-p")
        , (Gangsa.inst_sangsih, to_val $ Score.instrument $ name <> "-s")
        ]
    to_val :: RestrictedEnviron.ToVal a => a -> RestrictedEnviron.Val
    to_val = RestrictedEnviron.to_val
    umbang_patch name patch =
        ( name, sc_qualified patch, True
        , tuning BaliScales.Umbang
        , Just $ Legong.complete_instrument_scale
            Legong.laras_rambat BaliScales.Umbang
        )
    isep_patch name patch =
        ( name, sc_qualified patch, True
        , tuning BaliScales.Isep
        , Just $ Legong.complete_instrument_scale
            Legong.laras_rambat BaliScales.Isep
        )
    tuning val = [(EnvKey.tuning, to_val val)]
    patch name = (name, sc_qualified name, True, [], Nothing)
