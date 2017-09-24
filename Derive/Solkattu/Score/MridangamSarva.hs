-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Sarvalaghu.
module Derive.Solkattu.Score.MridangamSarva where
import Prelude hiding ((.), repeat)

import Derive.Solkattu.MridangamGlobal
import qualified Derive.Solkattu.Tala as Tala
import Global


-- * kirkalam

-- TODO these don't need to be a full avartanam, only a binary factor of it

kir1 :: Korvai
kir1 = sarvalaghu $ sudhindra $ korvai adi $
    [ repeat 4 $ repeat 2 (n.l.d.d) & (o.__.o.o.__.o.o.__) -- takadimi takajonu
    ]

kir2 :: Korvai
kir2 = sarvalaghu $ sudhindra $ korvai adi $
    repeat 2 sarva : map pattern prefixes
    where
    pattern (prefix, end) =
        (repeat 2 $ prefix `replaceStart` sarva) `replaceEnd` end
    -- takatadin or nakanadin
    sarva = repeat 2 (n.k.n.d) & (o.__.o.o.__.__.o.o) . (on.k.n.d) . (n.k.n.d)
    prefixes = map (su *** su)
        [ (takadinna, takadinna . repeat 3 (t.o.o.k))
        , (o.o.n.n . o.k, repeat 4 (o.o.n.n))
        , (o.o.k.t . p.k, repeat 4 (o.o.k.t))
        , (n.n.p.k, repeat 4 (n.n.p.k))
        , (p.u.__.k, repeat 4 (p.u.__.k))
        , (dinna_kitataka, repeat 2 dinna_kitataka . o.k.o.k . dinna_kitataka)
        , let nknk = o&j.y.o&j.y
            in (nknk, nknk.d.__.nknk.d.__.nknk)
        ]
    dinna_kitataka = o.n . su (k.t.o.k)

kir3 :: Korvai
kir3 = sarvalaghu $ sudhindra $ korvai1 adi $ repeat 2 $
    repeat 2 (n.d.__.n) & (o.o.__.o.__.o.__.o)
    . repeat 2 (n.d.__.n) & (o.__n 8)
    -- can end with faran: oonnpktk naka

kir4 :: Korvai
kir4 = sarvalaghu $ sudhindra $ korvai1 adi $
      on.__.on.__.on.od.__5.on.__.on.od.__2.o
    . on.k.on.k.on.od.__5.on.k.on.od.__2.o

kir5 :: Korvai
kir5 = sarvalaghu $ sudhindra $ korvai1 adi $
      nknd & (o.__.o.o.__.o.o.__) . nknd & (__.__.o.o.__.o.o.__)
    . nknd & (o.__n 8)            . nknd
    where
    nknd = n.k.n.d.__.n.d.__

-- * melkalam

mel1 :: Korvai
mel1 = sarvalaghu $ sudhindra $ korvai1 adi $
    repeat 4 $ on.od.on. su (pk.n.o).od.on . su pk
    -- ta din ta din takadin ta din

mel2 :: Korvai
mel2 = sarvalaghu $ sudhindra $ korvai1 adi $ su $
    repeat 2 $ repeat 3 (yjyj.d.__.lt p.k) . (t.k.o.o.k.t.o.k)
    where yjyj = y.j.y.j

-- reduce with kir2 and kir5

dinna_kitataka :: Korvai
dinna_kitataka = exercise $ sudhindra $ korvai adi $ map (sarvaSam adi) patterns
    where
    patterns = map su
        [ repeat 4 dinna
        , repeat 2 (od.__.dinna).dinna
        , repeat 2 (o.k.dinna) . dinna
        , repeat 2 (o.t.k.n.kttk) . dinna
        , tri_ (o.k) dinna
        ]
    kttk = su (k.t.o.k)
    dinna = o.n.kttk

farans :: Korvai
farans = sudhindra $ faran $ korvai adi $
    [ long . long
        . repeat 4 (o.o.k.t) . long
        . repeat 2 (o.o.k.t.p.k) . o.o.k.t . long
        . repeat 2 (o.o.k.t.__.k) . o.o.k.t . long
    ]
    where
    long = o.o.k.t.p.k.t.k.nakatiku


-- * ganesh

kir6 :: Korvai
kir6 = sarvalaghu $ date 2017 8 29 $ ganesh $ korvai adi $
    [ both . o1 rh
        -- TODO second half has D after prefix
        -- I could maybe do that by having transparent strokes, so I could
        -- add the trailing thom.  But it's seems over general for this
        -- specific case, e.g. I don't see how solkattu would support it.
    , prefix `replaceStart` both . prefix `replaceStart` rh
        . repeat 2 (prefix .od.l.od.on.l) . prefix `replaceStart` rh
        . prefix `replaceStart` both . (prefix . prefix) `replaceStart` rh
        . repeat 2 prefix `replaceStart` both
            . repeat 2 prefix `replaceStart` rh
        . (repeat 2 prefix . su (od.n.p.k) . prefix) `replaceStart` both
            . prefix `replaceStart` rh
        . repeat 2 prefix . repeat 5 (su (od.n.p.k)) . prefix `replaceStart` rh
    ]
    where
    rh = d.__.n.d. l.d.n. l.d.l .n.d. l.d.n.l
    lh = thom_lh rh
    both = rh & lh
    prefix = su $ od.__.od.n.p.k -- din dinataka

kir_misra_1 :: Korvai
kir_misra_1 = sarvalaghu $ date 2017 8 29 $ ganesh $ korvai Tala.misra_chapu
    [ rh & lh . o1 rh
    ]
    where
    rh = sd $ n.l.n.n.d.l.n.l.d.l.n.n.d.l
    lh = thom_lh rh