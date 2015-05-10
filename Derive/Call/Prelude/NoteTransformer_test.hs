module Derive.Call.Prelude.NoteTransformer_test where
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Score as Score


test_clip = do
    let run top = run_sub DeriveTest.e_start_dur [(">", top)]
            [(">", [(0, 1, ""), (1, 1, "")])]
    -- make sure out of range notes are clipped
    equal (run [(0, 1, "clip | sub")]) ([(0, 1)], [])

    -- sub goes *4/2 + 1 ==> [(1, 2), (3, 2)]
    -- I want            ==> [(1, 1), (2, 1)]
    -- so (-1) (*0.5)
    equal (run [(1, 4, "clip | sub")]) ([(1, 1), (2, 1)], [])

    -- sub goes *1.5/2 + 1 ==> [(1, 0.75), (1.75, 0.75)]
    -- I want              ==> [(1, 1), (2, 1)]
    -- so (-1) (* 1/.75)
    -- notes that overlap the end are shortened
    equal (run [(1, 1.5, "clip | sub")]) ([(1, 1), (2, 0.5)], [])

    -- clip works even when it's not directly a block call.
    equal (run [(1, 1.5, "^b=sub | clip | b")]) ([(1, 1), (2, 0.5)], [])

test_clip_start = do
    let run = run_sub DeriveTest.e_note
    -- Aligned to the end.
    equal (run [(">", [(0, 2, "Clip | sub")])] (UiTest.regular_notes 1))
        ([(1, 1, "3c")], [])
    -- Get the last two notes.
    equal (run [(">", [(0, 2, "Clip | sub")])] (UiTest.regular_notes 3))
        ([(0, 1, "3d"), (1, 1, "3e")], [])

test_loop = do
    let run = run_sub DeriveTest.e_start_dur
    equal (run [(">", [(0, 4, "loop | sub")])] [(">", [(0, 1, "")])])
        ([(0, 1), (1, 1), (2, 1), (3, 1)], [])
    -- Cuts off the last event.
    let sub = [(">", [(0, 1, ""), (1, 3, "")])]
    equal (run [(">", [(0, 5, "loop | sub")])] sub)
        ([(0, 1), (1, 3), (4, 1)], [])

test_tile = do
    let run top = run_sub Score.event_start [(">", top)]
            [(">", [(0, 1, ""), (1, 3, "")])]
    -- If it starts at 0, it's just like 'loop'.
    equal (run [(0, 5, "tile | sub")]) ([0, 1, 4], [])
    equal (run [(1, 5, "tile | sub")]) ([1, 4, 5], [])
    equal (run [(9, 5, "tile | sub")]) ([9, 12, 13], [])

run_sub :: (Score.Event -> a) -> [UiTest.TrackSpec] -> [UiTest.TrackSpec]
    -> ([a], [String])
run_sub extract top sub = DeriveTest.extract extract $ DeriveTest.derive_blocks
    [("top", top), ("sub=ruler", sub)]
