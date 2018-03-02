-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DeriveGeneric #-}
-- | The 'Sample' type and support.
module Synth.Sampler.Sample where
import System.FilePath ((</>))

import qualified Util.ApproxEq as ApproxEq
import qualified Util.Audio.Audio as Audio
import qualified Util.Audio.File as Audio.File
import qualified Util.Audio.Resample as Resample
import qualified Util.Num as Num

import Synth.Lib.Global
import qualified Synth.Sampler.Config as Config
import qualified Synth.Shared.Signal as Signal


-- | Path to a sample, relative to the instrument db root.
type SamplePath = FilePath

-- | Low level representation of a note.  This corresponds to a single sample
-- played.
data Sample = Sample {
    start :: !RealTime
    -- | Relative to 'Config.instrumentDbDir'.
    , filename :: !SamplePath
    -- | Sample start offset.
    , offset :: !RealTime
    -- | The sample ends when it runs out of samples, or when envelope ends
    -- on 0.
    , envelope :: !Signal.Signal
    -- | Sample rate conversion ratio.  This controls the pitch.
    , ratio :: !Signal.Signal
    } deriving (Show)

-- | Evaluating the Audio could probably produce more exceptions...
realize :: Resample.ConverterType -> Sample -> (RealTime, Audio)
realize quality (Sample start filename offset env ratio) = (start,) $
    resample quality (Signal.at start ratio) $
    applyEnvelope start env $
    Audio.File.read (Config.instrumentDbDir </> filename)
    -- TODO use offset

resample :: Resample.ConverterType -> Double -> Audio -> Audio
resample quality ratio audio
    -- Don't do any work if it's close enough to 1.
    | ApproxEq.eq closeEnough ratio 1 = audio
    | otherwise = Resample.resample quality ratio audio
    where
    -- More or less a semitone / 100 cents / 10.  Anything narrower than this
    -- probably isn't perceptible.
    closeEnough = 1.05 / 1000

applyEnvelope :: RealTime -> Signal.Signal -> Audio -> Audio
applyEnvelope start sig
    | ApproxEq.eq 0.01 val 1 = id
    | otherwise = Audio.gain val
    where val = Num.d2f (Signal.at start sig)
    -- TODO scale by envelope, and shorten the audio if the 'sig' ends on 0
