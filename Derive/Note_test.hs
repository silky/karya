module Derive.Note_test where

import qualified Data.Maybe as Maybe

import Util.Test
import qualified Util.Log as Log

import Ui.Types
import qualified Ui.Block as Block
import qualified Ui.Id as Id
import qualified Ui.State as State
import qualified Ui.TestSetup as TestSetup

import qualified Derive.Note as Note
import qualified Derive.Scale as Scale

import qualified Derive.Derive_test as Derive_test

import qualified Perform.Signal as Signal
import qualified Perform.Pitch as Pitch

import qualified Derive.Derive as Derive
import qualified Derive.Twelve as Twelve


-- * derivers

test_d_instrument_track = do
    let d tid = Note.d_note_track Scale.scale_map (Note.scale_parser scale) tid
    let (tids, state) = TestSetup.run_mkstate
            [ ("0", [(0, 10, "5a-"), (10, 10, "5b-"), (20, 10, "5c-")])
            , ("1", [(0, 10, ".1"), (10, 10, ".2"), (20, 10, ".4")])
            ]
    print tids
    let (val, _tempo, _inv_tempo, logs) =
            derive Derive.empty_lookup_deriver state (d (head tids))
    mapM_ pprint val

test_derive_note = do
    let mkevt text parsed = Note.ParsedEvent text parsed
            (TrackPos 1) (TrackPos 1)
        note_evt =
            mkevt "5a-" (Note.ParsedNote (Just Signal.Set) (mkpitch "5a-"))
        call_evt = mkevt sub_name (Note.ParsedCall sub_name)

        (tids, ui_state) = TestSetup.run State.empty
            (TestSetup.mkstate sub_name [("0", [(1, 1, "5a-")])])
        lookup = lookup_deriver (Note.derive_note note_evt)
        run deriver = (Derive_test.extract_events evts, map Log.msg_text logs)
            where
            (evts, logs) = Derive_test.derive_events ui_state lookup deriver

    equal (run (Note.derive_note note_evt)) ([(1.0, 1.0, "5a-")], [])
    -- Shifted by 1, stretched to fit in event dur 1.
    equal (run (Note.derive_note call_evt)) ([(1.5, 0.5, "5a-")], [])

sub_name = "sub"
sub_block = Block.BlockId $ Id.id (State.state_project State.empty) sub_name

lookup_deriver deriver block_id
    | block_id == sub_block = Right deriver
    | otherwise = Left (State.StateError "not found")

-- * parse

scale = Twelve.scale
mkpitch note = Pitch.Pitch (Pitch.scale_id scale) (Pitch.Note note)

test_parse_note = do
    -- let parse = either (const Nothing) Just . P.parse (Note.p_note scale) ""
    let parse = Note.default_parse_note scale

    equal (parse "7q#") $ Left "note not in scale: \"7q#\""
    equal (parse "blor, 7c#") $ Left "couldn't parse method: \"blor\""

    let p = mkpitch "7c#"
    equal (parse "i, 7c#") $ Right $ Note.ParsedNote (Just Signal.Linear) p
    equal (parse "2.1e, 7c#") $ Right $
        Note.ParsedNote (Just (Signal.Exp 2.1)) p
    equal (parse "i, 7c#, <block") $ Left $
        "too many words in note: [\"i\",\"7c#\",\"<block\"]"

test_tokenize = do
    let prop toks =
            equal (Note.tokenize_note (Note.untokenize_note toks)) (Right toks)
    sequence_ [prop (a, b) | a <- ["", "i"], b <- ["", "n"]]


-- * util

derive = Derive_test.derive
