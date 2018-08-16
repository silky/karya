-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Provide short names and operators for writing korvais in haskell.  This
    module is the shared global namespace between "Solkattu.SolkattuGlobal" and
    "Solkattu.MridangamGlobal".

    Operators:

    > infixl 9 ^ § & -- also •, which replaces prelude (.)
    > infixl 8 <== ==>
    > infixr 6 . -- same as (<>)
-}
module Solkattu.Dsl (
    (.), (•), ø
    , karvai

    -- * directives
    , hv, lt
    , akshara, sam, (§)
    -- * abstraction
    , Abstraction
    , patterns, groups
    -- * patterns
    , pat, p5, p6, p7, p8, p9, p666, p567, p765
    -- * re-exports
    , module Solkattu.Korvai
    , module Solkattu.MetadataGlobal
    , module Solkattu.Notation
    , module Solkattu.Part
    , module Solkattu.SectionGlobal
    , module Solkattu.S
    , module Solkattu.Solkattu
    , module Solkattu.Tala
    -- * mridangam
    , (&)
    -- * misc
    , pprint
    -- * talam
    , beats
    , adi
    -- * conveniences
    , ganesh, janahan, sriram, sudhindra
    , Pretty -- signatures wind up being Pretty sollu => ...
) where
import qualified Prelude
import Prelude hiding ((.), (^), repeat)
import qualified Data.Monoid as Monoid

import qualified Util.CallStack as CallStack
import Util.Pretty (pprint)
import qualified Solkattu.Format.Format as Format
import Solkattu.Format.Format (Abstraction)
import Solkattu.Instrument.Mridangam ((&))
import Solkattu.Korvai (Korvai, section, smap)
import Solkattu.Part (Part(..), Index(..), realizeParts)
import qualified Solkattu.Realize as Realize
import qualified Solkattu.S as S
import Solkattu.S (Duration, Matra, Nadai, defaultTempo)
import qualified Solkattu.Solkattu as Solkattu
import Solkattu.Solkattu (check, durationOf, throw)
import qualified Solkattu.Tala as Tala
import Solkattu.Tala (Akshara)

import Global
import Solkattu.MetadataGlobal
import Solkattu.Notation
import Solkattu.SectionGlobal


-- | Combine 'Sequence's.  This is just another name for (<>).
(.) :: Monoid a => a -> a -> a
(.) = (Monoid.<>)
infixr 6 . -- same as <>

-- | Composition is still useful though.
(•) :: (b -> c) -> (a -> b) -> a -> c
(•) = (Prelude..)
infixr 9 • -- match prelude (.)

-- | Synonym for mempty.  Opt-o on OS X.  It looks a little bit nicer when
-- the empty case takes less horizontal space than the non-empty case.
ø :: Monoid a => a
ø = mempty

makeNote :: a -> [S.Note g a]
makeNote a = [S.Note a]

-- ** sollus

-- | Make a single sollu 'Solkattu.Karvai'.
karvai :: (CallStack.Stack, Pretty sollu) => SequenceT sollu -> SequenceT sollu
karvai = modifySingleNote $ Solkattu.modifyNote $
    \note -> note { Solkattu._karvai = True }

-- ** directives

akshara :: Akshara -> SequenceT sollu
akshara n = makeNote (Solkattu.Alignment n)

-- | Align at sam.
sam :: SequenceT sollu
sam = akshara 0

-- | Align at the given akshara.  I use § because I don't use it so often,
-- and it's opt-6 on OS X.
(§) :: SequenceT sollu -> Akshara -> SequenceT sollu
seq § n = makeNote (Solkattu.Alignment n) <> seq
infix 9 §

-- * modify sollus

modifySingleNote :: (CallStack.Stack, Pretty sollu) =>
    (Solkattu.Note sollu -> Solkattu.Note sollu)
    -> SequenceT sollu -> SequenceT sollu
modifySingleNote modify (n:ns) = case n of
    S.Note note@(Solkattu.Note {}) -> S.Note (modify note) : ns
    S.TempoChange change sub ->
        S.TempoChange change (modifySingleNote modify sub) : ns
    _ -> throw $ "expected a single note: " <> pretty n
modifySingleNote _ [] = throw "expected a single note, but got []"

-- ** strokes

hv, lt :: (Pretty stroke, Pretty g, CallStack.Stack) =>
    S.Note g (Realize.Note stroke) -> S.Note g (Realize.Note stroke)
hv (S.Note (Realize.Note s)) =
    S.Note $ Realize.Note $ s { Realize._emphasis = Realize.Heavy }
hv n = throw $ "expected stroke: " <> pretty n

lt (S.Note (Realize.Note s)) =
    S.Note $ Realize.Note $ s { Realize._emphasis = Realize.Light }
lt n = throw $ "expected stroke: " <> pretty n

-- * Abstraction

-- | Abstract all Patterns to durations.
patterns :: Abstraction
patterns = Format.abstract Format.Patterns

-- | Abstract groups to durations, either all of them or just the ones with
-- the given name.
groups :: Maybe Text -> Abstraction
groups name = Format.abstract (Format.Groups name)

-- * patterns

pat :: Matra -> SequenceT sollu
pat d = makeNote $ Solkattu.Pattern (Solkattu.pattern d)

p5, p6, p7, p8, p9 :: SequenceT sollu
p5 = pat 5
p6 = pat 6
p7 = pat 7
p8 = pat 8
p9 = pat 9

p666, p567, p765 :: SequenceT sollu -> SequenceT sollu
p666 sep = trin sep (pat 6) (pat 6) (pat 6)
p567 sep = trin sep (pat 5) (pat 6) (pat 7)
p765 sep = trin sep (pat 7) (pat 6) (pat 5)


-- * talam

-- | For a fragment which fits a certain number of beats.
beats :: Akshara -> Tala.Tala
beats aksharas = Tala.Tala "beats" [Tala.I] aksharas

adi :: Tala.Tala
adi = Tala.adi_tala

-- * conveniences

ganesh, janahan, sriram, sudhindra :: Korvai -> Korvai
ganesh = source "ganesh"
janahan = source "janahan"
sriram = source "sriram"
sudhindra = source "sudhindra"
