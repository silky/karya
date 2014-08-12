-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for equal-tempered chromatic scales with keys and modes.
module Derive.Scale.ChromaticScales where
import qualified Data.Either as Either
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import Util.Control
import qualified Util.Seq as Seq
import qualified Derive.Call.ScaleDegree as ScaleDegree
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.Environ as Environ
import qualified Derive.PitchSignal as PitchSignal
import qualified Derive.Scale as Scale
import qualified Derive.Scale.Scales as Scales
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.TheoryFormat as TheoryFormat
import qualified Derive.Score as Score
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch


-- | This contains all that is needed to define a western-like key system.
-- It fills a similar role to 'Scales.ScaleMap' for non-keyed scales.
data ScaleMap = ScaleMap {
    smap_fmt :: !TheoryFormat.Format
    , smap_keys :: !Keys
    , smap_default_key :: !Theory.Key
    , smap_layout :: !Theory.Layout
    , smap_show_pitch :: !(Maybe Pitch.Key -> Pitch.Pitch
        -> Either Scale.ScaleError Pitch.Note)
    , smap_read_pitch :: !(Maybe Pitch.Key -> Pitch.Note
        -> Either Scale.ScaleError Pitch.Pitch)
    -- | Inclusive (bottom, top) of scale, for documentation.
    , smap_range :: !(Pitch.Pitch, Pitch.Pitch)
    }

twelve_doc :: Text
twelve_doc = "Scales in the \"twelve\" family use western style note naming.\
    \ That is, note names look like octave-letter-accidentals like \"4c#\".\
    \ They have a notion of a \"layout\", which is a pattern of half and\
    \ whole steps, e.g. the piano layout, and a key, which is a subset of\
    \ notes from the scale along with a preferred spelling for them. The\
    \ rules of how enharmonic spelling works are complicated, and documented\
    \ in 'Derive.Scale.Theory'. The key is read from the `key` env var, and\
    \ each scale has a list of keys it will accept."

scale_map :: Theory.Layout -> TheoryFormat.Format -> Keys -> Theory.Key
    -> ScaleMap
scale_map layout fmt keys default_key = ScaleMap
    { smap_fmt = fmt
    , smap_keys = keys
    , smap_default_key = default_key
    , smap_layout = layout
    , smap_show_pitch = show_pitch layout fmt
    , smap_read_pitch = read_pitch fmt
    , smap_range = (to_pitch 1, to_pitch 127)
    }
    where to_pitch = Theory.semis_to_pitch_sharps layout . Theory.nn_to_semis

type Keys = Map.Map Pitch.Key Theory.Key

make_keys :: TheoryFormat.Format -> [Theory.Key] -> Keys
make_keys fmt keys =
    Map.fromList $ zip (map (TheoryFormat.show_key fmt) keys) keys

make_scale :: Pitch.ScaleId -> ScaleMap -> Text -> Scale.Scale
make_scale scale_id smap doc = Scale.Scale
    { Scale.scale_id = scale_id
    , Scale.scale_pattern = TheoryFormat.fmt_pattern (smap_fmt smap)
    , Scale.scale_symbols = []
    , Scale.scale_transposers = Scales.standard_transposers
    , Scale.scale_read = smap_read_pitch smap
    , Scale.scale_show = smap_show_pitch smap
    , Scale.scale_layout = Theory.layout_intervals (smap_layout smap)
    , Scale.scale_transpose = transpose smap
    , Scale.scale_enharmonics = enharmonics smap
    , Scale.scale_note_to_call = note_to_call scale smap
    , Scale.scale_input_to_note = input_to_note smap
    , Scale.scale_input_to_nn = Scales.computed_input_to_nn
        (input_to_note smap) (note_to_call scale smap)
    , Scale.scale_call_doc = call_doc Scales.standard_transposers smap doc
    }
    where scale = PitchSignal.Scale scale_id Scales.standard_transposers

-- * functions

transpose :: ScaleMap -> Derive.Transpose
transpose smap transposition maybe_key steps pitch = do
    key <- read_key smap maybe_key
    return $ trans key steps pitch
    where
    trans = case transposition of
        Scale.Chromatic -> Theory.transpose_chromatic
        Scale.Diatonic -> Theory.transpose_diatonic

enharmonics :: ScaleMap -> Derive.Enharmonics
enharmonics smap maybe_key note = do
    pitch <- smap_read_pitch smap maybe_key note
    key <- read_key smap maybe_key
    return $ Either.rights $ map (smap_show_pitch smap maybe_key) $
        Theory.enharmonics_of (Theory.key_layout key) pitch

note_to_call :: PitchSignal.Scale -> ScaleMap -> Pitch.Note
    -> Maybe Derive.ValCall
note_to_call scale smap note =
    case TheoryFormat.read_unadjusted_pitch (smap_fmt smap) note of
        Left _ -> Nothing
        Right pitch -> Just $ ScaleDegree.scale_degree scale
            (pitch_nn smap semis_to_nn pitch) (pitch_note smap pitch)
    where semis_to_nn _config semis = return $ Pitch.NoteNumber semis + 12
    -- Add an octave becasue of NOTE [middle-c].

-- | Create a PitchNote for 'ScaleDegree.scale_degree'.
pitch_note :: ScaleMap -> Pitch.Pitch -> Scale.PitchNote
pitch_note smap pitch (PitchSignal.PitchConfig env controls) =
    Scales.scale_to_pitch_error diatonic chromatic $ do
        let d = round diatonic
            c = round chromatic
        smap_show_pitch smap (Scales.environ_key env) =<< if d == 0 && c == 0
            then return pitch
            else do
                key <- read_env_key smap env
                return $ Theory.transpose_chromatic key c $
                    Theory.transpose_diatonic key d pitch
    where
    chromatic = Map.findWithDefault 0 Controls.chromatic controls
    diatonic = Map.findWithDefault 0 Controls.diatonic controls

type SemisToNoteNumber = PitchSignal.PitchConfig -> Pitch.FSemi
    -> Either Scale.ScaleError Pitch.NoteNumber

-- | Create a PitchNn for 'ScaleDegree.scale_degree'.
pitch_nn :: ScaleMap -> SemisToNoteNumber -> Pitch.Pitch -> Scale.PitchNn
pitch_nn smap semis_to_nn pitch config@(PitchSignal.PitchConfig env controls) =
    Scales.scale_to_pitch_error diatonic chromatic $ do
        pitch <- TheoryFormat.fmt_to_absolute (smap_fmt smap)
            (Scales.environ_key env) pitch
        dsteps <- if diatonic == 0 then Right 0 else do
            key <- read_env_key smap env
            return $ Theory.diatonic_to_chromatic key
                (Pitch.pitch_degree pitch) diatonic
        let semis = Theory.pitch_to_semis (smap_layout smap) pitch
            degree = fromIntegral semis + chromatic + dsteps
        nn <- semis_to_nn config degree
        if 1 <= nn && nn <= 127 then Right nn
            else Left Scale.InvalidTransposition
    where
    chromatic = Map.findWithDefault 0 Controls.chromatic controls
    diatonic = Map.findWithDefault 0 Controls.diatonic controls

input_to_note :: ScaleMap -> Scales.InputToNote
input_to_note smap maybe_key (Pitch.Input kbd_type pitch frac) = do
    pitch <- Scales.kbd_to_scale kbd_type pc_per_octave (key_tonic key) pitch
    unless (Theory.layout_contains_degree key (Pitch.pitch_degree pitch)) $
        Left Scale.InvalidInput
    -- Relative scales don't need to figure out enharmonic spelling, and
    -- besides it would be wrong since it assumes Pitch 0 0 is C.
    let pick_enharmonic = if TheoryFormat.fmt_relative (smap_fmt smap) then id
            else Theory.pick_enharmonic key
    -- Don't pass the key, because I want the Input to also be relative, i.e.
    -- Pitch 0 0 should be scale degree 0 no matter the key.
    note <- smap_show_pitch smap Nothing $ pick_enharmonic pitch
    return $ ScaleDegree.pitch_expr frac note
    where
    pc_per_octave = Theory.layout_pc_per_octave (smap_layout smap)
    -- Default to a key because otherwise you couldn't enter notes in an
    -- empty score!
    key = fromMaybe (smap_default_key smap) $
        flip Map.lookup (smap_keys smap) =<< maybe_key

call_doc :: Set.Set Score.Control -> ScaleMap -> Text -> Derive.DocumentedCall
call_doc transposers smap doc =
    Scales.annotate_call_doc transposers extra_doc fields $
        Derive.extract_val_doc call
    where
    call = ScaleDegree.scale_degree PitchSignal.no_scale err err
        where err _ = Left $ PitchSignal.PitchError "it was just an example!"
    extra_doc = doc <> twelve_doc
    -- Not efficient, but shouldn't matter for docs.
    default_key = fst <$> List.find ((== smap_default_key smap) . snd)
        (Map.toList (smap_keys smap))
    (bottom, top) = smap_range smap
    show_pitch = either prettyt prettyt . smap_show_pitch smap Nothing
    fields = concat
        [ [("range", show_pitch bottom <> " to " <> show_pitch top)]
        , maybe [] (\n -> [("default key", prettyt n)]) default_key
        , [ ("keys", format_keys $ Map.keys (smap_keys smap)) ]
        ]

format_keys :: [Pitch.Key] -> Text
format_keys keys
    | all (("-" `Text.isInfixOf`) . name) keys = Text.intercalate ", " $
        map fst $ group_tonic_mode $ map (flip (,) ()) keys
    | otherwise = Text.intercalate ", " $ map name keys
    where name (Pitch.Key k) = k

-- | Assuming keys are formatted @tonic-mode@, group keys by mode and replace
-- the tonics with a pattern.
group_tonic_mode :: [(Pitch.Key, a)] -> [(Text, a)]
group_tonic_mode = map extract . Seq.keyed_group_on key . map (first split)
    where
    extract (mode, group) = (fmt mode (map (fst . fst) group), snd (head group))
    key ((_, mode), _) = mode
    split (Pitch.Key t) = (pre, Text.drop 1 post)
        where (pre, post) = Text.break (=='-') t
    fmt mode keys = "(" <> Text.intercalate "|" keys <> ")-" <> mode

-- * format

relative_fmt :: Theory.Key -> Keys -> TheoryFormat.RelativeFormat Theory.Key
relative_fmt default_key all_keys  = TheoryFormat.RelativeFormat
    { TheoryFormat.rel_acc_fmt = TheoryFormat.ascii_accidentals
    , TheoryFormat.rel_parse_key = Scales.get_key default_key all_keys
    , TheoryFormat.rel_default_key = default_key
    , TheoryFormat.rel_show_degree = TheoryFormat.show_degree_chromatic
    , TheoryFormat.rel_to_absolute = TheoryFormat.chromatic_to_absolute
    , TheoryFormat.rel_key_tonic = key_tonic
    }

-- * implementation

key_tonic :: Theory.Key -> Pitch.PitchClass
key_tonic = Pitch.degree_pc . Theory.key_tonic

show_pitch :: Theory.Layout -> TheoryFormat.Format -> Maybe Pitch.Key
    -> Pitch.Pitch -> Either Scale.ScaleError Pitch.Note
show_pitch layout fmt key pitch
    | 1 <= nn && nn <= 127 =
        Right $ TheoryFormat.show_pitch fmt key pitch
    | otherwise = Left Scale.InvalidTransposition
    where nn = Theory.semis_to_nn $ Theory.pitch_to_semis layout pitch

read_pitch :: TheoryFormat.Format -> Maybe Pitch.Key -> Pitch.Note
    -> Either Scale.ScaleError Pitch.Pitch
read_pitch = TheoryFormat.read_pitch

read_env_key :: ScaleMap -> TrackLang.Environ
    -> Either Scale.ScaleError Theory.Key
read_env_key smap = Scales.read_environ
    (\k -> Map.lookup (Pitch.Key k) (smap_keys smap))
    (smap_default_key smap) Environ.key

read_key :: ScaleMap -> Maybe Pitch.Key -> Either Scale.ScaleError Theory.Key
read_key smap = Scales.get_key (smap_default_key smap) (smap_keys smap)
