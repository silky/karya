module Perform.Lilypond.Lilypond_test where
import qualified Data.Char as Char
import qualified Data.Map as Map
import qualified System.Process as Process

import Util.Control
import qualified Util.Pretty as Pretty
import Util.Test

import qualified Ui.UiTest as UiTest
import qualified Derive.Derive as Derive
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.LEvent as LEvent

import qualified Perform.Lilypond.Convert as Convert
import qualified Perform.Lilypond.Lilypond as Lilypond
import qualified Perform.Pitch as Pitch

import Types


test_convert_notes = do
    let f sig = map Lilypond.to_lily . Lilypond.convert_notes False sig
            . map mkevent
        s44 = sig 4 4
    equal (f s44 [(0, 1, "a"), (1, 1, "b")])
        ["a4", "b4", "r2"]
    -- Rests are not dotted, even when they could be.
    equal (f s44 [(0, 1, "a"), (1.5, 1, "b")])
        ["a4", "r8", "b8~", "b8", "r8", "r4"]

test_convert_duration = do
    let f sig pos = Lilypond.to_lily $ head $
            Lilypond.convert_duration sig True pos
                (Lilypond.time_per_whole - pos)
    equal (map (f (sig 4 4)) [0, 8 .. 127])
        [ "1", "8.", "4.", "16", "2.", "8.", "8", "16"
        -- mid-measure
        , "2", "8.", "4.", "16", "4", "8.", "8", "16"
        ]
    equal (map (f (sig 2 4)) [0, 8 .. 127]) $
        concat $ replicate 2 ["2", "8.", "4.", "16", "4", "8.", "8", "16"]

test_make_score = do
    let (score, notes, events) = run (mkmeta "title" "treble" "4/4")
            ("", [(0, 1, "4c"), (1.5, 2, "4d#")], [])
    equal notes ["c'4", "r8", "ds'8~", "ds'4.", "r8"]
    -- compile_ly score
    pprint events
    pprint score


-- * util

compile_ly :: Pretty.Doc -> IO ()
compile_ly score = do
    writeFile "build/test/test.ly" (Pretty.formatted score)
    void $ Process.rawSystem
        "lilypond" ["-o", "build/test/test", "build/test/test.ly"]

read_note :: String -> Lilypond.Note
read_note text
    | pitch == "r" = Lilypond.rest dur
    | otherwise = Lilypond.note pitch dur (tie == "~")
    where
    (pitch, rest) = break Char.isDigit text
    (dur_text, tie) = break (=='~') rest
    Just dur = flip Lilypond.NoteDuration False <$>
        Lilypond.read_duration dur_text

mkmeta :: String -> String -> String -> Map.Map String String
mkmeta title clef sig = Map.fromList
    [ (Lilypond.meta_ly, "")
    , (Lilypond.meta_title, title)
    , (Lilypond.meta_clef, clef)
    , (Lilypond.meta_time_signature, sig)
    ]

run :: Map.Map String String -> UiTest.NoteSpec
    -> (Pretty.Doc, [String], [Lilypond.Event])
run meta note_spec =
    (Lilypond.make_score score events,
        map Lilypond.to_lily (Lilypond.convert_notes False sig events),
        events)
    where
    sig = Lilypond.score_time score
    res = DeriveTest.derive_tracks (UiTest.note_spec note_spec)
    (events, _logs) = LEvent.partition $ Convert.convert Lilypond.D4
        (Derive.r_events res)
    Just (Right score) = Lilypond.meta_to_score (Just (Pitch.Key "d-min")) meta

score0 = Lilypond.make_score
    (Lilypond.Score "hi there" (sig 3 4) "treble" ("d", Lilypond.Major)
        Lilypond.D4)
    [Lilypond.Event start dur pitch | (start, dur, pitch) <-
        [(0, 4, "a"), (4, 4, "b"), (16, 2, "a"), (18, 2, "b")]]


mkevent :: (RealTime, RealTime, String) -> Lilypond.Event
mkevent (start, dur, pitch) =
    Lilypond.Event (Convert.real_to_time Lilypond.D4 start)
        (Convert.real_to_time Lilypond.D4 dur) pitch

sig :: Int -> Int -> Lilypond.TimeSignature
sig num denom = Lilypond.TimeSignature num dur
    where Just dur = Lilypond.read_duration (show denom)
