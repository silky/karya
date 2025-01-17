-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{- | Provide short names and operators for writing korvais in haskell.  This
    module is the shared global namespace between "Solkattu.Dsl.Solkattu" and
    "Solkattu.Dsl.Mridangam".

    Operators:

    > infixl 9 ^ § & -- also •, which replaces prelude (.)
    > infixl 8 <== ==>
    > infixr 6 . -- same as (<>)
-}
module Solkattu.Dsl.Generic (
    s
    , (.), (•), ø
    , mconcatMap
    , writeHtml
    -- * notation
    , karvai
    , stripRests

    -- * directives
    , hv, lt
    , akshara, sam, (§)
    -- * Config
    , wider
    , abstract, concrete
    , Abstraction
    , patterns, namedGroups, allAbstract
    -- * patterns
    , pat, p5, p6, p7, p8, p9, p666, p567, p765
    -- * re-exports
    , module Solkattu.Korvai
    , module Solkattu.Dsl.Metadata
    , module Solkattu.Dsl.Notation
    , module Solkattu.Dsl.Section
    , Duration, Matra, Nadai
    , check, durationOf, throw
    , Akshara
    -- * misc
    , pprint
    -- * talam
    , beats
    , adi
    -- * conveniences
    , ganesh, janahan, sudhindra, elaforge
    , Pretty -- signatures wind up being Pretty sollu => ...
) where
import qualified Prelude
import           Prelude hiding ((.), (^), repeat)

import qualified Util.CallStack as CallStack
import           Util.Pretty (pprint)
import qualified Solkattu.Format.Format as Format
import           Solkattu.Format.Format (Abstraction)
import qualified Solkattu.Format.Html as Html
import qualified Solkattu.Format.Terminal as Terminal
import qualified Solkattu.Korvai as Korvai
import           Solkattu.Korvai (Korvai, Score, tani, Part(..), index, slice)
import qualified Solkattu.Realize as Realize
import qualified Solkattu.S as S
import           Solkattu.S (Duration, Matra, Nadai)
import qualified Solkattu.Solkattu as Solkattu
import           Solkattu.Solkattu (check, durationOf, throw)
import qualified Solkattu.Tala as Tala
import           Solkattu.Tala (Akshara)

import           Global
import           Solkattu.Dsl.Metadata
import           Solkattu.Dsl.Notation
import           Solkattu.Dsl.Section


-- | Declare a 'Section' of a 'Korvai'.
--
-- I tried to think of various ways to avoid having to explicitly wrap every
-- section, but they all seem really heavyweight, like a typeclass and replace
-- list literals with a custom (:) operator, or leaky, like embed section in
-- the Sequence and just pull out the topmost one.  So I'll settle for explicit
-- noise, but shorten the name.
s :: a -> Korvai.Section a
s = section

-- | Combine 'Sequence's.  This is just another name for (<>).
(.) :: Monoid a => a -> a -> a
(.) = (<>)
infixr 6 . -- same as <>

-- | Composition is still useful though.
(•) :: (b -> c) -> (a -> b) -> a -> c
(•) = (Prelude..)
infixr 9 • -- match prelude (.)

-- | Synonym for mempty.  Opt-o on OS X.  It looks a little bit nicer when
-- the empty case takes less horizontal space than the non-empty case.
ø :: Monoid a => a
ø = mempty

makeNote :: a -> S.Sequence g a
makeNote a = S.singleton $ S.Note a

-- * realize

writeHtml :: FilePath -> Korvai -> IO ()
writeHtml fname = Html.writeAll fname • Korvai.Single

-- * notation

-- | Make a single sollu 'Solkattu.Karvai'.
karvai :: (CallStack.Stack, Pretty sollu) => SequenceT sollu -> SequenceT sollu
karvai = modifySingleNote $ Solkattu.modifyNote $
    \note -> note { Solkattu._karvai = True }

-- * check alignment

akshara :: Akshara -> SequenceT sollu
akshara n = makeNote (Solkattu.Alignment n)

-- | Assert that the following sollu is on sam.
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
modifySingleNote modify = S.apply go
    where
    go = \case
        n : ns -> case n of
            S.Note note@(Solkattu.Note {}) -> S.Note (modify note) : ns
            S.TempoChange change sub -> S.TempoChange change (go sub) : ns
            _ -> throw $ "expected a single note: " <> pretty n
        [] -> throw "expected a single note, but got []"

stripRests :: SequenceT sollu -> SequenceT sollu
stripRests = S.filterNotes notRest
    where
    notRest (Solkattu.Space {}) = False
    notRest _ = True

-- ** strokes

lt, hv :: SequenceT (Realize.Stroke stroke) -> SequenceT (Realize.Stroke stroke)
lt = mapSollu (\stroke -> stroke { Realize._emphasis = Realize.Light })
hv = mapSollu (\stroke -> stroke { Realize._emphasis = Realize.Heavy })

mapSollu :: (sollu -> sollu) -> SequenceT sollu -> SequenceT sollu
mapSollu = fmap • fmap

-- * Config

wider :: Terminal.Config -> Terminal.Config
wider config =
    config { Terminal._terminalWidth = Terminal._terminalWidth config + 40 }

abstract :: Abstraction -> Terminal.Config -> Terminal.Config
abstract a config = config { Terminal._abstraction = a }

concrete :: Terminal.Config -> Terminal.Config
concrete = abstract mempty

-- | Abstract all Patterns to durations.
patterns :: Abstraction
patterns = Format.abstract Solkattu.GPattern

namedGroups :: Abstraction
namedGroups = Format.named Solkattu.GGroup

allAbstract :: Abstraction
allAbstract = Format.allAbstract

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
beats = Tala.beats

adi :: Tala.Tala
adi = Tala.adi_tala

-- * conveniences

ganesh, janahan, sudhindra :: Korvai -> Korvai
ganesh = source "ganesh"
janahan = source "janahan"
sudhindra = source "sudhindra"

elaforge :: Korvai -> Korvai
elaforge = source "elaforge"
