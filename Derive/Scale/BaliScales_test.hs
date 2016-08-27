-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Derive.Scale.BaliScales_test where
import Util.Test
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Scale.BaliScales as BaliScales
import qualified Derive.Score as Score

import qualified Perform.Pitch as Pitch


test_ombak = do
    let run trans pitch = DeriveTest.extract Score.initial_nn $
            DeriveTest.derive_tracks ""
                [("> " ++ trans, [(0, 1, "")]), ("*wayang", [(0, 0, pitch)])]
    equal (run "" "4e") ([Just 67.57], [])
    equal (run "| tuning = umbang" "4e") ([Just 67.57], [])
    equal (run "| tuning = isep" "4e") ([Just 67.26], [])

    equalf 0.01 (run "| %ombak = 5" "4e") ([Just 67.306], [])
    equalf 0.01 (run "| %ombak = 10" "4e") ([Just 67.198], [])

test_extend_scale = do
    let f = BaliScales.extend_scale 2
        p = Pitch.pitch
    equal (f (p 1 0) (p 2 0) (p 1 0) [12, 13]) [12, 13, 24]
    equal (f (p 1 0) (p 2 1) (p 1 0) [12, 13]) [12, 13, 24, 25]
    equal (f (p 0 0) (p 1 1) (p 1 0) [12, 13]) [0, 1, 12, 13]
    equal (f (p 0 0) (p 3 0) (p 1 0) [12, 13]) [0, 1, 12, 13, 24, 25, 36]
