-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- automatically generated by extract_korvais
-- | Collect korvais into one database.
-- This is automatically generated, but checked in for convenience.
-- Don't edit it directly.  Any modifications to the the source
-- directory should cause it to be regenerated.
module Derive.Solkattu.All where
import qualified Derive.Solkattu.Korvai as Korvai
import Derive.Solkattu.Metadata
import qualified Derive.Solkattu.Score.Mridangam2013
import qualified Derive.Solkattu.Score.Solkattu2013
import qualified Derive.Solkattu.Score.Solkattu2016
import qualified Derive.Solkattu.Score.Solkattu2017


korvais :: [Korvai.Korvai]
korvais =
    [ variable_name "dinnagina_sequence" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 16 Derive.Solkattu.Score.Mridangam2013.dinnagina_sequence
    , variable_name "c_13_11_19" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 87 Derive.Solkattu.Score.Mridangam2013.c_13_11_19
    , variable_name "c_16_11_14" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 102 Derive.Solkattu.Score.Mridangam2013.c_16_11_14
    , variable_name "ganesh_17_02_13" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 108 Derive.Solkattu.Score.Mridangam2013.ganesh_17_02_13
    , variable_name "din_nadin" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 122 Derive.Solkattu.Score.Mridangam2013.din_nadin
    , variable_name "nadin_ka" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 129 Derive.Solkattu.Score.Mridangam2013.nadin_ka
    , variable_name "nadindin" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 134 Derive.Solkattu.Score.Mridangam2013.nadindin
    , variable_name "nadindin_negative" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 152 Derive.Solkattu.Score.Mridangam2013.nadindin_negative
    , variable_name "namita_dimita" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 165 Derive.Solkattu.Score.Mridangam2013.namita_dimita
    , variable_name "janahan_exercise" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 182 Derive.Solkattu.Score.Mridangam2013.janahan_exercise
    , variable_name "nakanadin" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 186 Derive.Solkattu.Score.Mridangam2013.nakanadin
    , variable_name "p16_12_06_sriram2" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 192 Derive.Solkattu.Score.Mridangam2013.p16_12_06_sriram2
    , variable_name "p16_12_06_janahan1" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 200 Derive.Solkattu.Score.Mridangam2013.p16_12_06_janahan1
    , variable_name "p16_12_06_janahan2" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 207 Derive.Solkattu.Score.Mridangam2013.p16_12_06_janahan2
    , variable_name "farans" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 221 Derive.Solkattu.Score.Mridangam2013.farans
    , variable_name "eddupu6" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 267 Derive.Solkattu.Score.Mridangam2013.eddupu6
    , variable_name "eddupu10" $
        module_ "Derive.Solkattu.Score.Mridangam2013" $
        line_number 278 Derive.Solkattu.Score.Mridangam2013.eddupu10
    , variable_name "c_13_07_23" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 21 Derive.Solkattu.Score.Solkattu2013.c_13_07_23
    , variable_name "c_13_08_14" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 28 Derive.Solkattu.Score.Solkattu2013.c_13_08_14
    , variable_name "c_yt1" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 67 Derive.Solkattu.Score.Solkattu2013.c_yt1
    , variable_name "c_13_10_29" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 90 Derive.Solkattu.Score.Solkattu2013.c_13_10_29
    , variable_name "c_13_11_05" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 105 Derive.Solkattu.Score.Solkattu2013.c_13_11_05
    , variable_name "c_13_11_12" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 115 Derive.Solkattu.Score.Solkattu2013.c_13_11_12
    , variable_name "c_nnnd" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 134 Derive.Solkattu.Score.Solkattu2013.c_nnnd
    , variable_name "k1_1" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 153 Derive.Solkattu.Score.Solkattu2013.k1_1
    , variable_name "k1_2" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 170 Derive.Solkattu.Score.Solkattu2013.k1_2
    , variable_name "k1_3" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 183 Derive.Solkattu.Score.Solkattu2013.k1_3
    , variable_name "k3s" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 217 Derive.Solkattu.Score.Solkattu2013.k3s
    , variable_name "t1s" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 262 Derive.Solkattu.Score.Solkattu2013.t1s
    , variable_name "t2s" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 282 Derive.Solkattu.Score.Solkattu2013.t2s
    , variable_name "t3s" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 314 Derive.Solkattu.Score.Solkattu2013.t3s
    , variable_name "t4s" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 351 Derive.Solkattu.Score.Solkattu2013.t4s
    , variable_name "t4s2" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 376 Derive.Solkattu.Score.Solkattu2013.t4s2
    , variable_name "t4s3" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 401 Derive.Solkattu.Score.Solkattu2013.t4s3
    , variable_name "t5s" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 425 Derive.Solkattu.Score.Solkattu2013.t5s
    , variable_name "koraippu_misra" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 481 Derive.Solkattu.Score.Solkattu2013.koraippu_misra
    , variable_name "tir_18" $
        module_ "Derive.Solkattu.Score.Solkattu2013" $
        line_number 521 Derive.Solkattu.Score.Solkattu2013.tir_18
    , variable_name "c_16_09_28" $
        module_ "Derive.Solkattu.Score.Solkattu2016" $
        line_number 13 Derive.Solkattu.Score.Solkattu2016.c_16_09_28
    , variable_name "c_16_12_06_sriram1" $
        module_ "Derive.Solkattu.Score.Solkattu2016" $
        line_number 31 Derive.Solkattu.Score.Solkattu2016.c_16_12_06_sriram1
    , variable_name "koraippu_janahan" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 18 Derive.Solkattu.Score.Solkattu2017.koraippu_janahan
    , variable_name "e_spacing" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 77 Derive.Solkattu.Score.Solkattu2017.e_spacing
    , variable_name "c_17_02_06" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 92 Derive.Solkattu.Score.Solkattu2017.c_17_02_06
    , variable_name "c_17_03_20" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 102 Derive.Solkattu.Score.Solkattu2017.c_17_03_20
    , variable_name "c_17_04_04" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 138 Derive.Solkattu.Score.Solkattu2017.c_17_04_04
    , variable_name "c_17_04_23" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 164 Derive.Solkattu.Score.Solkattu2017.c_17_04_23
    , variable_name "c_17_05_10" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 191 Derive.Solkattu.Score.Solkattu2017.c_17_05_10
    , variable_name "m_17_05_11" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 227 Derive.Solkattu.Score.Solkattu2017.m_17_05_11
    , variable_name "e_17_05_19" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 244 Derive.Solkattu.Score.Solkattu2017.e_17_05_19
    , variable_name "c_17_05_19_janahan" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 250 Derive.Solkattu.Score.Solkattu2017.c_17_05_19_janahan
    , variable_name "janahan_17_06_02" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 273 Derive.Solkattu.Score.Solkattu2017.janahan_17_06_02
    , variable_name "c_17_06_15" $
        module_ "Derive.Solkattu.Score.Solkattu2017" $
        line_number 286 Derive.Solkattu.Score.Solkattu2017.c_17_06_15
    ]
