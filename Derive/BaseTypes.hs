{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
{-# LANGUAGE OverlappingInstances #-} -- I want a special Pretty for TypedVal
{-# OPTIONS_HADDOCK not-home #-}
{- | This is a bit of song and dance to avoid circular imports.

    "Derive.Score", "Derive.PitchSignal", and "Derive.TrackLang" all define
    basic types.  They also refer to each others types, which means they must
    all be defined in the same module.  But each set of types also comes with
    its own set of functions, and it would make for a giant messy module to
    put them all together.

    So the basic types are defined here, and re-exported from their intended
    modules.  All importers should access the symbols from the higher-level
    modules if at all possible.  Even the ones that must import BaseTypes
    (which should be only the modules collected in BasyTypes itself) should
    use @import qualified as@ to make clear the module that the symbols
    *should* be coming from.

    It's a little grody but still nicer than hs-boot.

    TODO some haddock flags to make sure the docs are collected in the high
    level modules?
-}
module Derive.BaseTypes where
import qualified Control.DeepSeq as DeepSeq
import qualified Data.Map as Map
import qualified Data.Monoid as Monoid
import qualified Data.Set as Set

import qualified Text.Read as Read

import Util.Control
import qualified Util.Functor0 as Functor0
import Util.Functor0 (Elem)
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Ui.ScoreTime as ScoreTime
import qualified Derive.ShowVal as ShowVal
import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal


-- * Derive.Score

-- | An Instrument is identified by a plain string.  This will be looked up in
-- the instrument db to get the backend specific Instrument type as well as
-- the backend itself, but things at the Derive layer and above don't care
-- about all that.
newtype Instrument = Instrument String
    deriving (DeepSeq.NFData, Eq, Ord, Show, Read)

instance Pretty.Pretty Instrument where pretty = ShowVal.show_val
instance ShowVal.ShowVal Instrument where
    show_val (Instrument inst) = '>' : inst

newtype Control = Control String
    deriving (Eq, Ord, Read, Show, DeepSeq.NFData)

-- | Tag for the type of the values in a control signal.
data Type = Untyped | Chromatic | Diatonic | Score | Real
    deriving (Eq, Ord, Read, Show)

instance Pretty.Pretty Type where pretty = show

type_to_code :: Type -> String
type_to_code typ = case typ of
    Untyped -> ""
    Chromatic -> "c"
    Diatonic -> "d"
    Score -> ScoreTime.suffix : "" -- t for time
    Real -> RealTime.suffix : "" -- s for seconds

code_to_type :: String -> Maybe Type
code_to_type s = case s of
    "c" -> Just Chromatic
    "d" -> Just Diatonic
    "t" -> Just Score
    "s" -> Just Real
    "" -> Just Untyped
    _ -> Nothing

instance Monoid.Monoid Type where
    mempty = Untyped
    mappend Untyped typed = typed
    mappend typed _ = typed

instance Pretty.Pretty Control where pretty = ShowVal.show_val
instance ShowVal.ShowVal Control where
    show_val (Control c) = '%' : c

data Typed a = Typed {
    type_of :: !Type
    , typed_val :: !a
    } deriving (Eq, Ord, Read, Show)

instance (DeepSeq.NFData a) => DeepSeq.NFData (Typed a) where
    rnf (Typed typ val) = typ `seq` DeepSeq.rnf val

instance Functor Typed where
    fmap f (Typed typ val) = Typed typ (f val)

instance (Pretty.Pretty a) => Pretty.Pretty (Typed a) where
    format (Typed typ val) =
        Pretty.text (if null c then "" else c ++ ":") <> Pretty.format val
        where c = type_to_code typ

merge_typed :: (a -> a -> a) -> Typed a -> Typed a -> Typed a
merge_typed f (Typed typ1 v1) (Typed typ2 v2) = Typed (typ1<>typ2) (f v1 v2)

untyped :: a -> Typed a
untyped = Typed Untyped

type TypedSignal = Typed Signal.Control
type TypedVal = Typed Signal.Y

instance ShowVal.ShowVal TypedVal where
    show_val (Typed typ val) = ShowVal.show_val val ++ type_to_code typ

-- ** Attributes

-- | Instruments can have a set of attributes along with them.  These are
-- propagated dynamically down the derivation stack.  They function like
-- arguments to an instrument, and will typically select an articulation, or
-- a drum from a drumset, or something like that.
type Attribute = String
newtype Attributes = Attributes (Set.Set Attribute)
    deriving (Monoid.Monoid, Eq, Ord, Read, Show)

instance Pretty.Pretty Attributes where pretty = ShowVal.show_val
instance ShowVal.ShowVal Attributes where
    show_val attrs = if null alist then "-" else '+' : Seq.join "+" alist
        where alist = attrs_list attrs

attrs_set :: Attributes -> Set.Set Attribute
attrs_set (Attributes attrs) = attrs

attrs_list :: Attributes -> [Attribute]
attrs_list = Set.toList . attrs_set

no_attrs :: Attributes
no_attrs = Attributes Set.empty


-- * Derive.PitchSignal

-- | A pitch is an abstract value that can turn a map of values into
-- a NoteNumber.  The values are expected to contain transpositions that this
-- Pitch understands, for example 'Derive.Score.c_chromatic' and
-- 'Derive.Score.c_diatonic'.
--
-- TODO why have TypedVals, if the chromatic and diatonic transpose signals are
-- separate?
newtype Pitch = Pitch PitchCall
type PitchCall = Map.Map Control Signal.Y -> Either PitchError Pitch.NoteNumber

instance Eq Pitch where
    Pitch p1 == Pitch p2 = p1 Map.empty == p2 Map.empty

instance Show Pitch where
    show (Pitch p) = show (p Map.empty)

instance Read Pitch where
    readPrec = do
        val <- Read.readPrec
        return $ Pitch $ \_ -> val

instance Pretty.Pretty Pitch where
    pretty (Pitch p) = either show Pretty.pretty (p Map.empty)

instance Functor0.Functor0 Pitch where
    type Elem Pitch = PitchCall
    fmap0 f (Pitch p) = Pitch (f p)

newtype PitchError = PitchError String deriving (Eq, Ord, Read, Show)
instance Pretty.Pretty PitchError where pretty (PitchError s) = s


-- * Derive.TrackLang

type Environ = Map.Map ValName Val

-- | Symbols to look up a val in the 'ValMap'.
type ValName = Symbol

-- | Even though Environ is a type synonym, you can use this to avoid depending
-- directly on that.
insert_val :: ValName -> Val -> Environ -> Environ
insert_val = Map.insert

-- | Environ key for the default attributes.
--
-- This is defined here so 'Derive.Score.event_attributes' can use it.
v_attributes :: ValName
v_attributes = Symbol "attr"

-- ** Val

data Val =
    -- | A number with an optional type suffix.
    --
    -- Literal: @42.23@, @-.4@, @1c@, @-2.4d@
    VNum TypedVal

    -- | Escape a quote by doubling it.
    --
    -- Literal: @\'hello\'@, @\'quinn\'\'s hat\'@
    | VString String

    -- | Relative attribute adjustment.
    --
    -- This is a bit of a hack, but means I can do attr adjustment without +=
    -- or -= operators.
    --
    -- Literal: @+attr@, @-attr@, @=attr@, @=-@ (to clear attributes).
    | VRelativeAttr RelativeAttr
    -- | A set of Attributes for an instrument.  No literal, since you can use
    -- VRelativeAttr.
    | VAttributes Attributes

    -- | A control name.  An optional value gives a default if the control
    -- isn't present.
    --
    -- Literal: @%control@, @%control,.4@
    | VControl ValControl
    -- | If a control name starts with a *, it denotes a pitch signal and the
    -- scale is taken from the environ.  Unlike a control signal, the empty
    -- string is a valid signal name and means the default pitch signal.
    --
    -- Literal: @\#pitch,4c@, @\#,4@, @\#@
    | VPitchControl PitchControl

    -- | The literal names a ScaleId, and will probably result in an exception
    -- if the lookup fails.  The empty scale is taken to mean the relative
    -- scale.
    --
    -- Literal: @*scale@, @*@.
    | VScaleId Pitch.ScaleId
    -- | No literal yet, but is returned from val calls.
    | VPitch Pitch
    -- | Sets the instrument in scope for a note.  An empty instrument doesn't
    -- set the instrument, but can be used to mark a track as a note track.
    --
    -- Literal: @>@, @>inst@
    | VInstrument Instrument

    -- | A call to a function.  Symbol parsing is special in that the first
    -- word is always parsed as a symbol.  So you can have symbols of numbers
    -- or other special characters.  This means that a symbol can't be in the
    -- middle of an expression, but if you surround a word with parens like
    -- @(42)@, it will be interpreted as a call.  So the only characters a
    -- symbol can't have are space and parens.
    --
    -- Literal: @func@
    | VSymbol Symbol
    -- | An explicit not-given arg for functions so you can use positional
    -- args with defaults.
    --
    -- Literal: @_@
    | VNotGiven
    deriving (Show)

instance ShowVal.ShowVal Val where
    show_val val = case val of
        VNum d -> ShowVal.show_val d
        VString s -> ShowVal.show_val s
        VRelativeAttr rel -> ShowVal.show_val rel
        VAttributes attrs -> ShowVal.show_val attrs
        VControl control -> ShowVal.show_val control
        VPitchControl control -> ShowVal.show_val control
        VScaleId scale_id -> ShowVal.show_val scale_id
        VPitch pitch -> ShowVal.show_val pitch
        VInstrument inst -> ShowVal.show_val inst
        VSymbol sym -> ShowVal.show_val sym
        VNotGiven -> "_"

-- | Pitchas have no literal syntax, but I have to print something.
instance ShowVal.ShowVal Pitch where
    show_val pitch = "<pitch: " ++ Pretty.pretty pitch ++ ">"

instance Pretty.Pretty Val where pretty = ShowVal.show_val
instance ShowVal.ShowVal Pitch.ScaleId where
    show_val (Pitch.ScaleId s) = '*' : s

newtype Symbol = Symbol String deriving (Eq, Ord, Show)
instance Pretty.Pretty Symbol where pretty = ShowVal.show_val
instance ShowVal.ShowVal Symbol where show_val (Symbol s) = s

data AttrMode = Add | Remove | Set | Clear deriving (Eq, Show)
newtype RelativeAttr = RelativeAttr (AttrMode, Attribute) deriving (Eq, Show)

instance ShowVal.ShowVal RelativeAttr where
    show_val (RelativeAttr (mode, attr)) = case mode of
        Add -> '+' : attr
        Remove -> '-' : attr
        Set -> '=' : attr
        Clear -> "=-"

data ControlRef val =
    -- | A constant signal.  For 'Control', this is coerced from a VNum
    -- literal.
    ConstantControl val
    -- | If the control isn't present, use the constant.
    | DefaultedControl Control val
    -- | Throw an exception if the control isn't present.
    | LiteralControl Control
    deriving (Eq, Show)

type PitchControl = ControlRef Note
type ValControl = ControlRef TypedVal

instance Pretty.Pretty PitchControl where pretty = ShowVal.show_val
instance ShowVal.ShowVal PitchControl where
    -- The PitchControl syntax doesn't support args for the signal default yet.
    show_val = show_control '#' (Pitch.note_text . note_sym)

instance Pretty.Pretty ValControl where pretty = ShowVal.show_val
instance ShowVal.ShowVal ValControl where
    show_val = show_control '%' $ \(Typed typ num) ->
        ShowVal.show_val num ++ type_to_code typ

show_control :: Char -> (val -> String) -> ControlRef val -> String
show_control prefix show_val control = case control of
    ConstantControl val -> show_val val
    DefaultedControl (Control cont) deflt ->
        prefix : cont ++ ',' : show_val deflt
    LiteralControl (Control cont) -> prefix : cont

-- ** Note

-- | Pitch.Note is just the name of the pitch, but the TrackLang Note carries
-- args, and should be used in preference to Pitch.Note where appropriate.
data Note = Note {
    note_sym :: Pitch.Note
    , note_args :: [Val]
    } deriving (Show)
