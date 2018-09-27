-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Definitions for the wayang instrument family.
module Synth.Sampler.Patch.Wayang (convert, load, Patch) where
import qualified Data.Either as Either
import qualified Data.Map as Map
import qualified Data.Text as Text

import qualified System.Directory as Directory
import qualified System.FilePath as FilePath
import System.FilePath ((</>))

import qualified Text.Parsec as P

import qualified Util.Parse as Parse
import qualified Midi.Key as Key
import qualified Midi.Midi as Midi
import qualified Perform.Pitch as Pitch
import qualified Synth.Sampler.Patch as Patch
import qualified Synth.Shared.Note as Note

import Global


type Error = Text

sampleDir :: FilePath
sampleDir = "../data/sampler/wayang"

-- Convert Note.Note into Sample.Sample
-- Must be deterministic, which means the Variation has to be in the Note.
convert :: Note.Note -> Either Error (FilePath, Patch.Sample)
convert = undefined

load :: IO (Either [FilePath] Patch)
load = loadPatch sampleDir

-- * implementation

data Patch = Patch {
    _samples :: Map (Instrument, Tuning) [Sample]
    } deriving (Eq, Show)

data Instrument = Pemade | Kantilan deriving (Eq, Ord, Show)
data Tuning = Umbang | Isep deriving (Eq, Ord, Show)

data Sample = Sample {
    _filename :: !FilePath
    , _pitch :: !Pitch.NoteNumber
    , _dynamic :: !Dynamic
    , _articulation :: !Articulation
    , _variation :: !Variation
    } deriving (Eq, Show)

data Dynamic = PP | MP | MF | FF
    deriving (Eq, Show)

data Articulation = Mute | LooseMute | Open | CalungMute | Calung
    deriving (Eq, Show)

type Variation = Int

loadPatch :: FilePath -> IO (Either [FilePath] Patch)
loadPatch rootDir = do
    (errs, samples) <- Either.partitionEithers <$> parseAll rootDir
    return $ if null errs
        then Right $ Patch (Map.fromList samples)
        else Left errs

parseAll :: FilePath -> IO [Either FilePath ((Instrument, Tuning), [Sample])]
parseAll rootDir = mapM parse
    [ (Pemade, Umbang)
    , (Pemade, Isep)
    , (Kantilan, Umbang)
    , (Kantilan, Isep)
    ]
    where
    parse (inst, tuning) =
        fmap ((inst, tuning),) . sequence <$>
            ((++) <$> parseDir (keyToNn nns) (rootDir </> dir </> "normal")
                <*> parseDir (keyToNn nns) (rootDir </> dir </> "calung"))
        where (nns, dir) = nnsDir (inst, tuning)
    nnsDir = \case
        (Pemade, Umbang) -> (pemadeUmbang, "pemade/umbang")
        (Pemade, Isep) -> (pemadeIsep, "pemade/isep")
        (Kantilan, Umbang) -> (kantilanUmbang, "kantilan/umbang")
        (Kantilan, Isep) -> (kantilanIsep, "kantilan/isep")

parseDir :: KeyToNn -> FilePath -> IO [Either FilePath Sample]
parseDir toNn dir =
    map (\fn -> maybe (Left fn) Right $ parseFilename toNn fn) <$>
        Directory.listDirectory dir

parseFilename :: KeyToNn -> FilePath -> Maybe Sample
parseFilename toNn filename =
    parse . Text.split (=='-') . txt . FilePath.dropExtension $ filename
    where
    parse [key, lowVel, highVel, group] = do
        dyn <- flip Map.lookup dyns =<< (,) <$> pNat lowVel <*> pNat highVel
        (art, var) <- parseArticulation group
        nn <- toNn art . Midi.Key =<< pNat key
        return $ Sample
            { _filename = filename
            , _pitch = nn
            , _dynamic = dyn
            , _articulation = art
            , _variation = var
            }
    parse _ = Nothing

pNat :: Text -> Maybe Int
pNat = try . Parse.parse Parse.p_nat

try :: Either Text a -> Maybe a
try = either (const Nothing) return

parseArticulation :: Text -> Maybe (Articulation, Variation)
parseArticulation = try . Parse.parse p
    where
    p = (,) <$> pArticulation <*> (P.optional (P.string "+v") *> Parse.p_nat)
    match (str, val) = P.try (P.string str) *> pure val
    pArticulation = P.choice $ map match
        [ ("mute", Mute)
        , ("loose", LooseMute)
        , ("open", Open)
        , ("calung+mute", CalungMute)
        , ("calung", Calung)
        ]

{-
    sample structure:
    pemade/{isep,umbang}/normal/$key-$lowVel-$highVel-$group.wav
    group = mute{1..8} loose{1..8} open{1..4}

    100-1-31-calung{1..3}.wav
    29-1-31-calung+mute{1..6}.wav

    mute and loose start at Key.f0 (17)
    open starts at Key.f4 65
-}
dyns :: Map (Int, Int) Dynamic
dyns = Map.fromList
    [ ((1, 31), PP)
    , ((32, 64), MP)
    , ((65, 108), MF)
    , ((109, 127), FF)
    ]

type KeyToNn = Articulation -> Midi.Key -> Maybe Pitch.NoteNumber

keyToNn :: ((Instrument, a), [Pitch.NoteNumber]) -> KeyToNn
keyToNn ((inst, _), nns) art key = lookup key keyNns
    where
    keyNns = zip keys nns
    keys = wayangKeys $ (if inst == Kantilan then (+1) else id) $ case art of
        Mute -> 1
        LooseMute -> 1
        CalungMute -> 1
        Open -> 5
        Calung -> 5

pemadeMute = wayangKeys 1
pemadeOpen = wayangKeys 5

kantilanMute = wayangKeys 2
kantilanOpen = wayangKeys 6

wayangKeys :: Int -> [Midi.Key]
wayangKeys oct = map (Midi.to_key (oct * 12) +)
    (take 10 $ drop 1 [k + o*12 | o <- [0..], k <- baseKeys])
    where
    -- ding dong deng dung dang
    baseKeys = [Key.e_1, Key.f_1, Key.a_1, Key.b_1, Key.c0]

pemadeUmbang :: ((Instrument, Tuning), [Pitch.NoteNumber])
pemadeUmbang = ((Pemade, Umbang),) $ map toNN
    [ (Key.f3, 55)
    , (Key.g3, 43)
    , (Key.as3, 56)
    , (Key.c4, 20)
    , (Key.ds4, 54)
    , (Key.f4, 50)
    , (Key.gs4, 68)
    , (Key.as4, 69)
    , (Key.c5, 18)
    , (Key.ds5, 34)
    ]

pemadeIsep :: ((Instrument, Tuning), [Pitch.NoteNumber])
pemadeIsep = ((Pemade, Isep),) $ map toNN
    [ (Key.f3, 0)
    , (Key.g3, -7)
    , (Key.as3, 0)
    , (Key.c4, -36)
    , (Key.ds4, 0)
    , (Key.f4, 28)
    , (Key.gs4, 39)
    , (Key.as4, 51)
    , (Key.c5, -12)
    , (Key.ds5, 16)
    ]

kantilanUmbang :: ((Instrument, Tuning), [Pitch.NoteNumber])
kantilanUmbang = ((Kantilan, Umbang),) $ map toNN
    [ (Key.e4, -31)
    , (Key.g4, -13)
    , (Key.a4, -23)
    , (Key.c5, 20)
    , (Key.ds5, 44)
    , (Key.f5, 24)
    , (Key.g5, -36)
    , (Key.as5, 48)
    , (Key.c6, -1)
    , (Key.ds6, 21)
    ]

kantilanIsep :: ((Instrument, Tuning), [Pitch.NoteNumber])
kantilanIsep = ((Kantilan, Isep),) $ map toNN
    [ (Key.e4, 23)
    , (Key.gs4, 55)
    , (Key.as4, 55)
    , (Key.c5, -1)
    , (Key.ds5, 20)
    , (Key.f5, 12)
    , (Key.gs5, 50)
    , (Key.as5, 35)
    , (Key.c6, -13)
    , (Key.ds6, 11)
    ]

-- NN +cents to adjust to that NN
toNN :: (Midi.Key, Int) -> Pitch.NoteNumber
toNN (key, cents) = Pitch.key_to_nn key - Pitch.nn cents / 100

{-
    Use this to get absolute pitches for samples:

    pemade umbang 12
        start f2, midi 53
        f+.55 g+.43 a#+.56 c+.2 d#+.54 f+.50 g#+.68 a#+.69 c+.18 d#+.34
    pemade isep 12
        start f2, midi 53
        f+0 g-.07 a#+0 c-.36 d#+0 f+.28 g#+.39 a#+.51 c-.12 d#+.16
        down to prev c, up to next g
    kantilan umbang 12
        start e3, midi 64
        e-.31 g-.13 a-.23 c+.2 d#+.44 f+.24 g-.36 a#+.48 c-.01 d#+.21
        down to prev c, up to next g
    kantilan isep 12
        start e3, midi 64
        e+.23 g#+.55 a#+.55 c-.01 d#+.2 f+.12 g#+.5 a#+.35 c-.13 d#+11
        down to prev c, up to next g
-}
