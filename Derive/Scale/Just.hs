-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | A version of a just intonation diatonic scale that is tuned based on
-- a pitch signal.
module Derive.Scale.Just where
import qualified Data.Map as Map
import Data.Ratio ((%))
import qualified Data.Vector as Vector

import Util.Control
import qualified Derive.Scale as Scale
import qualified Derive.Scale.JustScales as JustScales
import qualified Derive.Scale.TheoryFormat as TheoryFormat
import qualified Derive.Scale.Util as Util

import qualified Perform.NN as NN
import qualified Perform.Pitch as Pitch


scales :: [Scale.Scale]
scales =
    [ JustScales.make_scale (Pitch.ScaleId "just")
        (scale_map TheoryFormat.absolute_c)
    , JustScales.make_scale (Pitch.ScaleId "just-r")
        (scale_map (TheoryFormat.sargam relative_fmt))
    ]

scale_map :: TheoryFormat.Format -> JustScales.ScaleMap
scale_map fmt = JustScales.ScaleMap
    { JustScales.smap_fmt = fmt
    , JustScales.smap_keys = keys
    , JustScales.smap_default_key = default_key
    , JustScales.smap_default_base_hz = Pitch.nn_to_hz NN.middle_c
    , JustScales.smap_named_intervals = JustScales.named_intervals
    , JustScales.smap_accidental_interval = 16 / 15
    }

relative_fmt :: TheoryFormat.RelativeFormat TheoryFormat.Tonic
relative_fmt = TheoryFormat.RelativeFormat
    { TheoryFormat.rel_acc_fmt = TheoryFormat.ascii_accidentals
    , TheoryFormat.rel_parse_key = fmap JustScales.key_tonic . lookup_key
    , TheoryFormat.rel_default_key = 0
    , TheoryFormat.rel_show_note = TheoryFormat.show_note_diatonic
    , TheoryFormat.rel_to_absolute = TheoryFormat.diatonic_to_absolute
    }

lookup_key :: Maybe Pitch.Key -> Either Scale.ScaleError JustScales.Key
lookup_key Nothing = Right default_key
lookup_key (Just key) = Util.maybe_key key (Map.lookup key keys)

default_key :: JustScales.Key
Just default_key = Map.lookup (Pitch.Key "c-maj") keys

keys :: Map.Map Pitch.Key JustScales.Key
keys = Map.fromList
    [ (Pitch.Key $ degree <> "-" <> name, JustScales.Key tonic ratios)
    | (name, ratios) <- key_ratios
    , (degree, tonic) <- zip TheoryFormat.absolute_c_degrees [0..]
    ]

key_ratios :: [(Text, JustScales.Ratios)]
key_ratios = map (second Vector.fromList)
    [ ("maj", [1, 9%8, 5%4, 4%3, 3%2, 5%3, 15%8])
    , ("min", [1, 9%8, 6%5, 4%3, 3%2, 8%5, 9%5])
    , ("legong", [1, 10%9, 6%5, 4%3, 3%2, 25%16, 9%5])
    , ("hemavathi", [1, 10%9, 6%5, (3%2) / (16%15), 3%2, 5%3, 9%5])
    ]
