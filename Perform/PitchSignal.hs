{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
{- | A PitchSignal has pitches instead of numbers.

    Pitches are more complicated than numbers because they represent a point on
    a scale.  The difference between scale degrees may vary, so if I store
    absolute logarithmic note numbers pitches become non-transposable.  But if
    I store scale degrees then I can't interpolate between them regularly.

    In other words, a pitch slide from 1 to 2 followed by a pitch slide from
    2 to 3 is not the same as a pitch slide from 1 to 3.  For instance, given
    a scale with a mapping from scale degree to tempered note number as
    follows:

    @1 -> 1.0@, @2 -> 2.0@, @3 -> 2.5@

    A slide from 1 to 2 to 3 will look like @[1.0, 1.5, 2.0, 2.25, 2.5]@, but
    a slide from 1 to 3 in the same time will look like
    @[1.0, 1.4, 1.8, 2.6, 3.0]@.

    So pitches are stored as a triple, @(from, to, at)@.  @from@ and @to@
    represent possibly fractional scale degrees, and @at@ is a number between
    0 and 1 representing where in the @(from, to)@ range the pitch lies.  This
    way a pitch can still be transposed by modifying @from@ and @to@ and the
    actual interpolation to an absolute pitch is delayed until the performance.
-}
module Perform.PitchSignal (
    PitchSignal, Relative, sig_scale, sig_vec
    , X, Y, max_x, default_srate

    , signal, constant, empty, track_signal, Method(..), Segment
    , unpack

    , at, at_linear, sample
    , convert

    , sig_add
    , sig_max, sig_min, clip_max, clip_min
    , truncate
    , map_x
) where
import Prelude hiding (truncate)
import qualified Data.List as List
import qualified Data.StorableVector as V
import qualified Foreign.Storable as Storable
import qualified Util.Num as Num

import Ui

import qualified Perform.Pitch as Pitch
import qualified Perform.SignalBase as SignalBase
import Perform.SignalBase (Method(..), max_x, default_srate)
import qualified Perform.Signal as Signal


data PitchSignal = PitchSignal
    { sig_scale :: Pitch.ScaleId
    , sig_vec :: SignalBase.SigVec Y
    } deriving (Eq)

-- | Signal generated by relative pitch tracks.
--
-- It should be lacking a scale, but is the same type as PitchSignal for
-- convenience, and to document the functions that treat their first and second
-- arguments differently, like 'sig_max'.
type Relative = PitchSignal

modify_vec :: (SignalBase.SigVec Y -> SignalBase.SigVec Y)
    -> PitchSignal -> PitchSignal
modify_vec f sig = sig { sig_vec = f (sig_vec sig) }

type X = SignalBase.X
-- | Each sample is @(from, to, at)@, where @at@ is a normalized value between
-- 0 and 1 describing how far between @from@ and @to@ the value is.  @from@ and
-- @to@ are really Pitch.Degree, but are Floats here to save space.
--
-- This encoding consumes 12 bytes, but it seems like it should be possible to
-- reduce that.  There will be long sequences of samples with the same @from@
-- and @to@, and 'y_at' cares only about the first @from@ and the second @to@.
-- @(from, to, [(X, at)])@ is an obvious choice, but putting X inside the
-- sample will make the SignalBase stuff tricky... unless I have an extract_x
-- method.  Still, the list is variable length and StorableVector can't do
-- that.
type Y = (Float, Float, Float)
instance SignalBase.Signal Y

instance Storable.Storable (X, Y) where
    sizeOf _ = Storable.sizeOf (undefined :: Double)
        + Storable.sizeOf (undefined :: Float) * 3
    alignment _ = Storable.alignment (undefined :: Double)
    poke cp (pos, (from, to, at)) = do
        Storable.pokeByteOff cp 0 pos
        Storable.pokeByteOff cp 8 from
        Storable.pokeByteOff cp 12 to
        Storable.pokeByteOff cp 16 at
    peek cp = do
        pos <- Storable.peekByteOff cp 0 :: IO Double
        from <- Storable.peekByteOff cp 8 :: IO Float
        to <- Storable.peekByteOff cp 12 :: IO Float
        at <- Storable.peekByteOff cp 16 :: IO Float
        return (TrackPos pos, (from, to, at))

instance SignalBase.Y Y where
    zero_y = (0, 0, 0)
    y_at x0 (_, to0, at0) x1 (from1, _, at1) x = (to0, from1, at)
        where at = Num.scale at0 at1 (Num.normalize x0 x1 x)
    project y0 y1 at = (realToFrac y0, realToFrac y1, realToFrac at)

instance Show PitchSignal where
    show (PitchSignal scale_id vec) =
        "PitchSignal (" ++ show scale_id ++ ") " ++ show (V.unpack vec)

-- * construction / deconstruction

signal :: Pitch.ScaleId -> [(X, Y)] -> PitchSignal
signal scale_id ys = PitchSignal scale_id (V.pack ys)

empty :: PitchSignal
empty = constant (Pitch.ScaleId "empty signal")
    (Pitch.Degree Signal.invalid_pitch)

constant :: Pitch.ScaleId -> Pitch.Degree -> PitchSignal
constant scale_id (Pitch.Degree n) =
    signal scale_id [(0, (realToFrac n, realToFrac n, 0))]

type Segment = (TrackPos, Method, Pitch.Degree)

track_signal :: Pitch.ScaleId -> X -> [Segment] -> PitchSignal
track_signal scale_id srate segs = PitchSignal scale_id
    (SignalBase.track_signal srate
        [(pos, meth, g) | (pos, meth, Pitch.Degree g) <- segs])

-- | Used for tests.
unpack :: PitchSignal -> [(X, Y)]
unpack = V.unpack . sig_vec

-- * access

at, at_linear :: X -> PitchSignal -> Y
at pos sig = SignalBase.at pos (sig_vec sig)
at_linear pos sig = SignalBase.at_linear pos (sig_vec sig)

sample :: X -> PitchSignal -> [(X, Y)]
sample start sig = SignalBase.sample start (sig_vec sig)

-- | Flatten a pitch signal into an absolute note number signal.
convert :: Pitch.Scale -> PitchSignal -> Signal.NoteNumber
convert scale psig = Signal.Signal (V.map f (sig_vec psig))
    where
    f (x, (from, to, at)) = case (to_nn from, to_nn to) of
        (Just nn0, Just nn1) -> (x, Num.scale nn0 nn1 at)
        _ -> (x, Signal.invalid_pitch)
    to_nn n = fmap un_nn
        (Pitch.scale_degree_to_nn scale (Pitch.Degree (realToFrac n)))
    un_nn (Pitch.NoteNumber n) = n

-- * functions

sig_add :: PitchSignal -> Relative -> PitchSignal
sig_add = sig_op add
    where
    add y0@(from0, to0, _) y1@(from1, to1, _) = (from, to, at)
        where
        (from, to) = (from0 + from1, to0 + to1)
        at = Num.normalize from to (realToFrac (reduce y0 + reduce y1))

sig_max, sig_min :: PitchSignal -> Relative -> PitchSignal
sig_max = sig_op $ \y0 y1 -> ymax (reduce y1) y0
sig_min = sig_op $ \y0 y1 -> ymin (reduce y1) y0

-- | Scalar versions of 'sig_max' and 'sig_min'.  Note that the arguments are
-- also reversed for currying convenience.
clip_max, clip_min :: Pitch.NoteNumber -> PitchSignal -> PitchSignal
clip_max (Pitch.NoteNumber nn) = map_y (ymin nn)
clip_min (Pitch.NoteNumber nn) = map_y (ymax nn)

ymin, ymax :: Double -> Y -> Y
ymin val (from, to, at) = (from, to, at2)
    where at2 = Num.clamp 0 at (Num.normalize from to (realToFrac val))
ymax val (from, to, at) = (from, to, at2)
    where at2 = Num.clamp at 1 (Num.normalize from to (realToFrac val))

truncate :: X -> PitchSignal -> PitchSignal
truncate x = modify_vec (SignalBase.truncate x)

-- | Combine two PitchSignals with a binary operator.  This ignores the
-- scale of the second signal, so anyone who wants to warn about that should do
-- it separately.
sig_op :: (Y -> Y -> Y) -> PitchSignal -> Relative -> PitchSignal
sig_op op (PitchSignal scale vec0) (PitchSignal _ vec1) =
    PitchSignal scale (SignalBase.sig_op op vec0 vec1)

map_x :: (X -> X) -> PitchSignal -> PitchSignal
map_x f = modify_vec (SignalBase.map_x f)

map_y :: (Y -> Y) -> PitchSignal -> PitchSignal
map_y f = modify_vec (SignalBase.map_y f)

reduce :: Y -> Signal.Y
reduce (from, to, at) = Num.scale (realToFrac from) (realToFrac to) at
