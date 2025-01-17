-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | General utilities for sampler patches.
module Synth.Sampler.Patch.Lib.Util where
import qualified Control.Monad.Except as Except
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text

import qualified GHC.Stack as Stack

import qualified Util.Maps as Maps
import qualified Util.Num as Num
import qualified Util.Lists as Lists

import qualified Cmd.Instrument.CUtil as CUtil
import qualified Cmd.Instrument.ImInst as ImInst
import qualified Derive.Attrs as Attrs
import qualified Instrument.Common as Common
import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Synth.Sampler.Patch as Patch
import qualified Synth.Sampler.Sample as Sample
import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note
import qualified Synth.Shared.Thru as Thru
import qualified Synth.Shared.Signal as Signal

import           Global


-- * preprocess

nextsBy :: Eq key => (a -> key) -> [a] -> [(a, [a])]
nextsBy key xs = zipWith extract xs (drop 1 (List.tails xs))
    where extract x xs = (x, filter ((== key x) . key) xs)

nexts :: [a] -> [(a, [a])]
nexts xs = zip xs (drop 1 (List.tails xs))


-- * convert

-- ** pitch

symbolicPitch :: Except.MonadError Text m => Note.Note
    -> m (Either Pitch.Note Pitch.NoteNumber)
symbolicPitch note
    | Text.null (Note.element note) = Right <$> initialPitch note
    | otherwise = return $ Left $ Pitch.Note $ Note.element note

initialPitch :: Except.MonadError Text m => Note.Note -> m Pitch.NoteNumber
initialPitch = tryJust "no pitch" . Note.initialPitch

-- | Find a value (presumably a FileName) and pitch ratio for a simple patch
-- with a static NoteNumber mapping.
findPitchRatio :: Map Pitch.NoteNumber a -> Pitch.NoteNumber -> (a, Signal.Y)
findPitchRatio nnToSample nn = (fname, Sample.pitchToRatio sampleNn nn)
    where
    (sampleNn, fname) = fromMaybe (error "findPitch: empty nnToSample") $
        Maps.lookupClosest nn nnToSample

-- ** articulation

articulation :: Except.MonadError Text m => Common.AttributeMap a
    -> Attrs.Attributes -> m a
articulation attributeMap attrs =
    maybe (Except.throwError $ "attributes not found: " <> pretty attrs)
        (return . snd) $
    Common.lookup_attributes attrs attributeMap

articulationDefault :: a -> Common.AttributeMap a -> Attrs.Attributes -> a
articulationDefault deflt attributeMap  =
    maybe deflt snd . (`Common.lookup_attributes` attributeMap)

-- ** dynamic

-- | Standard dynamic ranges.
data Dynamic = PP | MP | MF | FF
    deriving (Eq, Ord, Show, Read, Bounded, Enum)
instance Pretty Dynamic where pretty = showt

-- | Get patch-specific dyn category, and note dynamic.
dynamic :: (Bounded dyn, Enum dyn) => (dyn -> (Int, Int))
    -- ^ Returns velocity instead of dyn, and the lower bound is unnecessary,
    -- for compatibility.
    -> Signal.Y
    -- ^ Min dyn.  This is for normalized samples, where 0 gets this dyn.
    -> Note.Note -> (dyn, Signal.Y)
dynamic dynToRange minDyn note =
    ( fst $ findDynamic (velToDyn . snd . dynToRange) dyn
    , Num.scale minDyn 1 dyn
    )
    where dyn = Note.initial0 Control.dynamic note

-- | Convert to (Dynamic, DistanceFromPrevDynamic)
findDynamic :: (Bounded dyn, Enum dyn) => (dyn -> Signal.Y)
    -> Signal.Y -> (dyn, Signal.Y)
findDynamic dynToRange dyn = find 0 dyn rangeDynamics
    where
    find low val ((high, dyn) : rest)
        | null rest || val < high = (dyn, Num.normalize low high val)
        | otherwise = find high val rest
    find _ _ [] = error "empty rangeDynamics"
    rangeDynamics = Lists.keyOn dynToRange enumAll

type Variation = Int

variation :: Variation -> Note.Note -> Variation
variation variations = pick . Note.initial0 Control.variation
    where pick var = round (var * fromIntegral (variations - 1))

chooseVariation :: [a] -> Note.Note -> a
chooseVariation as = pickVariation as . Note.initial0 Control.variation

pickVariation :: [a] -> Double -> a
pickVariation as var =
    as !! round (Num.clamp 0 1 var * fromIntegral (length as - 1))

-- | Pick from a list of dynamic variations.
pickDynamicVariation :: Double -> [a] -> Double -> Double -> a
pickDynamicVariation variationRange samples dyn var =
    pickVariation samples (Num.clamp 0 1 (dyn + var * variationRange))

-- | Scale dynamic for non-normalized samples, recorded with few dynamic
-- levels.  Since each sample already has its own dynamic level, if I do no
-- scaling, then there will be noticeable bumps as the dynamic thresholds
-- are crossed.  So I scale the dynamics of each one by an adjustment to smooth
-- the bumps.  But the result will be more bumpy if each sample covers a
-- different width of dynamic range, so I also scale the adjustment by
-- that width.
--
-- TODO I think it doesn't actually work though, I need to adjust manually
-- per-sample.
dynamicAutoScale :: (Signal.Y, Signal.Y) -> (Signal.Y, Signal.Y) -> Signal.Y
    -> Signal.Y
dynamicAutoScale (minDyn, maxDyn) (low, high) dyn =
    Num.scale minDyn maxDyn biased
    where
    -- dyn should be in the (low, high) range already.
    pos = Num.normalize low high dyn
    -- bias the position toward the middle of the dyn range, depending on
    -- the dynamic width allocated to the sample.
    biased = Num.scale 0.5 pos (high - low)

dynToVel :: Signal.Y -> Int
dynToVel = Num.clamp 1 127 . round . (*127)

velToDyn :: Int -> Signal.Y
velToDyn = (/127) . fromIntegral

-- ** envelope

dynEnvelope :: Signal.Y -> RealTime.RealTime -> Note.Note -> Signal.Signal
dynEnvelope minDyn releaseTime note =
    env <> Signal.from_pairs [(end, Signal.at end env), (end + releaseTime, 0)]
    where
    end = Note.end note
    env = Signal.scalar_scale minDyn $
        Signal.drop_before (Note.start note) $
        Signal.clip_after (Note.end note) $
        Map.findWithDefault mempty Control.dynamic $
        Note.controls note

-- | Simple sustain-release envelope.
sustainRelease :: Signal.Y -> RealTime.RealTime -> Note.Note -> Signal.Signal
sustainRelease sustain releaseTime note = Signal.from_pairs
    [ (Note.start note, sustain), (Note.end note, sustain)
    , (Note.end note + releaseTime, 0)
    ]

-- * thru

thru :: FilePath -> (Note.Note -> Patch.ConvertM Sample.Sample)
    -> ImInst.Code
thru sampleDir convert = ImInst.thru $ thruFunction sampleDir convert

imThruFunction :: FilePath -> (Note.Note -> Patch.ConvertM Sample.Sample)
    -> CUtil.Thru
imThruFunction dir = CUtil.ImThru . thruFunction dir

thruFunction :: FilePath -> (Note.Note -> Patch.ConvertM Sample.Sample)
    -> Thru.ThruFunction
thruFunction sampleDir convert = fmap Thru.Plays . mapM note
    where
    note (Thru.Note pitch velocity attrs offset) = do
        (sample, _logs) <- Patch.runConvert $ convert $ (Note.note "" "" 0 1)
            { Note.attributes = attrs
            , Note.controls = Map.fromList
                [ (Control.pitch, Signal.constant (Pitch.nn_to_double pitch))
                , (Control.dynamic, Signal.constant velocity)
                , (Control.sampleStartOffset,
                    Signal.constant (fromIntegral offset))
                ]
            }
        return $ Sample.toThru sampleDir sample

-- * util

requireMap :: (Ord k, Show k) => Text -> Map k a -> k -> Patch.ConvertM a
requireMap name m k =
    tryJust ("no " <> name <> ": " <> showt k) $ Map.lookup k m

enumAll :: (Enum a, Bounded a) => [a]
enumAll = [minBound .. maxBound]

findBelow :: Ord k => (a -> k) -> k -> [a] -> a
findBelow _ _ [] = error "empty list"
findBelow key val (x:xs) = go x xs
    where
    go x0 (x:xs)
        | val < key x = x0
        | otherwise = go x xs
    go x0 [] = x0

showLower :: Show a => a -> String
showLower = map Char.toLower . show

showtLower :: Show a => a -> Text
showtLower = txt . showLower

assertLength :: (Stack.HasCallStack, Foldable t) => Int -> t a -> t a
assertLength len xs
    | length xs == len = xs
    | otherwise = error $ "expected length " <> show len <> ", but was "
        <> show (length xs)
