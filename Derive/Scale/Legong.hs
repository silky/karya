-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Saih pitu scales.

    @
    3i 3o 3e 3u 3a 4i 4o 4e 4u 4a 5i 5o 5e 5u 5a 6i 6o 6e 6u 6a 7i
    jegog---------
                   calung--------
                                  penyacah------
       ugal-------------------------
          rambat-----------------------------------
    0              7              14             21             28
    3i 3o 3e 3u 3a 4i 4o 4e 4u 4a 5i 5o 5e 5u 5a 6i 6o 6e 6u 6a 7i
                trompong---------------------
                      pemade-----------------------
                                     kantilan---------------------
                         reyong-----------------------------
                         |1-----|---       |3--|---
                                  |2-----|---    |4--------|
    3i 3o 3e 3u 3a 4i 4o 4e 4u 4a 5i 5o 5e 5u 5a 6i 6o 6e 6u 6a 7i
    @
-}
module Derive.Scale.Legong where
import qualified Data.Map as Map
import qualified Data.Vector as Vector

import qualified Util.Doc as Doc
import qualified Util.Seq as Seq
import qualified Util.TextUtil as TextUtil

import qualified Midi.Key as Key
import qualified Midi.Midi as Midi
import qualified Derive.Scale as Scale
import qualified Derive.Scale.Bali as Bali
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Scale.McPhee as McPhee
import qualified Derive.Scale.Scales as Scales
import qualified Derive.Scale.Theory as Theory
import qualified Derive.ShowVal as ShowVal

import qualified Perform.Midi.Patch as Patch
import qualified Perform.Pitch as Pitch
import Global


scales :: [Scale.Make]
scales = make_scale_set config scale_id "Saih pelegongan, from my instruments."

make_scale_set :: BaliScales.Config -> Pitch.ScaleId -> Doc.Doc -> [Scale.Make]
make_scale_set config (Pitch.ScaleId prefix) doc =
    map (Scale.Simple . Scales.add_doc doc)
    [ BaliScales.make_scale (id_with "") (scale_map complete_scale)
    , BaliScales.make_scale (id_with "b") (scale_map complete_scale_balinese)
    , Scales.add_doc "Use Javanese-style cipher notation. This can be more\
        \ convenient for saih pitu." $
        -- TODO use 4 and 7 instead of 3# and 6#.
        -- Use simple_scale like *wayang and *selesir?
        BaliScales.make_scale (id_with "c") (scale_map cipher_scale)
    , inst_doc "pemade" $ BaliScales.make_scale (id_with "pemade")
        (inst_scale_map pemade)
    , inst_doc "pemade" $ BaliScales.make_scale (id_with "pemade-b")
        (inst_scale_map (balinese pemade))
    , inst_doc "kantilan" $ BaliScales.make_scale (id_with "kantilan")
        (inst_scale_map kantilan)
    , inst_doc "kantilan" $ BaliScales.make_scale (id_with "kantilan-b")
        (inst_scale_map (balinese kantilan))
    ]
    where
    id_with suffix = Pitch.ScaleId $ TextUtil.joinWith "-" prefix suffix
    inst_doc name = Scales.add_doc $
        "This is centered around the " <> name <> " range."
    scale_map fmt = BaliScales.scale_map config fmt Nothing
    inst_scale_map = BaliScales.instrument_scale_map config

    complete_scale = BaliScales.ioeua_relative True
        (BaliScales.config_default_key config) (BaliScales.config_keys config)
    complete_scale_balinese =
        BaliScales.digit_octave_relative BaliScales.balinese True
            (BaliScales.config_default_key config)
            (BaliScales.config_keys config)
    cipher_scale = BaliScales.cipher_relative_dotted 5
        (BaliScales.config_default_key config)
        (BaliScales.config_keys config)

scale_id :: Pitch.ScaleId
scale_id = "legong"

jegog, calung, penyacah :: BaliScales.Instrument
jegog = instrument 1 (Pitch.pitch 3 I) (Pitch.pitch 3 As)
calung = instrument 2 (Pitch.pitch 4 I) (Pitch.pitch 4 As)
penyacah = instrument 3 (Pitch.pitch 5 0) (Pitch.pitch 5 As)

pemade, kantilan :: BaliScales.Instrument
pemade = instrument 5 (Pitch.pitch 4 O) (Pitch.pitch 6 I)
kantilan = instrument 6 (Pitch.pitch 5 O) (Pitch.pitch 7 I)

-- * config

instrument :: Pitch.Octave -> Pitch.Pitch -> Pitch.Pitch
    -> BaliScales.Instrument
instrument = BaliScales.Instrument BaliScales.ioeua BaliScales.arrow_octaves

balinese :: BaliScales.Instrument -> BaliScales.Instrument
balinese inst = inst
    { BaliScales.inst_degrees = BaliScales.balinese
    , BaliScales.inst_relative_octaves = BaliScales.balinese_octaves
    }

config :: BaliScales.Config
config = BaliScales.Config
    { config_layout = layout
    , config_base_octave = base_octave
    , config_keys = keys
    , config_default_key = default_key
    , config_saihs = saihs
    , config_default_saih = default_saih
    }
    where
    layout = Theory.layout [1, 1, 2, 1, 2]
    keys = BaliScales.make_keys layout all_keys
    Just default_key = Map.lookup (Pitch.Key "selisir") keys

-- | These are from Tenzer's "Gamelan Gong Kebyar", page 29.  This is Dewa
-- Beratha's definition.  McPhee's book has different names for gambuh, but
-- Beratha's is probably more modern.
--
-- This are assigned with @key=...@.  McPhee calls them tekepan (suling) or
-- ambah.  Or I could use patutan / pathet.
--
-- TODO this is wrong, patut changes both key and mode, so ding is shifted.
all_keys :: [(Text, Pitch.Semi, [Pitch.Semi])]
all_keys = map make_key
    [ ("selisir", [1, 2, 3, 5, 6])          -- 123_45_  ioe_ua_
    , ("slendro-gede", [2, 3, 4, 6, 7])     -- _234_67  _ioe_ua
    , ("baro", [1, 3, 4, 5, 7])             -- 1_345_7  a_ioe_u
    , ("tembung", [1, 2, 4, 5, 6])          -- 12_456_  ua_ioe_
    , ("sunaren", [2, 3, 5, 6, 7])          -- _23_567  _ua_ioe
    -- hypothetical
    , ("pengenter-alit", [1, 3, 4, 6, 7])   -- 1_34_67  e_ua_io
    , ("pengenter", [1, 2, 4, 5, 7])        -- 12_45_7  oe_ua_i
    -- TODO these all have a hardcoded layout that assumes some "accidentals".
    -- For lebeng I can just use selisir with all the notes.
    -- , ("lebeng", [1, 2, 3, 4, 5, 6, 7])
    ]

make_key :: (Text, [Pitch.Semi]) -> (Text, Pitch.Semi, [Pitch.Semi])
make_key (_, []) = errorStack "no semis for scale"
make_key (name, n : ns) = (name, n - 1, zipWith (-) (ns ++ [n+7]) (n:ns))

ugal_range, rambat_range, trompong_range, reyong_range :: Scale.Range
ugal_range = Scale.Range (Pitch.pitch 3 O) (Pitch.pitch 5 I)
rambat_range = Scale.Range (Pitch.pitch 3 E) (Pitch.pitch 6 I)
trompong_range = Scale.Range (Pitch.pitch 3 A) (Pitch.pitch 5 U)
reyong_range = Scale.Range (Pitch.pitch 4 E) (Pitch.pitch 6 U)

-- | Lowest note start on this octave.
base_octave :: Pitch.Octave
base_octave = 3

-- * saih

data Pitch = I | O | E | Es | U | A | As
    deriving (Eq, Ord, Enum, Show, Bounded)

default_saih :: Text
default_saih = "rambat"

saihs :: Map Text BaliScales.Saih
saihs = Map.fromList $
    [ (default_saih, saih_rambat)
    , ("pegulingan-teges", pegulingan_teges)
    ] ++ mcphee

saih_rambat :: BaliScales.Saih
saih_rambat = BaliScales.saih (extend 3 E)
    "From my gender rambat, made in Blabatuh, Gianyar, tuned in\
    \ Munduk, Buleleng."
    $ map (second (Pitch.add_hz 4)) -- TODO until I measure real values
    [ (51.82,   51.82)  -- 3e, rambat begin
    , (54.00,   54.00)  -- TODO
    , (55.70,   55.70)  -- 3u
    , (56.82,   56.82)  -- 3a, trompong begin
    , (58.00,   58.00)  -- TODO

    , (60.73,   60.73)  -- 4i
    , (62.80,   62.80)  -- 4o, pemade begin
    , (63.35,   63.35)  -- 4e, reyong begin
    , (65.00,   65.00)  -- TODO
    , (67.70,   67.70)  -- 4u
    , (68.20,   68.20)  -- 4a
    , (70.00,   70.00)  -- TODO

    , (72.46,   72.46)  -- 5i
    , (73.90,   73.90)  -- 5o, kantilan begin
    , (75.50,   75.50)  -- 5e
    , (78.00,   78.00)  -- TODO
    , (79.40,   79.40)  -- 5u, trompong end
    , (80.50,   80.50)  -- 5a
    , (83.00,   83.00)  -- TODO

    , (84.46,   84.46)  -- 6i, rambat end, pemade end
    , (86.00,   86.00)  -- 6o
    , (87.67,   87.67)  -- 6e
    , (90.00,   90.00)  -- TODO
    , (91.74,   91.74)  -- 6u, reyong end
    , (92.50,   92.50)  -- 6a
    , (95.00,   95.00)  -- TODO

    , (96.46,   96.46)  -- 7i, kantilan end
    ]

-- TODO move to *selisir
-- TODO what is the ombak?
pegulingan_teges :: BaliScales.Saih
pegulingan_teges = BaliScales.saih (extend 4 U)
    "From Teges Semar Pegulingan, via Bob Brown's 1972 recording."
    $ map (\nn -> (nn, nn))
    [ 69.55 -- 4u
    , 70.88 -- 4a
    , 73.00

    , 75.25 -- 5i
    , 76.90 -- 5o, kantilan begin
    , 77.94 -- 5e
    , 81.00
    , 81.80 -- 5u... should I agree with the lower octave?
    ]

-- | Extend down to 3i, which is jegog range.
extend :: Pitch.Octave -> Pitch -> [Pitch.NoteNumber] -> [Pitch.NoteNumber]
extend oct pc = Bali.extend_scale 7 low_pitch high_pitch (Pitch.pitch oct pc)

low_pitch, high_pitch :: Pitch.Pitch
low_pitch = Pitch.pitch base_octave I
high_pitch = Pitch.pitch 7 I

mcphee :: [(Text, BaliScales.Saih)]
mcphee = map (make . McPhee.extract low_pitch high_pitch) McPhee.saih_pitu
    where
    make (name, (nns, doc)) =
        (name, BaliScales.saih id doc (map (\nn -> (nn, nn)) nns))

-- | Strip extra notes to get back to saih lima.
pitu_to_lima :: BaliScales.Saih -> BaliScales.Saih
pitu_to_lima (BaliScales.Saih doc umbang isep) = BaliScales.Saih
    { saih_doc = doc
    , saih_umbang = strip umbang
    , saih_isep = strip isep
    }
    where
    strip = Vector.fromList
        . concatMap (\nns -> mapMaybe (Seq.at nns) [0, 1, 2, 4, 5])
        . Seq.chunked 7 . Vector.toList

-- * instrument integration

-- | A Scale with the entire theoretical range.  This is for instruments
-- that are normalized to 12tet and then tuned in the patch (e.g. using KSP).
complete_instrument_scale :: BaliScales.Saih -> BaliScales.Tuning -> Patch.Scale
complete_instrument_scale = instrument_scale id

instrument_scale ::
    ([(Midi.Key, Pitch.NoteNumber)] -> [(Midi.Key, Pitch.NoteNumber)])
    -- ^ drop and take keys for the instrument's range
    -> BaliScales.Saih -> BaliScales.Tuning -> Patch.Scale
instrument_scale take_range saih tuning =
    Patch.make_scale ("legong " <> ShowVal.show_val tuning) $
        take_range $ zip midi_keys (Vector.toList nns)
    where
    nns = case tuning of
        BaliScales.Umbang -> BaliScales.saih_umbang saih
        BaliScales.Isep -> BaliScales.saih_isep saih

-- | Emit from i3 on up.
midi_keys :: [Midi.Key]
midi_keys = trim $ concatMap keys [base_octave + 1 ..]
    -- base_octave + 1 because MIDI starts at octave -1
    where
    trim = take (5*7 + 1)
    keys oct = map (Midi.to_key (oct * 12) +) -- i o e e# u a a#
        [Key.c_1, Key.d_1, Key.e_1, Key.f_1, Key.g_1, Key.a_1, Key.b_1]
