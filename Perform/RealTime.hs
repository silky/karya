-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable #-}
{- | RealTime represents seconds, as opposed to ScoreTime, which are abstract
    units.  Everything eventually is transformed into RealTime to be
    performed.

    This type has switched from floating point to decimal and back again.  The
    problem is that floating point is not exact, but there are a few
    operations that require events that have the same ScoreTime to be grouped
    with each other once they reach RealTime.  For instance, controls are
    clipped to the note boundaries, and a note is required to have a pitch at
    exactly its starting time.  While the event that produces the pitch signal
    may have the same ScoreTime as the note it belongs to, if imprecision has
    caused it to drift a little by the time it gets to performance, the note
    may wind up with no initial pitch, or pick up the pitch of the next note
    as a pitch bend.

    An example of how imprecision can accumulate is a block call with pitch
    set in the caller.  If the sub-block has a note at 0 this should line up
    with the start of the block call in the super-block and hence with a pitch
    at the same time.  But the sub-block has its own warp which is
    a composition of the its tempo and the super-block's tempo.  In theory the
    sub-block's warp should be shifted so its 0 starts at the calling point
    in the super-block, but in practice this is a number of floating point
    operations (addition, linear interpolation, ...) and the value may very
    well be slightly different.

    Unfortunately switching RealTime to a lower-precision decimal type has the
    same problem because it introduces even more imprecision due to the
    ScoreTime -> RealTime -> ScoreTime conversion (this happens during warp
    composition, for instance, since shift and stretch are in ScoreTime).
    And I think it's ultimately not quite right because rounding will still
    produce incorrect results if the imprecise value falls at a rounding
    boundary.

    Eventually, for MIDI at least, everything is rounded down to milliseconds
    so hopefully any imprecision can be accounted for by the operations that
    care about it and eventually be removed from the final result.
-}
module Perform.RealTime (
    RealTime, div, mul, large, suffix
    , show_units
    -- * convert from
    , seconds, milliseconds, microseconds, score
    -- * convert to
    , to_seconds, to_milliseconds, to_microseconds, to_score
    -- * misc
    , eta, (==), (>), (<=)
) where
import qualified Prelude
import Prelude hiding ((==), (>), (<=), div)
import qualified Control.DeepSeq as DeepSeq
import qualified Data.Digest.CRC32 as CRC32
import qualified Data.Text as Text
import qualified Data.Typeable as Typeable

import qualified Foreign
import qualified Text.Read as Read

import qualified Util.ApproxEq as ApproxEq
import Util.Crc32Instances ()
import qualified Util.ForeignC as C
import qualified Util.Pretty as Pretty
import qualified Util.Serialize as Serialize

import qualified Ui.ScoreTime as ScoreTime
import qualified Ui.Util as Util
import Global


-- | A concrete unit of time.
--
-- This must have negative values because it's used for signals, which are
-- used for the warp map, which is oriented with zero at the note start.  If
-- a note wants to get the real time before it, it must look up a negative
-- RealTime.
newtype RealTime = RealTime Double deriving
    ( DeepSeq.NFData, Num, Fractional, Real, RealFrac, Eq, Ord
    , Serialize.Serialize, CRC32.CRC32, ApproxEq.ApproxEq
    , Typeable.Typeable
    )

-- I could derive Storable, but technically speaking Double is not necessarily
-- the same as CDouble.
instance Foreign.Storable RealTime where
    sizeOf _ = Foreign.sizeOf (0 :: C.CDouble)
    alignment _ = Foreign.alignment (0 :: C.CDouble)
    poke p (RealTime d) = Foreign.poke (Foreign.castPtr p) (Util.c_double d)
    peek p = RealTime . Util.hs_double <$> Foreign.peek (Foreign.castPtr p)

instance C.CStorable RealTime where
    sizeOf = Foreign.sizeOf
    alignment = Foreign.alignment
    peek = Foreign.peek
    poke = Foreign.poke

instance Show RealTime where show (RealTime t) = show t
instance Read.Read RealTime where readPrec = RealTime <$> Read.readPrec

instance Pretty.Pretty RealTime where
    pretty t = Pretty.showFloat 2 (to_seconds t) <> Text.singleton suffix

div :: RealTime -> Double -> RealTime
div a b = seconds (to_seconds a / b)
infixl 7 `div`

mul :: RealTime -> Double -> RealTime
mul a b = seconds (to_seconds a * b)
infixl 7 `mul`

-- | A large RealTime that is also not the max bound so it won't overflow
-- too easily, and will also fit in a Signal.Y.
large :: RealTime
large = RealTime (2^32)

suffix :: Char
suffix = 's'

-- | Show RealTime as hours, minutes, seconds.
show_units :: RealTime -> Text
show_units t = units <> pretty (seconds (fromIntegral secs + frac))
    where
    units = mconcatMap (\(a, b) -> showt a <> b) $
        filter ((Prelude.>0) . fst) [(hours, "h"), (mins, "m")]
    (t1, frac) = properFraction (to_seconds t)
    (hours, t2) = t1 `divMod` (60 * 60)
    (mins, secs) = t2 `divMod` 60

-- * convert from

seconds :: Double -> RealTime
seconds = RealTime

milliseconds :: Integer -> RealTime
milliseconds = seconds . (/1000) . fromIntegral

microseconds :: Integer -> RealTime
microseconds = seconds . (/1000000) . fromIntegral

score :: ScoreTime.ScoreTime -> RealTime
score = seconds . ScoreTime.to_double

-- * convert to

to_seconds :: RealTime -> Double
to_seconds (RealTime s) = s

to_milliseconds :: RealTime -> Integer
to_milliseconds = round . (*1000) . to_seconds

to_microseconds :: RealTime -> Integer
to_microseconds = round . (*1000000) . to_seconds

to_score :: RealTime -> ScoreTime.ScoreTime
to_score = ScoreTime.double . to_seconds

-- | Eta for comparison.  Since RealTimes are seconds, this amount of time is
-- definitely unnoticeable.
eta :: RealTime
eta = 0.0000000000004

-- | RealTimes are imprecise, so compare them with this instead of (==).
(==) :: RealTime -> RealTime -> Bool
(==) = ApproxEq.eq (to_seconds eta)

(>), (<=) :: RealTime -> RealTime -> Bool
a > b = a - eta Prelude.> b
a <= b = not (a > b)
