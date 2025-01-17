-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.C.Prelude.Control_test where
import Util.Test
import qualified Derive.Call.CallTest as CallTest
import qualified Derive.DeriveTest as DeriveTest
import qualified Perform.Signal as Signal
import Global
import Types


run :: [(ScoreTime, Text)] -> [(RealTime, Signal.Y)]
run = CallTest.run_control

test_set :: Test
test_set = do
    equal (run [(0, "1"), (1, "0")]) [(0, 1), (1, 1), (1, 0)]
    equal (run [(0, "1"), (1, "")]) [(0, 1)]

test_set_transformer :: Test
test_set_transformer = do
    -- interpolate, then set
    equal (run [(0, "1"), (2, "3 | i 0")]) [(0, 1), (2, 0), (2, 3)]
    -- set, then interpolate
    equal (run [(0, "from=0 | i> 1"), (2, "0")]) [(0, 0), (2, 1), (2, 0)]

test_set_prev :: Test
test_set_prev = do
    let run ex tracks = DeriveTest.extract ex $ DeriveTest.derive_tracks "" $
            (">", [(0, 1, ""), (1, 1, ""), (2, 1, "")]) : tracks
    equal (run (DeriveTest.e_control "c")
            [("c", [(0, 0, ".5"), (1, 0, "'"), (2, 0, "'")])])
        ([[(0, 0.5)], [(1, 0.5)], [(2, 0.5)]], [])

test_porta :: Test
test_porta = do
    equal (run [(0, "0"), (1, "porta-place=1 | p 1 2s")])
        [(0, 0), (1, 0), (3, 1)]
    equal (run [(0, "0"), (1, "porta-place=1 | curve=(cf-expon 2) | p 1 2s")])
        [(0, 0), (1, 0), (2, 0.25), (3, 1)]

test_abs :: Test
test_abs = do
    let run = DeriveTest.extract (DeriveTest.e_control "c")
            . DeriveTest.derive_tracks_linear "" . (++ [(">", [(0, 1, "")])])
    equal (run [("c", [(0, 0, ".5")]), ("c", [(0, 0, ".5")])])
        ([[(0, 0.25)]], [])
    equal (run [("c", [(0, 0, ".5")]), ("c", [(0, 0, "abs .75")])])
        ([[(0, 0.75)]], [])
    -- Nothing can be done if the input is 0.
    equal (run [("c", [(0, 0, "0")]), ("c", [(0, 0, "abs .75")])])
        ([[(0, 0)]], [])

    equal (run [("c", [(0, 0, ".5")]), ("c set", [(0, 0, "abs .75")])])
        ([[(0, 0.75)]], [])
    equal (run [("c", [(0, 0, ".5")]), ("c add", [(0, 0, "abs .75")])])
        ([[(0, 0.75)]], [])
    equal (run [("c", [(0, 0, ".5")]), ("c sub", [(0, 0, "abs .75")])])
        ([[(0, 0.75)]], [])
    equal (run [("c", [(0, 0, ".5")]), ("c mul", [(0, 0, "abs .75")])])
        ([[(0, 0.75)]], [])
    equal (run [("c", [(0, 0, ".5")]), ("c scale", [(0, 0, "abs .75")])])
        ([[(0, 0.75)]], [])
    equal (run [("c", [(0, 0, ".5")]), ("c scale", [(0, 0, "abs .25")])])
        ([[(0, 0.25)]], [])

test_linear :: Test
test_linear = do
    equal (run [(0, "1"), (2, "i 0")]) [(0, 1), (2, 0)]
    -- Explicit duration overrides.
    equal (CallTest.run_control_dur [(0, 0, "1"), (2, 2, "i 0")])
        [(0, 1), (2, 1), (4, 0)]

test_linear_next :: Test
test_linear_next = do
    equal (run [(0, "1"), (4, "i> 0"), (6, "0")])
        [(0, 1), (4, 1), (6, 0)]

test_exponential :: Test
test_exponential = do
    equal (run [(0, "1"), (4, "e 0")])
        [(0, 1), (1, 0.9375), (2, 0.75), (3, 0.4375), (4, 0)]
    equal (run [(0, "1"), (4, "e 0 1")])
        [(0, 1), (1, 0.75), (2, 0.5), (3, 0.25), (4, 0)]
    equal (run [(0, "1"), (4, "e 0 -1")])
        [(0, 1), (1, 0.75), (2, 0.5), (3, 0.25), (4, 0)]
    equal (run [(0, "1"), (4, "e 0 -2")])
        [(0, 1), (1, 0.5),
            (2, 0.2928932188134524), (3, 0.1339745962155614), (4, 0)]

test_nested :: Test
test_nested = do
    -- This used to get the wrong result thanks to drop_discontinuity_at
    -- dropping a non-discontinuity with equal samples.
    -- TODO remove when I can get rid of drop_discontinuity_at.
    let run = DeriveTest.extract extract
            . DeriveTest.derive_blocks
        extract e = (DeriveTest.e_start_dur e, DeriveTest.e_dyn e)
    let ui = run
            [ ("top",
                [ ("dyn", [(0, 0, "1"), (4, 0, "1"), (8, 0, "i .5"),
                    (12, 0, "i 0")])
                , (">", [(0, 12, "sub1")])
                ])
            , ("sub1=ruler", [(">", [(6, 6, "")])])
            ]
    equal ui ([((6, 6), [(4, 1), (8, 0.5), (12, 0)])], [])

    let ui = run
            [ ("top",
                [ ("dyn", [(0, 0, "1"), (4, 0, "i> .5"), (8, 0, "i> 0"),
                    (12, 0, "0")])
                , (">", [(0, 12, "sub1")])
                ])
            , ("sub1=ruler", [(">", [(6, 6, "")])])
            ]
    equal ui ([((6, 6), [(4, 1), (8, 0.5), (12, 0)])], [])

-- * misc

test_breakpoint_next :: Test
test_breakpoint_next = do
    equal (run [(0, "bp> 1"), (4, "0")]) [(0, 1), (4, 1), (4, 0)]
    equal (run [(0, "bp> 1 0"), (4, "0")]) [(0, 1), (4, 0)]
    equal (run [(0, "bp> 1 0 1"), (4, "0")]) [(0, 1), (2, 0), (4, 1), (4, 0)]

test_neighbor :: Test
test_neighbor = do
    equal (run [(0, "n 1 2")]) [(0, 1), (2, 0)]
    equal (run [(0, "n 2 1")]) [(0, 2), (1, 0)]

test_up_down :: Test
test_up_down = do
    equal (run [(0, "2"), (1, "d 1 0"), (5, "2")])
        [(0, 2), (1, 2), (3, 0), (5, 0), (5, 2)]
    equal (run [(0, "3"), (1, "d"), (3, "0")])
        [(0, 3), (1, 3), (3, 1), (3, 0)]
    equal (run [(0, "2"), (1, "d .5"), (5, "0")])
        [(0, 2), (1, 2), (5, 0)]
    equal (run [(0, "from=1 | d .5")]) [(0, 1), (2, 0)]
    equal (run [(0, "from=.5 | d .25")]) [(0, 0.5), (2, 0)]
    equal (run [(0, "1"), (1, "d .5"), (6, "1")])
        [(0, 1), (1, 1), (3, 0), (6, 0), (6, 1)]

    equal (run [(0, "-1"), (1, "u 1 1"), (5, "0")])
        [(0, -1), (1, -1), (3, 1), (5, 1), (5, 0)]
    equal (run [(0, "-2"), (1, "u 1 1"), (3, "1")])
        [(0, -2), (1, -2), (3, 0), (3, 1)]
    equal (run [(0, "0"), (1, "u .5 1"), (5, "1")])
        [(0, 0), (1, 0), (3, 1), (5, 1)]

test_down_from :: Test
test_down_from = do
    equal (run [(0, "df 1 .5 0")]) [(0, 1), (2, 0)]
    equal (run [(0, "df .5 .25 0")]) [(0, 0.5), (2, 0)]

test_pedal :: Test
test_pedal = do
    equal (CallTest.run_control_dur [(0, 1, "ped .5")])
        [(0, 0.5), (1, 0.5), (1, 0)]
    -- Goes back to the original value.
    equal (CallTest.run_control_dur [(0, 0, "1"), (1, 1, "ped .5")])
        [(0, 1), (1, 1), (1, 0.5), (2, 0.5), (2, 1)]
    equal (CallTest.run_control_dur [(0, 0, "pedal-dur=.5 | ped .5")])
        [(0, 0.5), (0.5, 0.5), (0.5, 0)]

test_swell :: Test
test_swell = do
    equal (CallTest.run_control_dur [(0, 8, "swell 0 1 .5")])
        [(0, 0), (4, 1), (8, 0)]
    equal (CallTest.run_control_dur [(0, 4, "swell 0 1 0")])
        [(0, 1), (4, 0)]
