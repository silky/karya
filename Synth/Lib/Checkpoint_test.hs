-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Synth.Lib.Checkpoint_test where
import qualified Data.Set as Set
import qualified System.FilePath as FilePath

import qualified Synth.Lib.Checkpoint as Checkpoint
import qualified Synth.Shared.Note as Note

import           Global
import           Synth.Types
import           Util.Test


-- Many functions in Checkpoint are tested by caller tests, e.g.
-- 'Synth.Faust.Render_test'.

test_hashOverlapping = do
    let f start size = Checkpoint.hashOverlapping start size . map mkSpan
    equal (f 0 1 []) []
    -- 0 dur notes are also counted.
    equal (f 0 1 [(0, 0)]) [Checkpoint._hash $ mkSpan (0, 0)]

    check_val (f 0 1 [(1, 2)]) $ \case
        [x0, x1, x2] -> x0 == mempty && x1 == x2
        _ -> False
    check_val (f 0 2 [(1, 2)]) $ \case
        [x1, x2] -> x1 /= mempty && x1 == x2
        _ -> False
    check_val (f 0 1 [(0, 3), (1, 1)]) $ \case
        [x1, y1, x2] -> y1 /= mempty && x1 == x2
        _ -> False

test_groupOverlapping = do
    let f start size = map (map (eSpan . snd))
            . Checkpoint.groupOverlapping start size
            . map (((),) . mkSpan)
    equal (f 0 1 []) []

    -- 0 dur notes also included.
    equal (f 0 1 [(0, 0)]) [[(0, 0)]]
    equal (f 0 1 [(0, 0), (1, 0)]) [[(0, 0)], [(1, 0)]]
    equal (f 0 1 [(0, 0), (0.5, 0), (1, 0)]) [[(0, 0), (0.5, 0)], [(1, 0)]]
    equal (f 0 1 [(0, 0), (0.5, 1), (1, 0)])
        [[(0, 0), (0.5, 1)], [(0.5, 1), (1, 0)]]

    equal (f 0 1 [(1, 2)]) [[], [(1, 2)], [(1, 2)]]
    equal (f 0 2 [(1, 2)]) [[(1, 2)], [(1, 2)]]
    equal (f 1 2 [(1, 2)]) [[(1, 2)]]
    equal (f 0 1 [(0, 3), (1, 1)]) [[(0, 3)], [(0, 3), (1, 1)], [(0, 3)]]
    -- this is the Checkpoint.groupOverlapping haddock example
    equal (f 0 2 [(1, 2), (2, 1), (3, 2), (4, 1)])
        [[(1, 2)], [(1, 2), (2, 1), (3, 2)], [(3, 2), (4, 1)]]

test_findLastState = do
    let f files = Checkpoint.findLastState (Set.fromList files)
            . map (second (Note.Hash))
    let initialState = Checkpoint.encodeState $ Checkpoint.State mempty
    let fn chunk hash state =
            Checkpoint.filenameOf2 chunk (Note.Hash hash) state
    let wav1 = fn 0 "a" initialState
    equal (f [] [(0, "a")]) ([], ([(0, Note.Hash "a")], ""))
    -- .wav is present, but not .state, don't skip the .wav.
    equal (f [wav1] [(0, "a"), (1, "b")])
        ([], ([(0, Note.Hash "a"), (1, Note.Hash "b")], ""))
    let state1 = FilePath.replaceExtension wav1 ".state.b"
    equal (f [wav1, state1] [(0, "a"), (1, "b")])
        ([wav1], ([(1, Note.Hash "b")], state1))

-- filenameOf2 :: Config.ChunkNum -> Note.Hash -> String -> FilePath

mkSpan :: (RealTime, RealTime) -> Checkpoint.Span
mkSpan (s, d) = Checkpoint.Span
    { _start = s
    , _duration = d
    , _hash = Note.hash (s, d)
    }

eSpan :: Checkpoint.Span -> (RealTime, RealTime)
eSpan n = (Checkpoint._start n, Checkpoint._duration n)
