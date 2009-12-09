module Derive.Control_test where
import qualified Data.Map as Map
import qualified Data.Text as Text

import Util.Test
import qualified Util.Log as Log

import qualified Ui.State as State

import qualified Perform.Pitch as Pitch
import qualified Perform.PitchSignal as PitchSignal
import qualified Perform.Signal as Signal

import qualified Derive.Score as Score

import qualified Derive.Derive_test as Derive_test
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Control as Control


test_d_signal = do
    let track_signal = Signal.track_signal Signal.default_srate
    let f = Control.d_signal
    let run evts = case Derive_test.run State.empty (f evts) of
            Left err -> Left err
            Right (val, _dstate, msgs) -> Right (val, map Log.msg_string msgs)

    let Right (sig, msgs) = run [mkevent 0 "bad", mkevent 1 "i, bad"]
    equal sig (track_signal [])
    strings_like msgs ["parse error on char 1", "parse error on char 4"]

    let sig = track_signal
            [(0, Signal.Set, 0), (1, Signal.Linear, 1), (1.5, Signal.Exp 2, 0)]
    equal (run [mkevent 0 "0", mkevent 1 "i, 1", mkevent 1.5 "2e, 0"]) $
        Right (sig, [])

    -- error in the middle is ignored
    let Right (sig, msgs) = run [mkevent 0 "0", mkevent 1 "blah", mkevent 1 "1"]
    equal sig (track_signal [(0, Signal.Set, 0), (1, Signal.Set, 1)])
    strings_like msgs ["parse error on char 1"]

test_d_pitch_signal = do
    let scale_id = Twelve.scale_id
    let track_signal segs = PitchSignal.track_signal scale_id
            Signal.default_srate
            [(x, meth, Pitch.Generic n) | (x, meth, n) <- segs]
    let f = Control.d_pitch_signal
    let run evts = case Derive_test.run State.empty (f scale_id evts) of
            Left err -> Left err
            Right (val, _dstate, msgs) -> Right (val, map Log.msg_string msgs)

    let (sig, msgs) = expect_right "running derive" $
            run [mkevent 0 "0 blah", mkevent 1 "i, bad"]
    equal sig (track_signal [])
    strings_like msgs ["trailing junk: \" blah\"", "Note \"0\" not in ScaleId",
        "Note \"bad\" not in ScaleId"]

    let sig = track_signal
            [(0, Signal.Set, 60), (1, Signal.Set, 62), (2, Signal.Linear, 64)]
    equal (run [mkevent 0 "4c", mkevent 1 "4d", mkevent 2 "i, 4e"]) $
        Right (sig, [])

    -- blank notes inherit the previous pitch
    let sig = track_signal [(0, Signal.Set, 60), (1, Signal.Linear, 60),
            (2, Signal.Linear, 64)]
    equal (run [mkevent 0 "4c", mkevent 1 "i,", mkevent 2 "i, 4e"]) $
        Right (sig, [])

mkevent pos text =
    Score.Event pos 0 (Text.pack text) Map.empty PitchSignal.empty
        [] Nothing Score.no_attrs
