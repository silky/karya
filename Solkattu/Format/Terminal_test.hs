-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
module Solkattu.Format.Terminal_test where
import qualified Data.Text as Text

import qualified Util.CallStack as CallStack
import qualified Util.Lists as Lists
import qualified Util.Regex as Regex
import qualified Util.Styled as Styled

import qualified Solkattu.Dsl.Solkattu as G
import qualified Solkattu.Format.Format as Format
import qualified Solkattu.Format.Terminal as Terminal
import qualified Solkattu.Instrument.Mridangam as M
import qualified Solkattu.Korvai as Korvai
import qualified Solkattu.Realize as Realize
import qualified Solkattu.S as S
import qualified Solkattu.Solkattu as Solkattu
import           Solkattu.Solkattu (Sollu(..))
import qualified Solkattu.Tala as Tala
import qualified Solkattu.Talas as Talas

import           Global
import           Util.Test


-- Just print nested groups to check visually.
show_nested_groups :: IO ()
show_nested_groups = do
    let f = fmap (dropRulers . formatAbstraction mempty 80 tala4c . fst)
            . kRealize tala4
    let tas n = G.repeat n G.ta
        group = G.group
    prettyp (f (tas 4))
    prettyp (f (group (tas 4)))
    -- adjacent groups
    prettyp (f (group (tas 2) <> group (tas 2)))
    -- nested groups:   k k             k k       k k       k k
    prettyp (f $ group (tas 2 <> group (tas 2) <> tas 2) <> tas 2)
    -- show innermost nested group
    prettyp (f $ group (tas 2 <> G.p5))

test_format :: Test
test_format = do
    let f tala = eFormat . format 80 tala
            . map (S.FNote S.defaultTempo)
        n4 = [k, t, Realize.Space Solkattu.Rest, n]
        M.Strokes {..} = Realize.Note . Realize.stroke <$> M.strokes
        rupaka = Talas.Carnatic Tala.rupaka_fast
    -- Emphasize every 4.
    equal (f rupaka n4) "k t _ n"
    -- Alignment should be ignored.
    equal (f rupaka ([Realize.Alignment 0] <> n4)) "k t _ n"
    equal (f rupaka (n4 <> n4)) "k t _ n k t _ n"
    -- Emphasize according to the tala.
    let kook = [k, o, o, k]
    equal (f (Talas.Carnatic Tala.kanda_chapu) (take (5*4) (cycle kook)))
        "k o o k k o o k k o o k k o o k k o o k"

test_format_patterns :: Test
test_format_patterns = do
    let realize pmap seq = realizeP (Just pmap) defaultSolluMap seq
    let p = expect_right $ realize (M.families567 !! 1) G.p5
    equal (eFormat $ formatAbstraction mempty 80 adiTala p)
        "k _ t _ k _ k t o _"
    equal (eFormat $ formatAbstraction mempty 15 adiTala p) "k t k kto"

test_format_space :: Test
test_format_space = do
    let run = fmap (eFormat . format 80 adiTala . fst) . kRealize Tala.adi_tala
    equal (run (G.__M 4)) $ Right "‗|  ‗"
    equal (run (G.restD 1)) $ Right "‗|  ‗"

test_format_sarva :: Test
test_format_sarva = do
    let run abstract =
            fmap (eFormat . formatAbstraction abstract 80 adiTala . fst)
            . kRealize Tala.adi_tala
    equal (run mempty (G.sarvaM G.ta 5)) (Right "k k k k k")
    equal (run (Format.abstract Solkattu.GSarva) (G.sarvaM G.ta 5))
        (Right "==========")
    equal (run mempty (G.sarvaM_ 3)) (Right "======")

    let sarva = G.sarvaM_
        abstract = Format.abstract Solkattu.GSarva
    -- [s-1]
    -- [[s0, s0]]
    equal (run abstract (sarva 2)) (Right "====")
    -- This seems like it should be (2+1)*2, the fact that they can all be
    -- reduced to s1 means normalize expands to s1 instead of s0.  I don't
    -- really understand it but I think it's right?
    -- [s0, s0]
    -- [[s1, s1], [s1, s1]] 4*2 -> 8*'='
    equal (run abstract (sarva 1 <> G.su (sarva 2)))
        (Right "========")
    equal (run abstract (sarva 1 <> G.sd (sarva 2)))
        (Right "==========")

tala4c :: Talas.Tala
tala4c = Talas.Carnatic tala4

tala4 :: Tala.Tala
tala4 = Tala.Tala "tala4" [Tala.O, Tala.O] 0

test_format_ruler :: Test
test_format_ruler = do
    let run = fmap (first (capitalizeEmphasis . format 80 tala4c))
            . kRealize tala4
    let tas nadai n = G.nadai nadai (G.repeat n G.ta)
    equalT1 (run (tas 2 8)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k"
        , []
        )
    equalT1 (run (tas 2 16)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k\n\
          \K k K k K k K k"
        , []
        )
    equalT1 (run (tas 3 12)) $ Right
        ( "X:3   O     X     O     |\n\
          \K k k K k k K k k K k k"
        , []
        )

    equalT1 (run (tas 2 12 <> tas 3 6)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k\n\
          \X:2 O   X:3   O     |\n\
          \K k K k K k k K k k"
        , []
        )
    -- A final stroke won't cause the ruler to reappear.
    equalT1 (run (tas 2 16 <> G.ta)) $ Right
        ( "X:2 O   X   O   |\n\
          \K k K k K k K k\n\
          \K k K k K k K k K"
        , []
        )
    equalT (fst <$> run (tas 4 2)) $ Right
        "X:4 |\n\
        \K k"
    equalT (fst <$> run (tas 8 8)) $ Right
        "X:8     .       |\n\
        \K k k k k k k k"

    -- Rests stripped from final stroke.
    let ta_ = G.ta <> G.__4
    equalT (fst <$> run (G.repeat 5 ta_)) $ Right
        "X:4     O       X       O       |\n\
        \K _ ‗   K _ ‗   K _ ‗   K _ ‗   K"

test_format_eddupu :: Test
test_format_eddupu = do
    let run = stripAnsi . formatInstrument . korvai tala4
    let tas n = G.repeat n G.ta
    let s = G.section
    equal_fmt id (run [s $ tas 32, s $ tas 32])
        "    X:4     O       X       O       |\n\
        \0:  k k k k k k k k k k k k k k k k\n\
        \  > k k k k k k k k k k k k k k k k\n\
        \1:  k k k k k k k k k k k k k k k k\n\
        \  > k k k k k k k k k k k k k k k k"
    -- The ruler remains unchanged, even though there aren't enough sollus.
    equal_fmt id (run [G.endOn 2 $ s $ tas 24, G.startOn 2 $ s $ tas 24])
        "    X:4     O       X       O       |\n\
        \0:  k k k k k k k k k k k k k k k k\n\
        \  > k k k k k k k k\n\
        \1:                  k k k k k k k k\n\
        \  > k k k k k k k k k k k k k k k k"

test_spellRests :: Test
test_spellRests = do
    let run width = fmap (eFormat . format width tala4c . fst)
            . kRealize tala4
    equalT (run 80 (G.sd (G.__ <> G.ta))) $ Right "‗|  k _"
    equalT (run 80 (G.sd (G.ta <> G.__ <> G.ta))) $ Right "k _ ‗   k _"
    equalT (run 10 (G.sd (G.ta <> G.__ <> G.ta))) $ Right "k _ k"
    equalT (run 80 (G.ta <> G.__4 <> G.ta)) $ Right "k _ ‗   k"

test_inferRuler :: Test
test_inferRuler = do
    let f = Format.inferRuler 0 tala4c 2
            . map fst . S.flattenedNotes
            . Format.normalizeSpeed 0 (Talas.aksharas tala4c)
            . fst . expect_right
            . kRealize tala4
    let tas nadai n = G.nadai nadai (G.repeat n G.ta)
    equal (f (tas 2 4)) [("X:2", 2), ("O", 2)]

test_format_ruler_rulerEach :: Test
test_format_ruler_rulerEach = do
    let run = fmap (first (capitalizeEmphasis . format 16 adiTala))
            . kRealize tala4
    let tas n = G.repeat n G.ta
    equalT1 (run (tas 80)) $ Right
        ( "0:4 1   2   3   |\n\
          \KkkkKkkkKkkkKkkk\n\
          \KkkkKkkkKkkkKkkk\n\
          \KkkkKkkkKkkkKkkk\n\
          \KkkkKkkkKkkkKkkk\n\
          \0:4 1   2   3   |\n\
          \KkkkKkkkKkkkKkkk"
        , []
        )

equalT :: CallStack.Stack => Either Text Text -> Either Text Text -> Test
equalT = equal_fmt (either id id)

equalT1 :: (CallStack.Stack, Eq a, Show a) => Either Text (Text, a)
    -> Either Text (Text, a) -> Test
equalT1 = equal_fmt (either id fst)

test_formatLines :: Test
test_formatLines = do
    let f strokeWidth width tala =
            fmap (extractLines
                . formatLines Format.defaultAbstraction strokeWidth width
                    (Talas.Carnatic tala)
                . fst)
            . kRealize tala
    let tas n = G.repeat n G.ta

    equal (f 2 16 tala4 (tas 8)) $ Right [["k k k k k k k k"]]
    -- Even aksharas break in the middle.
    equal (f 2 14 tala4 (tas 8)) $ Right [["k k k k", "k k k k"]]

    -- Break multiple avartanams and lines.
    let ta2 = "k _ ‗   k _ ‗"
    equal (f 2 8 tala4 (G.sd (G.sd (tas 8)))) $ Right
        [ [ta2, ta2]
        , [ta2, ta2]
        ]
    -- If there's a final stroke on sam, append it to the previous line.
    equal (f 2 8 tala4 (G.sd (G.sd (tas 9)))) $ Right
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

    equal (f 1 80 Tala.rupaka_fast (G.p5)) $ Right [["5p---"]]
    equal (f 2 80 Tala.rupaka_fast (G.p5)) $ Right [["5p--------"]]

test_abstract :: Test
test_abstract = do
    let f = fmap (mconcat . extractLines
                . formatLines Format.allAbstract 2 80 tala4c . fst)
            . kRealize tala4
    let tas n = G.repeat n G.ta
    equal (f (tas 4)) (Right ["k k k k"])
    equal (f (tas 2 <> G.group (tas 2))) (Right ["k k 2---"])
    equal (f (G.su $ tas 2 <> G.group (tas 2))) (Right ["k k 1---"])
    equal (f (G.su $ tas 2 <> G.group (tas 3))) (Right ["k k 1½----"])
    equal (f (G.nadai 3 $ tas 2 <> G.group (tas 3)))
        (Right ["k k 3-----"])
    equal (f (G.su $ G.nadai 3 $ tas 2 <> G.group (tas 3)))
        (Right ["k k 1½----"])
    equal (f (G.group (tas 2) <> G.group (tas 2)))
        (Right ["2---2---"])
    equal (f (G.su $ tas 2 <> G.named "q" (tas 2)))
        (Right ["k k q---"])

    -- Named group with a longer name.
    equal (f (G.named "tata" (tas 4))) (Right ["tata----"])
    equal (f (G.named "takatiku" (tas 4))) (Right ["takatiku"])
    equal (f (G.named "takatikutari" (tas 4))) (Right ["takatiku"])
    equal (f (G.named "takatiku" (tas 2) <> tas 2)) (Right ["takak k"])

    equal (f (G.reduce3 1 mempty (tas 4))) (Right ["4-------3-----2---"])
    -- patterns
    equal (f (G.pattern (tas 4))) (Right ["4p------"])
    equal (f (G.pattern (G.su $ tas 4))) (Right ["2p------"])
    equal (f G.p5) (Right ["5p--------"])
    -- Unlike GExplicitPattern 'G.pattern', these have a logical matra
    -- duration, so they use that, not fmatras.
    equal (f (G.su G.p5)) (Right ["5p--------"])

extractLines :: [[[(a, Terminal.Symbol)]]] -> [[Text]]
extractLines = map $ map $ Text.strip . mconcat . map (Terminal._text . snd)

test_formatBreakLines :: Test
test_formatBreakLines = do
    let run width = fmap (stripAnsi . format width tala4c . fst)
            . kRealize tala4
    let tas n = G.repeat n G.ta
    equal (run 80 (tas 16)) $ Right
        "X:4     O       X       O       |\n\
        \k k k k k k k k k k k k k k k k"
    equal (run 10 (tas 16)) $ Right
        "X:4 O   |\n\
        \kkkkkkkk\n\
        \kkkkkkkk"

test_formatNadaiChange :: Test
test_formatNadaiChange = do
    let f tala =
            fmap (first
                (stripAnsi . formatAbstraction mempty 50 (Talas.Carnatic tala)))
            . kRealize tala
    let sequence = G.su (G.__ <> G.repeat 5 G.p7) <> G.nadai 6 (G.tri G.p7)
    let (out, warnings) = expect_right $ f Tala.adi_tala sequence
    equal_fmt Text.unlines (Text.lines out)
        [ "0:4     1       2       3       |"
        , "_k_t_knok t knok_t_knok t knok_t"
        , "X:4 :6.   O     .     X     .     O     .     |"
        , "_knok _ t _ k n o k _ t _ k n o k _ t _ k n o"
        ]
    equal warnings []
    -- 0123456701234567012345670123456701234560123450123450123450
    -- 0       1       2       3       4   |  5     6     7     8
    -- _k_t_knok_t_knok_t_knok_t_knok_t_knok_t_knok_t_knok_t_kno

test_formatSpeed :: Test
test_formatSpeed = do
    let f width = fmap (capitalizeEmphasis . dropRulers
                . format width (Talas.Carnatic Tala.rupaka_fast))
            . realize defaultSolluMap
        thoms n = mconcat (replicate n G.thom)
    equal (f 80 mempty) (Right "")
    equal (f 80 (thoms 8)) (Right "O o o o O o o o")
    equal (f 80 $ G.nadai 3 $ thoms 6) (Right "O o o O o o")
    equal (f 80 $ G.sd (thoms 4)) (Right "O _ o _ O _ o _")
    equal (f 80 $ thoms 2 <> G.su (thoms 4) <> thoms 1)
        (Right "O _ o _ o o o o O _")
    equal (f 80 $ thoms 2 <> G.su (G.su (thoms 8)) <> thoms 1)
        (Right "O _ ‗   o _ ‗   o o o o o o o o O _ ‗")
    equal (f 80 $ G.sd (thoms 2) <> thoms 4) (Right "O _ o _ O o o o")
    equal (f 80 (G.p5 <> G.p5)) (Right "5P------==5p----==--")
    -- Use narrow spacing when there's isn't space, and p5 overlaps the next
    -- '-'.
    equal (f 10 (G.p5 <> G.p5)) (Right "5P--=5p-=-")


-- * util

formatInstrument :: Korvai.Korvai -> Text
formatInstrument = Text.unlines . fst
    . Terminal.formatInstrument Terminal.defaultConfig Korvai.IMridangam Just

format :: Solkattu.Notation stroke => Int -> Talas.Tala
    -> [S.Flat Solkattu.Meta (Realize.Note stroke)] -> Text
format = formatAbstraction Format.defaultAbstraction

formatAbstraction :: Solkattu.Notation stroke => Format.Abstraction -> Int
    -> Talas.Tala -> [S.Flat Solkattu.Meta (Realize.Note stroke)] -> Text
formatAbstraction abstraction width tala =
    Text.intercalate "\n" . map Text.strip
    . map (Styled.toText . snd) . snd . snd
    . Terminal.format config (Nothing, 0) tala
    where
    config = Terminal.defaultConfig
        { Terminal._terminalWidth = width
        , Terminal._abstraction = abstraction
        }

eFormat :: Text -> Text
eFormat = stripAnsi . dropRulers

dropRulers :: Text -> Text
dropRulers =
    Text.strip . Text.unlines . filter (not . isRuler . stripAnsi) . Text.lines
    where isRuler t = "X:" `Text.isPrefixOf` t || "0:" `Text.isPrefixOf` t

stripAnsi :: Text -> Text
stripAnsi = Text.intercalate "\n" . map Text.stripEnd . Text.lines
    .  Regex.substitute (Regex.compileUnsafe "\ESC\\[[0-9;]+?m") ""
    -- ANSI codes likely protected trailing spaces.

-- | Replace emphasis with capitals, so spacing is preserved.
capitalizeEmphasis :: Text -> Text
capitalizeEmphasis = stripAnsi
    . Regex.substituteGroups emphasis
        (\_ [t] -> Text.replace "-" "=" (Text.toUpper t))

emphasis :: Regex.Regex
emphasis = Regex.compileUnsafe $ Lists.replace "x" "(.*?)" $
    Regex.escape $ untxt $ Styled.toText $ Terminal.emphasisStyle "x"

kRealize :: Tala.Tala -> Korvai.Sequence
    -> Either Text ([Format.Flat M.Stroke], [Realize.Warning])
kRealize tala = kRealizes tala . (:[])

kRealizes :: Tala.Tala -> [Korvai.Sequence]
    -> Either Text ([Format.Flat M.Stroke], [Realize.Warning])
kRealizes tala =
    fmap (first Format.mapGroups) . head . Korvai.realize Korvai.IMridangam
    . Korvai.korvai tala defaultStrokeMap
    . Korvai.inferSections

korvai :: Tala.Tala -> [Korvai.Section (Korvai.SequenceT Solkattu.Sollu)]
    -> Korvai.Korvai
korvai tala = Korvai.korvai tala defaultStrokeMap


-- * TODO duplicated with Realize_test

realize :: Realize.SolluMap Solkattu.Sollu M.Stroke
    -> S.Sequence Solkattu.Group (Solkattu.Note Sollu)
    -> Either Text [Format.Flat M.Stroke]
realize = realizeP Nothing

realizeP :: Maybe (Realize.PatternMap M.Stroke)
    -> Realize.SolluMap Solkattu.Sollu M.Stroke
    -> S.Sequence Solkattu.Group (Solkattu.Note Sollu)
    -> Either Text [Format.Flat M.Stroke]
realizeP pmap smap = fmap Format.mapGroups
    . Realize.formatError . fst
    . Realize.realize_ pattern (Realize.realizeSollu smap)
        (Tala.tala_aksharas Tala.adi_tala)
    . S.flatten . S.toList
    . fmap (fmap Realize.stroke)
    where
    pattern = Realize.realizePattern $ fromMaybe M.defaultPatterns pmap

adiTala = Talas.Carnatic Tala.adi_tala

formatLines :: Solkattu.Notation stroke => Format.Abstraction -> Int
    -> Int -> Talas.Tala -> [Format.Flat stroke]
    -> [[[(S.State, Terminal.Symbol)]]]
formatLines abstraction strokeWidth width tala notes =
    Terminal.formatLines abstraction strokeWidth width tala notes

defaultSolluMap :: Realize.SolluMap Solkattu.Sollu M.Stroke
defaultSolluMap = fst $ expect_right $ Realize.solluMap $ solkattuToRealize
    [ (G.thom, o)
    ]
    where M.Strokes {..} = M.notes

defaultStrokeMap :: Korvai.StrokeMaps
defaultStrokeMap = mempty
    { Korvai.smapMridangam = Realize.strokeMap M.defaultPatterns [(G.ta, k)] }
    where M.Strokes {..} = M.notes

solkattuToRealize :: [(a, S.Sequence g (Solkattu.Note (Realize.Stroke stroke)))]
    -> [(a, [S.Note () (Realize.Note stroke)])]
solkattuToRealize = expect_right . mapM (traverse Realize.solkattuToRealize)
