-- Copyright 2020 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE RecordWildCards #-}
module Solkattu.Score.MridangamTirmanam where
import           Prelude hiding ((.), repeat)

import qualified Solkattu.Tala as Tala

import           Solkattu.Dsl.Mridangam


tir_short_adi :: Korvai
tir_short_adi = tirmanam $ korvaiS adi
    [ __D 1 . tri_ (p&u.__.k.k.o) (on.d.__.on.d.__) . p&u
    , __D 4 . su (tri_ (u.__4) (k.n.o.od.__.od.__3)) . u
    , __D 4 . __ . tri (od.__ . su2 (p.k.n.p).k.__) . od
    , __D 7 . tri_ (od.__.k) (su (ktkt.p.kt.p.hv k.t.kt.p.k).od.od.k) . od
    ]

tir_long_adi :: Korvai
tir_long_adi = tirmanam $ korvaiS adi
    -- 1:08:07
    [ let p8 = group (mconcatMap (.__) [kt, k.n, k.o, o.k])
        in __D 4.5 . p8 . (od.__.k.k.o) . p8 . (od.__.on.o'&n.k)
            . (group (su (stride 3 (k.t.k.n.k.o.o.k))))
        . od
    ]

-- sam to sam
tir_sam_adi_kirkalam :: Korvai
tir_sam_adi_kirkalam = tirmanam $ korvaiS adi
    [ tri_ "D__k" "kookokk_"
    ]

tir_long_rupaka :: Korvai
tir_long_rupaka = tirmanam $ korvaiS Tala.rupaka_fast
    -- 20:06
    [ tri_ (od.__.k) (su (ktkt.p.kt.p.hv k.t.kt.p.k).od.od.k)
    ]

-- https://www.youtube.com/watch?v=lSVqfzQBkMs
tir_mysore_vidiraj22 :: Korvai
tir_mysore_vidiraj22 = tirmanam $ korvaiS adi
    -- 15
    [ __D 4 . r3 (__ . tri_ "D_o" "NNk")
    , __D 4 . __ . tri_ (su "D_ktpk") "NNk"
    , __D 4 . __ . su (tri_ (o&v.__.ktok) (r2 (o&v.__.o)))
    , __D 4 . __ . tri_ "v_o" (su "okokk_")
    -- 16
    , __D 4 . tri_ "D_" (su "t_o_ktok")
    , __D 4 . tri_ "D_" (su "k_oD_N_k")
    -- 24
    , __D 2 . tri_ "D_o" "NNkNNk"
    , __D 2 . tri_ (su "D_ktok") (su "N_N_pkN_N_pk")
    , __D 2 . tri_ (su "D_ktok") (su "ookD_kD_D_k_") -- (su "ookD_kookD_k")
    , __D 2 . tri_ (su "D_ktok") (su "npkD_kD_D_k_") -- (su "npknpknpknpk")
    , __D 2 . tri_ (su "D_ktok") (su "NkoD_kD_D_k_")
    , __D 2 . tri_ (o&v.__.o) (su "ktkto_ktkto_")

    , __D 2 . tri_ (su "D_pkno") "DDkDDk"
    -- 32
    , let kook = su "kook" in
        kook."D_kD_" . kook."D_kD_k_D_" . kook."D_kD_k_D_k__"

    ]

tir_itunes :: Korvai
tir_itunes = tirmanam $ source "Mannargudi Easwaran" $ korvaiS adi
    [ __D 7 . r2 (tri_ "D__" (su "kook"))
        -- TODO more elegant way to put in the extra k?
        . su "kook" . "D__" . su "kook" . "D_k" . su "kook"
    ]

tir_sivamani :: Korvai
tir_sivamani = tirmanam $ korvaiS adi
    [ __D 2 . tri_ (su "v_pkno") "DD_NN_" -- another 63636
    ]
