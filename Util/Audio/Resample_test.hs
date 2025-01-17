-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DataKinds, KindSignatures #-}
module Util.Audio.Resample_test where
import qualified Control.Monad.Trans.Resource as Resource

import qualified Util.Audio.Audio as Audio
import qualified Util.Audio.File as File
import qualified Util.Audio.Resample as Resample
import qualified Util.Segment as Segment

import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import           Util.Test


-- TODO
-- because I don't have a proper package system, to run these from ghci you
-- must pass -lsamplerate

test_segmentAt :: Test
test_segmentAt = do
    let f = Resample.segmentAt 2
    let sig = Signal.from_pairs [(0, 0), (1.25, 1), (4, 0)]
    equal (f 0 sig) $ Segment.Segment 0 0 1.25 1
    equal (f 1 sig) $ Segment.Segment 1.25 1 4 0
    equal (f 3.75 sig) $ Segment.Segment 4 0 RealTime.large 0

{- It's hard to test these automatically, so I tested by ear.
    Test for each of:

    [ test
    -- sine for pitch accuracy, file for continuity
    | source <- [Sine 2, File "test.wav"]
    , quality <- [Resample.ZeroOrderHold, Resample.SincFastest,
        Resample.SincBestQuality]
    ]
-}
generate = resampleBy (File "test.wav") -- (Sine 2)
    "out.wav" Resample.SincBestQuality

-- Should be 220hz, *2 long.
t_constant = generate [(0, 2)]

-- Should reach 440hz at 0.5s, > *1 long.
t_linear = generate [(0, 2), (0.5, 1)]

-- Should go 880 to 440 to 880 at breakpoints.
t_change_direction = generate [(0, 0.5), (0.5, 1), (1, 0.5)]

-- Shoud go to 440 at 0.5 and jump to 220.
t_discontinuity = generate [(0, 2), (0.5, 1), (0.5, 2), (1, 1)]

data Source = Sine Double | File FilePath
    deriving (Show)

resampleBy :: Source -> FilePath -> Resample.Quality
    -> [(Signal.X, Signal.Y)] -> IO ()
resampleBy source out quality curve = write out $ Audio.gain 0.5 $ Audio.mix
    [ Audio.expandChannels $ Audio.takeS 2 $ Audio.sine 440
    , Resample.resampleBy (Resample.defaultConfig quality)
            (Signal.from_pairs curve) $
        case source of
            Sine secs ->
                Audio.expandChannels $ Audio.takeS secs $ Audio.sine 440
            File fname -> File.read fname
    ]

resampleRate out = writeRate out $
    Resample.resampleRate Resample.SincBestQuality $
    File.read44k "test.wav"
    where
    writeRate :: FilePath -> Audio.AudioIO 22100 2 -> IO ()
    writeRate fname = Resource.runResourceT . File.write File.wavFormat fname

write :: FilePath -> Audio.AudioIO 44100 2 -> IO ()
write fname = Resource.runResourceT . File.write File.wavFormat fname
