-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
module Solkattu.Format.Terminal_test where
import qualified Data.Char as Char
import qualified Data.Text as Text

import qualified Util.CallStack as CallStack
import qualified Util.Regex as Regex
import qualified Util.Styled as Styled

import qualified Solkattu.Dsl as Dsl
import qualified Solkattu.Format.Format as Format
import qualified Solkattu.Format.Terminal as Terminal
import qualified Solkattu.Instrument.Mridangam as M
import qualified Solkattu.Korvai as Korvai
import qualified Solkattu.Notation as Notation
import qualified Solkattu.Realize as Realize
import qualified Solkattu.S as S
import qualified Solkattu.Solkattu as Solkattu
import Solkattu.Solkattu (Note(..), Sollu(..))
import qualified Solkattu.Tala as Tala

import Global
import Solkattu.DslSollu
import Util.Test


test_format = do
    let f tala = eFormat . format 80 tala
            . map (S.FNote S.defaultTempo)
        n4 = [k, t, Realize.Space Solkattu.Rest, n]
        M.Strokes {..} = Realize.Note . Realize.stroke <$> M.strokes
        rupaka = Tala.rupaka_fast
    -- Emphasize every 4.
    equal (f rupaka n4) "k t _ n"
    -- Alignment should be ignored.
    equal (f rupaka ([Realize.Alignment 0] <> n4)) "k t _ n"
    equal (f rupaka (n4 <> n4)) "k t _ n k t _ n"
    -- Emphasis works in patterns.
    equal (f rupaka (n4 <> [rpattern 5] <> n4))
        "k t _ n p5--------k t _ n"
    -- Patterns are wrapped properly.
    equal (f rupaka (n4 <> [rpattern 5] <> n4 <> [rpattern 5]))
        "k t _ n p5--------k t _\n\
        \n p5--------"
    -- Emphasize according to the tala.
    let kook = [k, o, o, k]
    equal (f Tala.khanda_chapu (take (5*4) (cycle kook)))
        "k o o k k o o k k o o k k o o k k o o k"

test_format_patterns = do
    let f pmap seq = do
            ps <- Realize.patternMap pmap
            realizeP (Just ps) strokeMap seq
    let p = expect_right $ f (M.families567 !! 1) Dsl.p5
    equal (eFormat $ format 80 Tala.adi_tala p) "k _ t _ k _ k t o _"
    equal (eFormat $ format 15 Tala.adi_tala p) "k t k kto"

test_format_space = do
    let run = fmap (eFormat . format 80 Tala.adi_tala . fst)
            . kRealize False Tala.adi_tala
    equal (run (Notation.sarvaM 4)) $ Right "========"
    equal (run (Notation.sarvaD 1)) $ Right "========"
    equal (run (Notation.restM 4)) $ Right "‗|  ‗"
    equal (run (Notation.restD 1)) $ Right "‗|  ‗"

tala4 :: Tala.Tala
tala4 = Tala.Tala "tala4" [Tala.O, Tala.O] 0

test_format_ruler = do
    let run = fmap (first (capitalizeEmphasis . format 80 tala4))
            . kRealize False tala4
    let tas nadai n = Dsl.nadai nadai (Dsl.repeat n ta)
    equalT1 (run (tas 2 8)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k"
        , ""
        )
    equalT1 (run (tas 2 16)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k\n\
          \K k K k K k K k"
        , ""
        )
    equalT1 (run (tas 3 12)) $ Right
        ( "X:3   O     X     O     |\n\
          \K k k K k k K k k K k k"
        , ""
        )

    equalT1 (run (tas 2 12 <> tas 3 6)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k\n\
          \X:2 O   X:3   O     |\n\
          \K k K k K k k K k k"
        , ""
        )
    -- A final stroke won't cause the ruler to reappear.
    equalT1 (run (tas 2 16 <> ta)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k\n\
          \K k K k K k K k K"
        , ""
        )
    equalT (fst <$> run (tas 4 2)) $ Right
        "X:4 |\n\
        \K k"
    equalT (fst <$> run (tas 8 8)) $ Right
        "X:8     .       |\n\
        \K k k k k k k k"

    -- Rests stripped from final stroke.
    let ta_ = ta <> Dsl.__4
    equalT (fst <$> run (Dsl.repeat 5 ta_)) $ Right
        "X:4     O       X       O       |\n\
        \K _ ‗   K _ ‗   K _ ‗   K _ ‗   K"

test_spellRests = do
    let run width = fmap (eFormat . format width tala4 . fst)
            . kRealize False tala4
    equalT (run 80 (sd (Dsl.__ <> ta))) $ Right "‗|  k _"
    equalT (run 80 (sd (ta <> Dsl.__ <> ta))) $ Right "k _ ‗   k _"
    equalT (run 10 (sd (ta <> Dsl.__ <> ta))) $ Right "k _ k"
    equalT (run 80 (ta <> Dsl.__4 <> ta)) $ Right "k _ ‗   k"

test_inferRuler = do
    let f = Format.inferRuler tala4 2
            . map fst . S.flattenedNotes . Format.normalizeSpeed tala4 . fst
            . expect_right
            . kRealize False tala4
    let tas nadai n = Dsl.nadai nadai (Dsl.repeat n ta)
    equal (f (tas 2 4)) [("X:2", 2), ("O", 2), ("|", 0)]

test_format_ruler_rulerEach = do
    let run = fmap (first (capitalizeEmphasis . format 16 Tala.adi_tala))
            . kRealize False tala4
    let tas n = Dsl.repeat n ta
    equalT1 (run (tas 80)) $ Right
        ( "0:4 1   2   3   |\n\
          \KkkkKkkkKkkkKkkk\n\
          \KkkkKkkkKkkkKkkk\n\
          \KkkkKkkkKkkkKkkk\n\
          \KkkkKkkkKkkkKkkk\n\
          \0:4 1   2   3   |\n\
          \KkkkKkkkKkkkKkkk"
        , ""
        )

equalT :: CallStack.Stack => Either Text Text -> Either Text Text -> IO Bool
equalT = equal_fmt (either id id)

equalT1 :: (CallStack.Stack, Eq a, Show a) => Either Text (Text, a)
    -> Either Text (Text, a) -> IO Bool
equalT1 = equal_fmt (either id fst)

test_formatLines = do
    let f strokeWidth width tala =
            fmap (extractLines . formatLines False strokeWidth width tala . fst)
            . kRealize False tala
    let tas n = Dsl.repeat n ta

    equal (f 2 16 tala4 (tas 8)) $ Right [["k k k k k k k k"]]
    -- Even aksharas break in the middle.
    equal (f 2 14 tala4 (tas 8)) $ Right [["k k k k", "k k k k"]]

    -- Break multiple avartanams and lines.
    let ta2 = "k _ ‗   k _ ‗"
    equal (f 2 8 tala4 (sd (sd (tas 8)))) $ Right
        [ [ta2, ta2]
        , [ta2, ta2]
        ]
    -- If there's a final stroke on sam, append it to the previous line.
    equal (f 2 8 tala4 (sd (sd (tas 9)))) $ Right
        [ [ta2, ta2]
        , [ta2, ta2 <> "   k"]
        ]

    -- Uneven ones break before the width.
    equal (f 2 24 Tala.rupaka_fast (tas (4 * 3))) $
        Right [["k k k k k k k k k k k k"]]
    equal (f 2 20 Tala.rupaka_fast (tas (4 * 3))) $
        Right [["k k k k k k k k", "k k k k"]]
    equal (f 2 10 Tala.rupaka_fast (tas (4 * 3))) $
        Right [["k k k k", "k k k k", "k k k k"]]
    equal (f 2 1 Tala.rupaka_fast (tas (4 * 3))) $
        Right [["k k k k", "k k k k", "k k k k"]]

    equal (f 1 80 Tala.rupaka_fast (Dsl.pat 4)) $ Right [["p4--"]]
    equal (f 2 80 Tala.rupaka_fast (Dsl.pat 4)) $ Right [["p4------"]]

test_formatLines_abstractGroups = do
    let f = fmap (mconcat . extractLines . formatLines True 2 80 tala4 . fst)
            . kRealize False tala4
    let tas n = Dsl.repeat n ta
    equal (f (tas 4)) (Right ["k k k k"])
    equal (f (tas 2 <> Dsl.group (tas 2))) (Right ["k k 2---"])
    equal (f (su $ tas 2 <> Dsl.group (tas 2))) (Right ["k k 1---"])
    equal (f (su $ tas 2 <> Dsl.group (tas 3))) (Right ["k k 1½----"])
    equal (f (Dsl.nadai 3 $ tas 2 <> Dsl.group (tas 3)))
        (Right ["k k 3-----"])
    equal (f (su $ Dsl.nadai 3 $ tas 2 <> Dsl.group (tas 3)))
        (Right ["k k 1½----"])
    equal (f (Dsl.group (tas 2) <> Dsl.group (tas 2)))
        (Right ["2---2---"])

-- Just print nested groups to check visually.
_nested_groups = do
    let f = fmap (dropRulers . format 80 tala4 . fst) . kRealize False tala4
    let tas n = Dsl.repeat n ta
        group = Dsl.group
    prettyp (f (tas 4))
    prettyp (f (group (tas 4)))
    -- adjacent groups
    prettyp (f (group (tas 2) <> group (tas 2)))
    -- nested groups:   k k             k k       k k       k k
    prettyp (f $ group (tas 2 <> group (tas 2) <> tas 2) <> tas 2)

extractLines :: [[[(a, Terminal.Symbol)]]] -> [[Text]]
extractLines = map $ map $ Text.strip . mconcat . map (Terminal._text . snd)

test_formatBreakLines = do
    let run width = fmap (stripAnsi . format width tala4 . fst)
            . kRealize False tala4
    let tas n = Dsl.repeat n ta
    equal (run 80 (tas 16)) $ Right
        "X:4     O       X       O       |\n\
        \k k k k k k k k k k k k k k k k"
    equal (run 10 (tas 16)) $ Right
        "X:4 O   |\n\
        \kkkkkkkk\n\
        \kkkkkkkk"

test_formatNadaiChange = do
    let f tala realizePatterns =
            fmap (first (stripAnsi . format 50 tala))
            . kRealize realizePatterns tala
    let sequence = Dsl.su (Dsl.__ <> Dsl.repeat 5 Dsl.p7)
            <> Dsl.nadai 6 (Dsl.tri Dsl.p7)
    let (out, warn) = expect_right $ f Tala.adi_tala True sequence
    equal_fmt Text.unlines (Text.lines out)
        [ "0:4     1       2       3       |"
        , "_k_t_knok t knok_t_knok t knok_t"
        , "0:4 :6.   1     .     2     .     3     .     |"
        , "_knok _ t _ k n o k _ t _ k n o k _ t _ k n o"
        ]
    equal warn ""
    -- 0123456701234567012345670123456701234560123450123450123450
    -- 0       1       2       3       4   |  5     6     7     8
    -- _k_t_knok_t_knok_t_knok_t_knok_t_knok_t_knok_t_knok_t_kno

test_formatSpeed = do
    let f width = fmap (capitalizeEmphasis . dropRulers
                . format width Tala.rupaka_fast)
            . realize strokeMap
        thoms n = mconcat (replicate n thom)
    equal (f 80 []) (Right "")
    equal (f 80 (thoms 8)) (Right "O o o o O o o o")
    equal (f 80 [nadai 3 $ thoms 6]) (Right "O o o O o o")
    equal (f 80 $ sd (thoms 4)) (Right "O _ o _ O _ o _")
    equal (f 80 $ thoms 2 <> su (thoms 4) <> thoms 1)
        (Right "O _ o _ o o o o O _")
    equal (f 80 $ thoms 2 <> su (su (thoms 8)) <> thoms 1)
        (Right "O _ ‗   o _ ‗   o o o o o o o o O _ ‗")
    equal (f 80 $ sd (thoms 2) <> thoms 4) (Right "O _ o _ O o o o")
    equal (f 80 (Dsl.p5 <> Dsl.p5)) (Right "P5------==p5----==--")
    -- Use narrow spacing when there's isn't space, and p5 overlaps the next
    -- '-'.
    equal (f 10 (Dsl.p5 <> Dsl.p5)) (Right "P5--=p5-=-")


-- * util

rpattern :: S.Matra -> Realize.Note stroke
rpattern = Realize.Pattern . Solkattu.pattern

format :: Solkattu.Notation stroke => Int -> Tala.Tala
    -> [S.Flat Format.Group (Realize.Note stroke)] -> Text
format width tala =
    Text.intercalate "\n" . map Text.strip . Text.lines
    . Styled.toText . snd
    . Terminal.format (config { Terminal._terminalWidth = width })
        (Nothing, 0) tala

config :: Terminal.Config
config = Terminal.defaultConfig

eFormat :: Text -> Text
eFormat = stripAnsi . dropRulers

dropRulers :: Text -> Text
dropRulers =
    Text.strip . Text.unlines . filter (not . isRuler . stripAnsi) . Text.lines
    where
    isRuler t = Text.all Char.isDigit (Text.take 1 t)
        || "X" `Text.isPrefixOf` t

stripAnsi :: Text -> Text
stripAnsi =
    Text.strip . Regex.substitute (Regex.compileUnsafe "\ESC\\[[0-9;]+?m") ""
    -- ANSI codes likely protected trailing spaces.

-- | Replace emphasis with capitals, so spacing is preserved.
capitalizeEmphasis :: Text -> Text
capitalizeEmphasis = stripAnsi
    . Regex.substituteGroups (Regex.compileUnsafe "\ESC\\[0;1m(.*?)\ESC\\[0m")
        (\_ [t] -> Text.replace "-" "=" (Text.toUpper t))

kRealize :: Bool -> Tala.Tala -> Korvai.Sequence
    -> Either Text ([Format.Flat M.Stroke], Text)
kRealize realizePatterns tala =
    fmap (first Format.mapGroups) . head
    . Korvai.realize Korvai.mridangam realizePatterns
    . Korvai.korvaiInferSections tala mridangam
    . (:[])


-- * TODO duplicated with Realize_test

sd, su :: [S.Note g a] -> [S.Note g a]
sd = (:[]) . S.changeSpeed (-1)
su = (:[]) . S.changeSpeed 1

nadai :: S.Nadai -> [S.Note g a] -> S.Note g a
nadai n = S.TempoChange (S.Nadai n)

realize :: Solkattu.Notation stroke => Realize.SolluMap stroke
    -> [S.Note Solkattu.Group (Note Sollu)]
    -> Either Text [Format.Flat stroke]
realize = realizeP Nothing

realizeP :: Solkattu.Notation stroke => Maybe (Realize.PatternMap stroke)
    -> Realize.SolluMap stroke -> [S.Note Solkattu.Group (Note Sollu)]
    -> Either Text [Format.Flat stroke]
realizeP pmap smap = fmap Format.mapGroups
    . Realize.formatError . fst
    . Realize.realize pattern (Realize.realizeSollu smap)
    . S.flatten
    where
    pattern = maybe Realize.keepPattern Realize.realizePattern pmap

formatLines :: Solkattu.Notation stroke => Bool -> Int -> Int -> Tala.Tala
    -> [Format.Flat stroke] -> [[[(S.State, Terminal.Symbol)]]]
formatLines = Terminal.formatLines

strokeMap :: Realize.SolluMap M.Stroke
strokeMap = fst $ expect_right $ Realize.solluMap
    [ (thom, [o])
    ]
    where M.Strokes {..} = M.notes

mridangam :: Korvai.StrokeMaps
mridangam = mempty
    { Korvai.smapMridangam = Dsl.check $ Realize.strokeMap $
        (ta, [M.k M.notes]) : Realize.patternKeys M.defaultPatterns
    }
