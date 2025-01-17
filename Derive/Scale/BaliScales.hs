-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for Balinese scales.  Mostly that means dealing with umbang and
-- isep.
--
-- They're implemented as a modification of "ChromaticScales" because a saih
-- pitu or pelog scale requires a key or pathet, which winds up being similar
-- to a simplified chromatic scale.
module Derive.Scale.BaliScales where
import qualified Data.Attoparsec.Text as A
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import           Data.Vector ((!?))

import qualified Util.Doc as Doc
import qualified Util.Lists as Lists
import qualified Util.Num as Num
import qualified Util.Texts as Texts

import qualified Derive.DeriveT as DeriveT
import qualified Derive.EnvKey as EnvKey
import qualified Derive.PSignal as PSignal
import qualified Derive.REnv as REnv
import qualified Derive.Scale as Scale
import qualified Derive.Scale.ChromaticScales as ChromaticScales
import qualified Derive.Scale.Scales as Scales
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.TheoryFormat as TheoryFormat
import qualified Derive.ScoreT as ScoreT
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Typecheck as Typecheck

import qualified Perform.Pitch as Pitch

import           Global


-- | Top level scale constructor.
make_scale :: Pitch.ScaleId -> ScaleMap -> Scale.Scale
make_scale scale_id smap =
    (ChromaticScales.make_scale scale_id (smap_chromatic smap) doc)
    { Scale.scale_enharmonics = Scales.no_enharmonics }
    where
    doc = "Balinese scales come in detuned pairs. They use the "
        <> ShowVal.doc EnvKey.tuning <> " env var to select between pengumbang\
        \ and pengisep. The env var should be set to either `umbang` or `isep`,\
        \ defaulting to `umbang`. Normally the umbang and isep\
        \ frequencies are hardcoded according to the scale, but if the "
        <> ShowVal.doc c_ombak
        <> " control is present, they will be tuned that many hz apart.\
        \\nThe " <> ShowVal.doc laras_key <> " env var chooses between\
        \ different tunings.  It defaults to "
        <> ShowVal.doc (laras_name (smap_default_laras smap))
        <> ". Laras:\n"
        <> Texts.enumeration
            [ ShowVal.doc name <> " - " <> laras_doc laras
            | (name, laras) <- Map.toList (smap_laras smap)
            ]

data ScaleMap = ScaleMap {
    smap_chromatic :: !ChromaticScales.ScaleMap
    , smap_laras :: !LarasMap
    , smap_default_laras :: !Laras
    }

type LarasMap = Map Text Laras

scale_map :: Config -> TheoryFormat.Format -> Maybe (Pitch.Semi, Pitch.Semi)
    -- ^ If not given, use the complete range of the saih.
    -> ScaleMap
scale_map (Config layout all_keys default_key laras default_laras)
        fmt maybe_range =
    ScaleMap
        { smap_chromatic =
            (ChromaticScales.scale_map layout fmt all_keys default_key)
            { ChromaticScales.smap_semis_to_nn =
                semis_to_nn layout laras default_laras
            -- Convert range to absolute.
            , ChromaticScales.smap_range = bimap (+offset) (+offset) range
            }
        , smap_laras = laras
        , smap_default_laras = default_laras
        }
    where
    -- Each laras can start on a different note, but I use the default one
    -- for the range as a whole.
    offset = laras_offset layout default_laras
    range = fromMaybe (0, top) maybe_range
    top = maybe 0 (subtract 1 . Vector.length . laras_umbang) $
        Lists.head (Map.elems laras)

data Config = Config {
    config_layout :: !Theory.Layout
    , config_keys :: !ChromaticScales.Keys
    , config_default_key :: !Theory.Key
    , config_laras :: !LarasMap
    , config_default_laras :: !Laras
    } deriving (Show)

-- | This is a specialized version of 'scale_map' that uses base octave and
-- low and high pitches to compute the range.
instrument_scale_map :: Config -> Instrument -> ScaleMap
instrument_scale_map config
        (Instrument degrees relative_octaves center_oct low high) =
    scale_map config fmt (Just (to_pc low, to_pc high))
    where
    to_pc p = Pitch.diff_pc per_oct p base_pitch
    base_pitch = laras_base (config_default_laras config)
    fmt = relative_arrow degrees relative_octaves center_oct True
        (config_default_key config) (config_keys config)
    per_oct = Theory.layout_semis_per_octave (config_layout config)

-- | Describe an instrument-relative scale.
data Instrument = Instrument {
    inst_degrees :: !TheoryFormat.Degrees
    , inst_relative_octaves :: !RelativeOctaves
    , inst_center :: !Pitch.Octave
    , inst_low :: !Pitch.Pitch
    , inst_high :: !Pitch.Pitch
    } deriving (Eq, Show)

instrument_range :: Instrument -> Scale.Range
instrument_range inst = Scale.Range (inst_low inst) (inst_high inst)

-- * Laras

-- | Describe the frequencies in a saih.  This doesn't say what the range is,
-- since that's in the 'ScaleMap', and all saihs in one scale should have the
-- same range.
data Laras = Laras {
    laras_name :: Text
    , laras_doc :: Doc.Doc
    -- | The pitch where the laras starts.  It should be such that octave 4 is
    -- close to middle C.
    , laras_base :: Pitch.Pitch
    , laras_umbang :: Vector.Vector Pitch.NoteNumber
    , laras_isep :: Vector.Vector Pitch.NoteNumber
    } deriving (Eq, Show)

laras_map :: [Laras] -> Map Text Laras
laras_map = Map.fromList . Lists.keyOn laras_name

laras :: Text -> Pitch.Pitch -> ([Pitch.NoteNumber] -> [Pitch.NoteNumber])
    -> Doc.Doc -> [(Pitch.NoteNumber, Pitch.NoteNumber)] -> Laras
laras name base_pitch extend doc nns = Laras
    { laras_name = name
    , laras_doc = doc
    , laras_base = base_pitch
    , laras_umbang = Vector.fromList (extend umbang)
    , laras_isep = Vector.fromList (extend isep)
    }
    where (umbang, isep) = unzip nns

laras_offset :: Theory.Layout -> Laras -> Pitch.Semi
laras_offset layout laras =
    Theory.layout_semis_per_octave layout * Pitch.pitch_octave base_pitch
        + Pitch.pitch_pc base_pitch
    where
    base_pitch = laras_base laras

laras_nns :: Laras -> [(Pitch.NoteNumber, Pitch.NoteNumber)]
laras_nns laras =
    zip (Vector.toList (laras_umbang laras)) (Vector.toList (laras_isep laras))

-- * Format

-- | This can't use backtick symbols because then the combining octave
-- characters don't combine.
balinese :: TheoryFormat.Degrees
balinese = TheoryFormat.make_degrees ["᭦", "᭡", "᭢", "᭣", "᭤"]

ioeua :: TheoryFormat.Degrees
ioeua = TheoryFormat.make_degrees ["i", "o", "e", "u", "a"]

digit_octave_relative :: TheoryFormat.Degrees -> Bool -> Theory.Key
    -> ChromaticScales.Keys -> TheoryFormat.Format
digit_octave_relative degrees chromatic default_key keys =
    TheoryFormat.make_relative_format
        ("[1-9]" <> degrees_doc degrees <> if chromatic then "#?" else "")
        degrees fmt
    where fmt = ChromaticScales.relative_fmt default_key keys

ioeua_relative :: Bool -> Theory.Key -> ChromaticScales.Keys
    -> TheoryFormat.Format
ioeua_relative = digit_octave_relative ioeua

-- | (high, middle, low)
type RelativeOctaves = (Char, Maybe Char, Char)

-- | Use ascii-art arrows for octaves.
arrow_octaves :: RelativeOctaves
arrow_octaves = ('^', Just '-', '_')

-- | Use combining marks for octaves.
balinese_octaves :: RelativeOctaves
balinese_octaves =
    ( '\x1b6b' -- balinese musical symbol combining tegeh
    , Nothing
    , '\x1b6c' -- balinese musical symbol combining endep
    )

degrees_doc :: TheoryFormat.Degrees -> Text
degrees_doc degrees = "[" <> mconcat (Vector.toList degrees) <> "]"

relative_arrow :: TheoryFormat.Degrees -> RelativeOctaves
    -> Pitch.Octave -> Bool -> Theory.Key
    -> ChromaticScales.Keys -> TheoryFormat.Format
relative_arrow degrees relative_octaves center chromatic default_key keys =
    TheoryFormat.make_relative_format
        (degrees_doc degrees <> (if chromatic then "#?" else "") <> "[_^-]")
        degrees fmt
    where
    fmt = with_config (set_relative_octaves relative_octaves center) $
        ChromaticScales.relative_fmt default_key keys

ioeua_relative_arrow :: Pitch.Octave -> Bool -> Theory.Key
    -> ChromaticScales.Keys -> TheoryFormat.Format
ioeua_relative_arrow = relative_arrow ioeua arrow_octaves

ioeua_absolute :: TheoryFormat.Format
ioeua_absolute = TheoryFormat.make_absolute_format "[1-9][ioeua]" ioeua

with_config :: (TheoryFormat.Config -> TheoryFormat.Config)
    -> TheoryFormat.RelativeFormat key -> TheoryFormat.RelativeFormat key
with_config f config = config
    { TheoryFormat.rel_config = f (TheoryFormat.rel_config config) }

set_relative_octaves :: RelativeOctaves -> Pitch.Octave
    -> TheoryFormat.Config -> TheoryFormat.Config
set_relative_octaves (high, middle, low) center =
    TheoryFormat.set_octave show_octave parse_octave
    where
    show_octave oct
        | oct > center = (<> Text.replicate (oct-center) (t high))
        | oct < center = (<> Text.replicate (center-oct) (t low))
        | otherwise = (<> maybe "" t middle)
    parse_octave p_degree = do
        (pc, acc) <- p_degree
        oct_str <- A.many' $ A.satisfy $ \c ->
            c == high || c == low || maybe True (==c) middle
        let oct_value c
                | c == high = 1
                | c == low = -1
                | otherwise = 0
        let oct = Num.sum $ map oct_value oct_str
        return $ TheoryFormat.RelativePitch (center + oct) pc acc
    t = Text.singleton

cipher_relative_dotted :: Pitch.Octave -> Theory.Key -> ChromaticScales.Keys
    -> TheoryFormat.Format
cipher_relative_dotted center default_key keys =
    TheoryFormat.make_relative_format "[12356]|`[12356][.^]*`" cipher5 fmt
    where
    fmt = with_config (dotted_octaves center) $
        ChromaticScales.relative_fmt default_key keys

cipher5 :: TheoryFormat.Degrees
cipher5 = TheoryFormat.make_degrees ["1", "2", "3", "5", "6"]

dotted_octaves :: Pitch.Octave -> TheoryFormat.Config -> TheoryFormat.Config
dotted_octaves center = TheoryFormat.set_octave show_octave parse_octave
    where
    show_octave oct d
        | oct == center = d
        | otherwise = "`" <> d
            <> (if oct >= center then Text.replicate (oct-center) "^"
                else Text.replicate (center-oct) ".")
            <> "`"
    parse_octave p_degree =
        uncurry (TheoryFormat.RelativePitch center) <$> p_degree
            <|> with_octave p_degree
    with_octave p_degree = do
        A.char '`'
        (pc, acc) <- p_degree
        octs <- A.many' $ A.satisfy $ \c -> c == '.' || c == '^'
        A.char '`'
        let oct = Lists.count (=='^') octs - Lists.count (=='.') octs
        return $ TheoryFormat.RelativePitch (center + oct) pc acc

-- * tuning

data Tuning = Umbang | Isep deriving (Eq, Ord, Enum, Bounded, Show)

instance Pretty Tuning where pretty = showt
instance Typecheck.Typecheck Tuning
instance REnv.ToVal Tuning
instance ShowVal.ShowVal Tuning

-- | If ombak is unset, use the hardcoded tunings.  Otherwise, create new
-- umbang and isep tunings based on the given number.
c_ombak :: ScoreT.Control
c_ombak = "ombak"

-- | Convert 'Pitch.FSemi' to 'Pitch.NoteNumber'.
semis_to_nn :: Theory.Layout -> LarasMap -> Laras
    -> ChromaticScales.SemisToNoteNumber
semis_to_nn layout laras default_laras =
    \(PSignal.PitchConfig env controls) fsemis_ -> do
        laras <- Scales.read_environ (\v -> Map.lookup v laras)
            (Just default_laras) laras_key env
        let fsemis = fsemis_ - fromIntegral offset
            offset = laras_offset layout laras
        tuning <- Scales.read_environ Just (Just Umbang) EnvKey.tuning env
        let err = DeriveT.out_of_range_error fsemis
                (0, Vector.length (laras_umbang laras))
        justErr err $ case Map.lookup c_ombak controls of
            Nothing -> case tuning of
                Umbang -> get_nn (laras_umbang laras) fsemis
                Isep -> get_nn (laras_isep laras) fsemis
            Just ombak -> do
                umbang <- get_nn (laras_umbang laras) fsemis
                isep <- get_nn (laras_isep laras) fsemis
                let avg = (Pitch.nn_to_hz umbang + Pitch.nn_to_hz isep) / 2
                return $ Pitch.hz_to_nn $ case tuning of
                    Umbang -> avg - ombak / 2
                    Isep -> avg + ombak / 2

-- | VStr: Select saih tuning.
laras_key :: EnvKey.Key
laras_key = "laras"

get_nn :: Vector.Vector Pitch.NoteNumber -> Pitch.FSemi
    -> Maybe Pitch.NoteNumber
get_nn nns fsemis
    | frac == 0 = nns !? semis
    | otherwise = do
        low <- nns !? semis
        high <- nns !? (semis + 1)
        return $ Num.scale low high (Pitch.nn frac)
    where (semis, frac) = properFraction fsemis
