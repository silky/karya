-- Copyright 2015 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Call.India.Gamakam3_test where
import Util.Test
import qualified Ui.UiTest as UiTest
import qualified Derive.Call.India.Gamakam3 as Gamakam
import Derive.Call.India.Gamakam3 (Expr_(..))
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Score as Score

import Global
import Types


test_parse_sequence = do
    let f = first untxt . Gamakam.parse_sequence
    equal (f " [-]> ") $ Right [DynExpr ">" "" "" [PitchExpr '-' ""]]
    equal (f "#012 -4") $ Right
        [ PitchExpr '0' "", PitchExpr '1' "", PitchExpr '2' ""
        , PitchExpr '-' "4"
        ]
    equal (f "a b1  c") $ Right
        [PitchExpr 'a' "", PitchExpr 'b' "1", PitchExpr 'c' ""]
    equal (f "#ab c") $ Right
        [PitchExpr 'a' "", PitchExpr 'b' "", PitchExpr 'c' ""]

    equal (f "[a]x>y") $ Right [DynExpr ">" "x" "y" [PitchExpr 'a' ""]]
    equal (f "[a]>") $ Right [DynExpr ">" "" "" [PitchExpr 'a' ""]]
    equal (f "[a]>[b]<") $ Right
        [ DynExpr ">" "" "" [PitchExpr 'a' ""]
        , DynExpr "<" "" "" [PitchExpr 'b' ""]
        ]
    equal (f "[a[b]>]<") $ Right
        [DynExpr "<" "" ""
            [PitchExpr 'a' "", DynExpr ">" "" "" [PitchExpr 'b' ""]]]
    -- Word notation vs. compact notation.
    equal (f "[a1]>") $ Right [DynExpr ">" "" "" [PitchExpr 'a' "1"]]
    equal (f "#[a1]>") $ Right
        [DynExpr ">" "" "" [PitchExpr 'a' "", PitchExpr '1' ""]]
    equal (f "#ab[cd]>") $ Right
        [ PitchExpr 'a' "", PitchExpr 'b' ""
        , DynExpr ">" "" "" [PitchExpr 'c' "", PitchExpr 'd' ""]
        ]

    left_like (f "ab [c") "parse error"
    left_like (f "#ab[c") "parse error"
    left_like (f "ab c]") "parse error"

-- test_resolve_exprs = do
--     equal (f "#56u") $ Right
--         [ PitchExpr '5' "", PitchExpr '6' "", PitchExpr '-' "1"
--         , PitchExpr '1' ""
--         ]
--     equal (f "#!12") $ Left "not found: '!', not found: '('"

test_sequence = do
    let run c = derive_tracks DeriveTest.e_nns_rounded $
            make_tracks (4, "--") (6, c)
        output nns = ([[(0, 60)], nns, [(10, 64)]], [])

    -- 4 5 6 7 8 9 10
    -- ------++++++
    equal (run "##-") (output [(4, 62)])
    -- The error shows up twice because of slicing.
    strings_like (snd $ run "#0nn")
        ["too many arguments: nn", "too many arguments: nn"]

    -- transition=1 takes all the time, and winds up being linear.
    equal (run "transition=1 | ##01")
        (output [(4, 62), (7, 62), (8, 62.67), (9, 63.33)])
    -- Fastest transition.
    equal (run "transition=0 | ##01")
        (output [(4, 62), (7, 62), (8, 62.13), (9, 63.87)])

    -- 4 5 6 7 8 9 10
    -- ----++++----
    equal (run "##010") (output [(4, 62), (6, 62), (7, 63), (8, 64)])
    equal (run "##0a0") (output [(4, 62), (6, 62), (7, 61), (8, 60)])

    -- move_absolute
    -- Move to next pitch.
    -- TODO not working yet
    -- equal (run "##-d-") (output [(4, 62), (6, 62), (7, 63), (8, 64)])

    -- Prev to current.
    equal (run "##<-c-") (output [(4, 60), (6, 60), (7, 61), (8, 62)])

    -- +1 to current.
    equal (run "# P1c #-c-") (output [(4, 63), (6, 63), (7, 62.5), (8, 62)])
    -- Current to -1nn.
    equal (run "##-y-") (output [(4, 62), (6, 62), (7, 61.5), (8, 61)])

test_dyn = do
    let run c = derive_tracks DeriveTest.e_dyn_rounded $
            make_tracks (4, "--") (6, c)
    equal (run "#-") ([[(0, 1)], [(0, 1)], [(0, 1)]], [])
    equal (run "#-[-]> -")
        ([[(0, 1)], [(4, 1), (6, 1), (7, 0.5), (8, 0)], [(0, 1)]], [])

    -- 4 5 6 7 8 9 10
    -- ------++++++
    -- Dyn is as long as the call it modifies.
    equal (run "#-[-]<")
        ([[(0, 1)], [(4, 0), (7, 0), (8, 0.33), (9, 0.67)], [(0, 1)]], [])
    equal (run "##[--]<")
        ([ [(0, 1)]
         , [(4, 0), (5, 0.17), (6, 0.33), (7, 0.5), (8, 0.67), (9, 0.83)]
         , [(0, 1)]], [])
    -- Fast and biased to the left.
    equal (run "##[--]<^")
        ([ [(0, 1)]
         , [(4, 0), (5, 0.51), (6, 0.73), (7, 0.87), (8, 0.95), (9, 0.99)]
         , [(0, 1)]], [])
    -- Continue from the previous dyn.
    equal (run "#[-]<.5 [-]>")
        ([ [(0, 1)]
         , [(4, 0), (5, 0.17), (6, 0.33), (7, 0.5), (8, 0.33), (9, 0.17)]
         , [(0, 1)]], [])

test_dyn_prev = do
    let run call1 = derive_tracks DeriveTest.e_dyn_rounded . make_tracks call1
    equal (run (2, "#[-]>.5") (2, "#[-]=1"))
        ([[(0, 1), (1, 0.75)], [(2, 0.75), (3, 0.88)], [(0, 1)]], [])

test_sequence_interleave = do
    let run c = derive_tracks extract $ make_tracks (4, "--") (6, c)
        extract = DeriveTest.e_nns_rounded
    equal (run "##0") ([[(0, 60)], [(4, 62)], [(10, 64)]], [])

    -- pprint (run "# P1c #-c-")
    -- pprint (run "# P2 0 -2")

make_tracks :: (ScoreTime, String) -> (ScoreTime, String) -> [UiTest.TrackSpec]
make_tracks (dur1, call1) (dur2, call2) =
    [ (">", [(0, dur1, ""), (dur1, dur2, ""), (dur1 + dur2, 2, "")])
    , ("*", [(0, 0, "4c"), (dur1, 0, "4d"), (dur1 + dur2, 0, "4e")])
    , ("* interleave | dyn-transition=1 | transition=1",
        [(0, dur1, call1), (dur1, dur2, call2)])
    , ("dyn", [(0, 0, "1")])
    ]

derive_tracks :: (Score.Event -> a) -> [UiTest.TrackSpec] -> ([a], [String])
derive_tracks extract = DeriveTest.extract extract
    . DeriveTest.derive_tracks "import india.gamakam3"
