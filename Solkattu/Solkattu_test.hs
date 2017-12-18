-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Solkattu.Solkattu_test where
import qualified Data.Text as Text

import Util.Test
import qualified Solkattu.Dsl as Dsl
import Solkattu.Dsl (__)
import Solkattu.DslSollu (ta, di, ki, thom)
import qualified Solkattu.Sequence as Sequence
import qualified Solkattu.Solkattu as Solkattu

import Global



test_matrasOf = do
    let f = Solkattu.matrasOf
        t s n = Sequence.Tempo s n 1
    equal (f (t 0 4) ta) 1
    equal (f (t 0 6) ta) 1
    equal (f (t 1 4) ta) (1/2)
    equal (f (t 1 6) ta) (1/2)

test_cancelKarvai = do
    let f = Text.unwords . map pretty . Sequence.flattenedNotes
            . Solkattu.cancelKarvai
            . Sequence.flatten
    equal (f (ta <> thom)) "ta thom"
    equal (f (ta <> Dsl.karvai thom)) "ta"
    equal (f (ta <> Dsl.karvai thom <> __)) "ta thom"
    equal (f (ta <> Dsl.karvai thom <> di)) "ta di"

test_vary = do
    let f notes = map (Text.unwords . map pretty) $
            Solkattu.vary
                (Solkattu.variations [Solkattu.standard, Solkattu.ascending])
                notes
    equal (f (ta <> di)) ["ta di"]
    equal (f (ta <> Dsl.p6 <> di <> Dsl.p6)) ["ta p6 di p6"]
    equal (f (ta <> Dsl.p6 <> di <> Dsl.p6 <> Dsl.p6)) ["ta p5 di p6 p7"]
    equal (f (Dsl.tri_ ta Dsl.p6 <> di <> Dsl.tri_ ki Dsl.p7))
        [ "p5 ta p6 mid^ta p7 di p6 ki p7 mid^ki p8"
        , "p5 ta p6 mid^ta p7 di p5 ki p7 mid^ki p9"
        ]

-- * utils

test_applyModifications = do
    let f = Solkattu.applyModifications (+)
    equal (f [] [1]) [1]
    let mods = [(0, 10), (2, 20)]
    equal (f mods [1]) [11]
    equal (f mods [1..2]) [11, 2]
    equal (f mods [1..3]) [11, 2, 23]
    equal (f mods [1..4]) [11, 2, 23, 4]

test_permuteFst = do
    let f = Solkattu.permuteFst (\x -> [x, x+1])
    equal (f ([] :: [(Int, Char)])) []
    equal (f [(0, 'a')]) [[(0, 'a')], [(1, 'a')]]
    equal (f [(0, 'a'), (10, 'b')])
        [ [(0, 'a'), (10, 'b')]
        , [(0, 'a'), (11, 'b')]
        , [(1, 'a'), (10, 'b')]
        , [(1, 'a'), (11, 'b')]
        ]
