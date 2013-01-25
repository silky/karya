module Perform.Lilypond.Lilypond_test where
import qualified Data.Char as Char
import qualified System.Process as Process

import Util.Control
import qualified Util.Pretty as Pretty
import Util.Test

import qualified Ui.UiTest as UiTest
import qualified Derive.Args as Args
import qualified Derive.Call.CallTest as CallTest
import qualified Derive.Call.Lily as Lily
import qualified Derive.Call.Note as Note
import qualified Derive.Call.Util as Util
import qualified Derive.Score as Score
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Lilypond.Lilypond as Lilypond
import qualified Perform.Lilypond.LilypondTest as LilypondTest
import Perform.Lilypond.LilypondTest (convert_staves, derive)
import qualified Perform.Lilypond.Meter as Meter
import Perform.Lilypond.Types (Duration(..))

import Types


test_convert_measures = do
    let f = convert_staves [] . map simple_event
    equal (f [(0, 1, "a"), (1, 1, "b")]) $ Right [["a4", "b4", "r2"]]
    equal (f [(1, 1, "a"), (2, 8, "b")]) $ Right
        [["r4", "a4", "b2~"], ["b1~"], ["b2", "r2"]]
    -- Rests are not dotted, even when they could be.
    -- I also get r8 r4, instead of r4 r8, see comment on 'allowed_time'.
    equal (f [(0, 1, "a"), (1.5, 1, "b")]) $ Right
        [["a4", "r8", "b8~", "b8", "r8", "r4"]]
    equal (f [(0, 2, "a"), (3.5, 0.25, "b"), (3.75, 0.25, "c")]) $ Right
        [["a2", "r4", "r8", "b16", "c16"]]
    equal (f [(0, 0.5, "a"), (0.5, 1, "b"), (1.5, 0.5, "c")]) $ Right
        [["a8", "b4", "c8", "r2"]]
    -- Zero durations turn into short notes.
    equal (f [(0, 0, "a"), (0, 0, "b"), (1, 1, "c")]) $ Right
        [["<a b>128", "r128", "r64", "r32", "r16", "r8", "c4", "r2"]]

test_dotted_rests = do
    let f = convert_staves [] . map meter_event
    -- Rests are allowed to be dotted when the meter isn't duple.
    equal (f [(1.5, 0.5, "a", "3+3/8")]) $
        Right [["r4.", "a8", "r4"]]
    equal (f [(3, 1, "a", "4/4")]) $
        Right [["r2", "r4", "a4"]]

test_change_meter = do
    let f = convert_staves ["time"] . map meter_event
    equal (f [(0, 5, "a", "4/4"), (6, 2, "b", "4/4")]) $ Right
        [["\\time 4/4", "a1~"], ["a4", "r4", "b2"]]
    -- Change meter on the measure boundary.
    equal (f [(0, 2, "a", "2/4"), (2, 2, "b", "4/4")]) $ Right
        [["\\time 2/4", "a2"], ["\\time 4/4", "b2", "r2"]]

    -- Meter changes during a note.
    equal (f [(0, 3, "a", "2/4"), (3, 4, "b", "4/4")]) $ Right
        [["\\time 2/4", "a2~"], ["a4", "b4~"], ["\\time 4/4", "b2.", "r4"]]
    equal (f [(0, 3, "a", "2/4"), (4, 4, "b", "4/4")]) $ Right
        [["\\time 2/4", "a2~"], ["a4", "r4"], ["\\time 4/4", "b1"]]

    -- Inconsistent meters cause an error.
    let run = convert_staves [] . fst . derive . concatMap UiTest.note_spec
    left_like (run
            [ ("s/i1 | meter = '2/4'", [(0, 4, "4a")], [])
            , ("s/i2 | meter = '4/4'", [(0, 4, "4b")], [])
            ])
        "staff for >s/i2: inconsistent meters"

test_parse_error = do
    let f = convert_staves [] . map environ_event
    left_like (f [(0, 1, "a", [(TrackLang.v_key, "oot-greet")])]) "unknown key"
    left_like (f [(0, 1, "a", [(Lilypond.v_meter, "oot-greet")])])
        "can't parse"

test_chords = do
    let f = convert_staves [] . map simple_event
    -- Homogenous durations.
    equal (f [(0, 1, "a"), (0, 1, "c")]) $ Right
        [["<a c>4", "r4", "r2"]]
    -- Starting at the same time.
    equal (f [(0, 2, "a"), (0, 1, "c")]) $ Right
        [["<a c>4~", "a4", "r2"]]
    -- Starting at different times.
    equal (f [(0, 2, "a"), (1, 1, "c")]) $ Right
        [["a4~", "<a c>4", "r2"]]
    equal (f [(0, 2, "a"), (1, 2, "c"), (2, 2, "e")]) $ Right
        [["a4~", "<a c>4~", "<c e>4~", "e4"]]

test_extract_meters = do
    let f = fmap (map Pretty.pretty) . Lilypond.extract_meters
            . map (\(s, d, meter) -> meter_event (s, d, "a", meter))
    equal (f [(0, 1, "4/4")]) $ Right ["4/4"]
    equal (f [(0, 5, "4/4")]) $ Right ["4/4", "4/4"]
    equal (f [(5, 5, "4/4")]) $ Right ["4/4", "4/4", "4/4"]
    equal (f [(5, 5, "3/4")]) $ Right ["3/4", "3/4", "3/4", "3/4"]
    equal (f [(0, 2, "4/4"), (2, 4, "3/4")]) $ Right ["4/4", "3/4"]
    equal (f [(0, 2, "4/4"), (1, 2, "4/4"), (2, 2, "4/4")]) $ Right ["4/4"]

test_convert_duration = do
    let f meter pos = Lilypond.to_lily $ head $
            Lilypond.convert_duration meter True False pos (whole - pos)
    equal (map (f (mkmeter "4/4")) [0, 8 .. 127])
        [ "1", "8.", "4.", "16", "2.", "8.", "8", "16"
        -- mid-measure
        , "2", "8.", "4.", "16", "4", "8.", "8", "16"
        ]
    equal (map (f (mkmeter "2/4")) [0, 8 .. 127]) $
        concat $ replicate 2 ["2", "8.", "4.", "16", "4", "8.", "8", "16"]

test_make_ly = do
    let (events, logs) = derive $ concatMap UiTest.note_spec
            -- complicated rhythm
            [ ("s/i1", [(0, 1, "4c"), (1.5, 2, "4d#")], [])
            -- rhythm starts after 0, long multi measure note
            , ("s/i2", [(1, 1, "4g"), (2, 12, "3a")], [])
            ]
    equal logs []
    -- Shorter staff is padded out to the length of the longer one.
    equal (LilypondTest.convert_events [] events) $ Right
        [ ("i1",
            [[["c'4", "r8", "ds'8~", "ds'4.", "r8"], ["r1"], ["r1"], ["r1"]]])
        , ("i2",
            [[["r4", "g'4", "a2~"], ["a1~"], ["a1~"], ["a2", "r2"]]])
        ]
    -- putStrLn $ LilypondTest.make_ly events
    -- compile_ly events

test_hands = do
    let (events, logs) = derive $ concatMap UiTest.note_spec
            [ (">s/1 | hand = 'right'", [(0, 4, "4c")], [])
            , (">s/1 | hand = 'left'", [(0, 4, "4d")], [])
            , (">s/2", [(0, 4, "4e")], [])
            ]
    equal logs []
    -- Right hand goes in first.
    equal (LilypondTest.convert_events [] events) $ Right
        [ ("1", [[["c'1"]], [["d'1"]]])
        , ("2", [[["e'1"]]])
        ]

test_clefs = do
    let f = first (convert_staves ["clef"]) . derive
    equal (f
            [ (">s/1 | clef = 'bass'", [(0, 2, ""), (2, 6, "clef = 'alto' |")])
            , ("*", [(0, 0, "4c")])
            ])
        (Right [["\\clef bass", "c'2", "\\clef alto", "c'2~"], ["c'1"]], [])

    -- test annotation promote
    -- The first clef and key are moved ahead of rests.
    equal (f $ UiTest.note_spec ("s/1", [(1, 3, "4c")], []))
        (Right [["\\clef treble", "r4", "c'2."]], [])

    -- Even if there are measures of rests.
    equal (f $ UiTest.note_spec ("s/1", [(5, 3, "4c")], []))
        (Right [["\\clef treble", "r1"], ["r4", "c'2."]], [])

test_key = do
    let f = first (convert_staves ["key"]) . derive
    equal (f
            [ (">s/1 | key = 'a-mixo'", [(0, 2, ""), (2, 2, "key = 'c-maj' |")])
            , ("*", [(0, 0, "4c")])
            ])
        (Right [["\\key a \\mixolydian", "c'2", "\\key c \\major", "c'2"]], [])

test_ly_code = do
    let f call = first (convert_staves2 [])
            . LilypondTest.derive_linear False
                (CallTest.with_note_call "code" call)
    equal (f c_magic [(">", [(0, 1, "code")])])
        (Right ["magic-lilypond-code r4 r2"], [])
    equal (f c_magic [(">", [(0, 0, "code")])])
        (Right ["magic-lilypond-code r1"], [])

    -- Ensure that a 0 dur event in the middle of a chord doesn't mess it up,
    -- courtesy of 'Lilypond.promote_0dur'.
    equal (f c_note
        [ (">", [(0, 1, ""), (1, 1, "")])
        , ("*", [(0, 0, "4a"), (1, 0, "4b")])
        , (">", [(0, 1, ""), (1, 1, "code")])
        , ("*", [(0, 0, "4c"), (1, 0, "4d")])
        ])
        (Right ["<a' c'>4 code0 <b' d'>4 r2"], [])
    where
    c_magic = CallTest.generator $ \args ->
        Lily.code (Args.extent args) "magic-lilypond-code"
    c_note = CallTest.generator $ Note.inverting $ \args ->
        Lily.code0 (Args.start args) "code0" <> Util.placed_note args

convert_staves2 :: [String] -> [Lilypond.Event] -> Either String [String]
convert_staves2 wanted = fmap (map unwords) . convert_staves wanted

test_allowed_time_greedy = do
    let f meter = extract_rhythms
            . map (Lilypond.allowed_time_greedy True (mkmeter meter))
        t = Lilypond.dur_to_time

    -- 4/4, being duple, is liberal about spanning beats, since it uses rank-2.
    equal (f "4/4" [0, t D4 .. 4 * t D4]) "1 2. 2 4 1"
    equal (f "4/4" [0, t D8 .. 8 * t D8])
        "1 4. 2. 8 2 4. 4 8 1"

    -- 6/8 is more conservative.
    equal (f "3+3/8" [0, t D8 .. 6 * t D8])
        "2. 4 8 4. 4 8 2."

    -- Irregular meters don't let you break the middle dividing line no matter
    -- what, because 'Meter.find_rank' always stops at rank 0.
    equal (f "3+2/4" [0, t D8 .. 10 * t D8])
        "2. 8 2 8 4 8 2 8 4 8 2."
        -- This has 8 after the middle 2 instead of 4. like 4/4 would have.
        -- That's because it's not duple, so it's more conservative.
        -- I guess that's probably ok.

test_allowed_time_best = do
    let f use_dot meter = extract_rhythms
            . map (Lilypond.allowed_time_best use_dot (mkmeter meter))
        t = Lilypond.dur_to_time
    equal (f False "4/4" [0, t D4 .. 4 * t D4])
        "1 4 2 4 1"
    equal (f False "4/4" [0, t D8 .. 8 * t D8])
        "1 8 4 8 2 8 4 8 1"
    equal (f True "3+3/8" [0, t D8 .. 6 * t D8])
        "2. 4 8 4. 4 8 2."

extract_rhythms :: [Lilypond.Time] -> String
extract_rhythms = unwords
        . map (Lilypond.to_lily . expect1 . Lilypond.time_to_note_durs)
    where
    expect1 [x] = x
    expect1 xs = error $ "expected only one element: " ++ show xs

-- * test lilypond derivation

-- These actually test derivation in lilypond mode.  So maybe they should go
-- in derive, but if I put them here I can test all the way to lilypond score.

test_enharmonics = do
    let (events, logs) = derive $ UiTest.note_track
            [(0, 1, "4c#"), (1, 1, "4db"), (2, 1, "4cx")]
    equal logs []
    equal (convert_staves [] events) $
        Right [["cs'4", "df'4", "css'4", "r4"]]

test_tempo = do
    -- Lilypond derivation is unaffected by the tempo.
    let (events, logs) = derive
            [ ("tempo", [(0, 0, "3")])
            , (">s/1", [(0, 4, ""), (4, 4, "")])
            , ("*", [(0, 0, "4c")])
            ]
        extract e = (Lilypond.event_start e, Lilypond.event_duration e)
    equal logs []
    equal (map extract events) [(0, whole), (whole, whole)]

-- * util

compile_ly :: [Lilypond.Event] -> IO ()
compile_ly events = do
    writeFile "build/test/test.ly" (LilypondTest.make_ly events)
    void $ Process.rawSystem
        "lilypond" ["-o", "build/test/test", "build/test/test.ly"]

read_note :: String -> Lilypond.Note
read_note text
    | pitch == "r" = Lilypond.rest dur
    | otherwise = Lilypond.Note
        { Lilypond._note_pitch = [pitch]
        , Lilypond._note_duration = dur
        , Lilypond._note_tie = tie == "~"
        , Lilypond._note_prepend = ""
        , Lilypond._note_append = ""
        , Lilypond._note_stack = Nothing
        }
    where
    (pitch, rest) = break Char.isDigit text
    (dur_text, tie) = break (=='~') rest
    Just dur = flip Lilypond.NoteDuration False <$>
        Lilypond.read_duration dur_text

simple_event :: (RealTime, RealTime, String) -> Lilypond.Event
simple_event (start, dur, pitch) = make_event start dur pitch "" []

environ_event :: (RealTime, RealTime, String, [(TrackLang.ValName, String)])
    -> Lilypond.Event
environ_event (start, dur, pitch, env) = make_event start dur pitch "" env

meter_event :: (RealTime, RealTime, String, String) -> Lilypond.Event
meter_event (s, d, p, meter) =
    environ_event (s, d, p, [(Lilypond.v_meter, meter)])

make_event :: RealTime -> RealTime -> String -> String
    -> [(TrackLang.ValName, String)] -> Lilypond.Event
make_event start dur pitch inst env = Lilypond.Event
    { Lilypond.event_start = Lilypond.real_to_time 1 start
    , Lilypond.event_duration = Lilypond.real_to_time 1 dur
    , Lilypond.event_pitch = pitch
    , Lilypond.event_instrument = Score.Instrument inst
    , Lilypond.event_dynamic = 0.5
    , Lilypond.event_environ = TrackLang.make_environ
        [(name, TrackLang.VString val) | (name, val) <- env]
    , Lilypond.event_stack = UiTest.mkstack (1, 0, 1)
    }

mkmeter :: String -> Meter.Meter
mkmeter s = case Meter.parse_meter s of
    Left err -> error $ "can't parse " ++ show s ++ ": " ++ err
    Right val -> val

whole :: Lilypond.Time
whole = Lilypond.time_per_whole
