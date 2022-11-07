-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- automatically generated by extract_korvais
-- | Collect korvais into one database.
-- This is automatically generated, but checked in for convenience.
-- Don't edit it directly.  Any modifications to the the source
-- directory should cause it to be regenerated.
module Solkattu.All where
import qualified Solkattu.Korvai as Korvai
import           Solkattu.Korvai (Score(Single), setLocation)
import qualified Solkattu.Score.Kendang2020
import qualified Solkattu.Score.Mridangam2013
import qualified Solkattu.Score.Mridangam2015
import qualified Solkattu.Score.Mridangam2016
import qualified Solkattu.Score.Mridangam2017
import qualified Solkattu.Score.Mridangam2018
import qualified Solkattu.Score.Mridangam2019
import qualified Solkattu.Score.Mridangam2020
import qualified Solkattu.Score.Mridangam2021
import qualified Solkattu.Score.Mridangam2022
import qualified Solkattu.Score.MridangamSarva
import qualified Solkattu.Score.MridangamTirmanam
import qualified Solkattu.Score.Solkattu2013
import qualified Solkattu.Score.Solkattu2014
import qualified Solkattu.Score.Solkattu2016
import qualified Solkattu.Score.Solkattu2017
import qualified Solkattu.Score.Solkattu2018
import qualified Solkattu.Score.Solkattu2019
import qualified Solkattu.Score.Solkattu2020
import qualified Solkattu.Score.Solkattu2021
import qualified Solkattu.Score.SolkattuMohra


scores :: [Korvai.Score]
scores = map Korvai.inferMetadataS
    [ setLocation ("Solkattu.Score.Kendang2020",7,"farans") $ Single Solkattu.Score.Kendang2020.farans
    , setLocation ("Solkattu.Score.Mridangam2013",17,"dinnagina_sequence_old") $ Single Solkattu.Score.Mridangam2013.dinnagina_sequence_old
    , setLocation ("Solkattu.Score.Mridangam2013",87,"dinnagina_sequences") $ Single Solkattu.Score.Mridangam2013.dinnagina_sequences
    , setLocation ("Solkattu.Score.Mridangam2013",172,"din_nadin") $ Single Solkattu.Score.Mridangam2013.din_nadin
    , setLocation ("Solkattu.Score.Mridangam2013",179,"nadin_ka") $ Single Solkattu.Score.Mridangam2013.nadin_ka
    , setLocation ("Solkattu.Score.Mridangam2013",184,"nadindin") $ Single Solkattu.Score.Mridangam2013.nadindin
    , setLocation ("Solkattu.Score.Mridangam2013",204,"nadindin_negative") $ Single Solkattu.Score.Mridangam2013.nadindin_negative
    , setLocation ("Solkattu.Score.Mridangam2013",217,"namita_dimita") $ Single Solkattu.Score.Mridangam2013.namita_dimita
    , setLocation ("Solkattu.Score.Mridangam2013",224,"namita_dimita_seq") $ Single Solkattu.Score.Mridangam2013.namita_dimita_seq
    , setLocation ("Solkattu.Score.Mridangam2013",256,"janahan_exercise") $ Single Solkattu.Score.Mridangam2013.janahan_exercise
    , setLocation ("Solkattu.Score.Mridangam2013",260,"nakanadin") $ Single Solkattu.Score.Mridangam2013.nakanadin
    , setLocation ("Solkattu.Score.Mridangam2013",264,"farans") $ Single Solkattu.Score.Mridangam2013.farans
    , setLocation ("Solkattu.Score.Mridangam2013",308,"e_ktkt") $ Single Solkattu.Score.Mridangam2013.e_ktkt
    , setLocation ("Solkattu.Score.Mridangam2013",322,"eddupu6") $ Single Solkattu.Score.Mridangam2013.eddupu6
    , setLocation ("Solkattu.Score.Mridangam2013",333,"eddupu10") $ Single Solkattu.Score.Mridangam2013.eddupu10
    , setLocation ("Solkattu.Score.Mridangam2015",13,"c_1") $ Single Solkattu.Score.Mridangam2015.c_1
    , setLocation ("Solkattu.Score.Mridangam2015",23,"c_2") $ Single Solkattu.Score.Mridangam2015.c_2
    , setLocation ("Solkattu.Score.Mridangam2015",33,"c_3") $ Single Solkattu.Score.Mridangam2015.c_3
    , setLocation ("Solkattu.Score.Mridangam2015",41,"akash1") $ Single Solkattu.Score.Mridangam2015.akash1
    , setLocation ("Solkattu.Score.Mridangam2016",12,"t_16_11_14") $ Single Solkattu.Score.Mridangam2016.t_16_11_14
    , setLocation ("Solkattu.Score.Mridangam2017",11,"t_17_02_13") $ Single Solkattu.Score.Mridangam2017.t_17_02_13
    , setLocation ("Solkattu.Score.Mridangam2017",24,"c_17_07_10") $ Single Solkattu.Score.Mridangam2017.c_17_07_10
    , setLocation ("Solkattu.Score.Mridangam2017",28,"e_1") $ Single Solkattu.Score.Mridangam2017.e_1
    , setLocation ("Solkattu.Score.Mridangam2017",37,"e_2") $ Single Solkattu.Score.Mridangam2017.e_2
    , setLocation ("Solkattu.Score.Mridangam2018",13,"e_323_1") $ Single Solkattu.Score.Mridangam2018.e_323_1
    , setLocation ("Solkattu.Score.Mridangam2018",27,"e_323_2") $ Single Solkattu.Score.Mridangam2018.e_323_2
    , setLocation ("Solkattu.Score.Mridangam2018",37,"e_18_03_19") $ Single Solkattu.Score.Mridangam2018.e_18_03_19
    , setLocation ("Solkattu.Score.Mridangam2018",43,"e_18_03_28") $ Single Solkattu.Score.Mridangam2018.e_18_03_28
    , setLocation ("Solkattu.Score.Mridangam2018",48,"e_18_05_25") $ Single Solkattu.Score.Mridangam2018.e_18_05_25
    , setLocation ("Solkattu.Score.Mridangam2018",55,"tir_18_05_25") $ Single Solkattu.Score.Mridangam2018.tir_18_05_25
    , setLocation ("Solkattu.Score.Mridangam2018",60,"tir_18_06_15") $ Single Solkattu.Score.Mridangam2018.tir_18_06_15
    , setLocation ("Solkattu.Score.Mridangam2018",92,"e_18_06_22") $ Single Solkattu.Score.Mridangam2018.e_18_06_22
    , setLocation ("Solkattu.Score.Mridangam2018",147,"c_18_07_02_sarva") $ Single Solkattu.Score.Mridangam2018.c_18_07_02_sarva
    , setLocation ("Solkattu.Score.Mridangam2018",156,"e_misra_tisram") $ Single Solkattu.Score.Mridangam2018.e_misra_tisram
    , setLocation ("Solkattu.Score.Mridangam2018",176,"e_18_11_12") $ Single Solkattu.Score.Mridangam2018.e_18_11_12
    , setLocation ("Solkattu.Score.Mridangam2018",197,"e_18_11_19") $ Single Solkattu.Score.Mridangam2018.e_18_11_19
    , setLocation ("Solkattu.Score.Mridangam2018",209,"e_18_12_08") $ Single Solkattu.Score.Mridangam2018.e_18_12_08
    , setLocation ("Solkattu.Score.Mridangam2018",218,"e_18_12_08_b") $ Single Solkattu.Score.Mridangam2018.e_18_12_08_b
    , setLocation ("Solkattu.Score.Mridangam2018",225,"p5_variations") $ Single Solkattu.Score.Mridangam2018.p5_variations
    , setLocation ("Solkattu.Score.Mridangam2018",239,"exercises_18_12_19") $ Solkattu.Score.Mridangam2018.exercises_18_12_19
    , setLocation ("Solkattu.Score.Mridangam2018",248,"e_npkt") $ Single Solkattu.Score.Mridangam2018.e_npkt
    , setLocation ("Solkattu.Score.Mridangam2019",10,"e_naka") $ Single Solkattu.Score.Mridangam2019.e_naka
    , setLocation ("Solkattu.Score.Mridangam2019",14,"e_19_03_20") $ Single Solkattu.Score.Mridangam2019.e_19_03_20
    , setLocation ("Solkattu.Score.Mridangam2019",33,"e_19_04_01") $ Single Solkattu.Score.Mridangam2019.e_19_04_01
    , setLocation ("Solkattu.Score.Mridangam2019",68,"e_19_04_15") $ Single Solkattu.Score.Mridangam2019.e_19_04_15
    , setLocation ("Solkattu.Score.Mridangam2019",82,"e_19_05_06_a") $ Single Solkattu.Score.Mridangam2019.e_19_05_06_a
    , setLocation ("Solkattu.Score.Mridangam2019",95,"e_19_05_06_b") $ Single Solkattu.Score.Mridangam2019.e_19_05_06_b
    , setLocation ("Solkattu.Score.Mridangam2019",126,"e_19_05_20a") $ Single Solkattu.Score.Mridangam2019.e_19_05_20a
    , setLocation ("Solkattu.Score.Mridangam2019",129,"e_19_05_20b") $ Single Solkattu.Score.Mridangam2019.e_19_05_20b
    , setLocation ("Solkattu.Score.Mridangam2019",132,"e_19_05_20b2") $ Single Solkattu.Score.Mridangam2019.e_19_05_20b2
    , setLocation ("Solkattu.Score.Mridangam2019",153,"e_19_05_20c") $ Single Solkattu.Score.Mridangam2019.e_19_05_20c
    , setLocation ("Solkattu.Score.Mridangam2019",180,"e_5x4_4x3") $ Single Solkattu.Score.Mridangam2019.e_5x4_4x3
    , setLocation ("Solkattu.Score.Mridangam2019",203,"e_19_06_10a") $ Single Solkattu.Score.Mridangam2019.e_19_06_10a
    , setLocation ("Solkattu.Score.Mridangam2019",219,"e_19_06_10b") $ Single Solkattu.Score.Mridangam2019.e_19_06_10b
    , setLocation ("Solkattu.Score.Mridangam2019",234,"e_19_06_17") $ Single Solkattu.Score.Mridangam2019.e_19_06_17
    , setLocation ("Solkattu.Score.Mridangam2019",249,"c_19_06_24_a") $ Single Solkattu.Score.Mridangam2019.c_19_06_24_a
    , setLocation ("Solkattu.Score.Mridangam2019",286,"c_19_06_24_b") $ Single Solkattu.Score.Mridangam2019.c_19_06_24_b
    , setLocation ("Solkattu.Score.Mridangam2019",311,"e_19_06_24") $ Single Solkattu.Score.Mridangam2019.e_19_06_24
    , setLocation ("Solkattu.Score.Mridangam2019",327,"e_19_08_05_gumiki") $ Single Solkattu.Score.Mridangam2019.e_19_08_05_gumiki
    , setLocation ("Solkattu.Score.Mridangam2019",349,"e_19_08_19") $ Single Solkattu.Score.Mridangam2019.e_19_08_19
    , setLocation ("Solkattu.Score.Mridangam2019",358,"c_19_08_26") $ Single Solkattu.Score.Mridangam2019.c_19_08_26
    , setLocation ("Solkattu.Score.Mridangam2019",382,"e_19_09_23") $ Single Solkattu.Score.Mridangam2019.e_19_09_23
    , setLocation ("Solkattu.Score.Mridangam2019",390,"c_19_09_23") $ Single Solkattu.Score.Mridangam2019.c_19_09_23
    , setLocation ("Solkattu.Score.Mridangam2019",402,"e_19_09_30_gumiki") $ Single Solkattu.Score.Mridangam2019.e_19_09_30_gumiki
    , setLocation ("Solkattu.Score.Mridangam2019",412,"e_19_11_11_namita_dimita") $ Single Solkattu.Score.Mridangam2019.e_19_11_11_namita_dimita
    , setLocation ("Solkattu.Score.Mridangam2019",429,"e_19_11_11_sarva") $ Single Solkattu.Score.Mridangam2019.e_19_11_11_sarva
    , setLocation ("Solkattu.Score.Mridangam2020",13,"e_20_02_24") $ Single Solkattu.Score.Mridangam2020.e_20_02_24
    , setLocation ("Solkattu.Score.Mridangam2020",17,"e_20_03_27") $ Single Solkattu.Score.Mridangam2020.e_20_03_27
    , setLocation ("Solkattu.Score.Mridangam2020",29,"e_20_05_01") $ Single Solkattu.Score.Mridangam2020.e_20_05_01
    , setLocation ("Solkattu.Score.Mridangam2020",44,"sarva_tani") $ Solkattu.Score.Mridangam2020.sarva_tani
    , setLocation ("Solkattu.Score.Mridangam2020",62,"sarva_20_01_27") $ Single Solkattu.Score.Mridangam2020.sarva_20_01_27
    , setLocation ("Solkattu.Score.Mridangam2020",99,"sarva_20_02_10") $ Single Solkattu.Score.Mridangam2020.sarva_20_02_10
    , setLocation ("Solkattu.Score.Mridangam2020",129,"sarva_20_02_27") $ Single Solkattu.Score.Mridangam2020.sarva_20_02_27
    , setLocation ("Solkattu.Score.Mridangam2020",184,"sarva_20_05_08") $ Single Solkattu.Score.Mridangam2020.sarva_20_05_08
    , setLocation ("Solkattu.Score.Mridangam2020",219,"sarva_20_05_29") $ Single Solkattu.Score.Mridangam2020.sarva_20_05_29
    , setLocation ("Solkattu.Score.Mridangam2020",235,"sarva_20_06_05") $ Single Solkattu.Score.Mridangam2020.sarva_20_06_05
    , setLocation ("Solkattu.Score.Mridangam2020",252,"sarva_20_06_12") $ Single Solkattu.Score.Mridangam2020.sarva_20_06_12
    , setLocation ("Solkattu.Score.Mridangam2020",267,"sarva_20_06_12_reduction") $ Single Solkattu.Score.Mridangam2020.sarva_20_06_12_reduction
    , setLocation ("Solkattu.Score.Mridangam2020",274,"sarva_20_06_19_endings") $ Single Solkattu.Score.Mridangam2020.sarva_20_06_19_endings
    , setLocation ("Solkattu.Score.Mridangam2020",286,"sarva_20_06_19") $ Single Solkattu.Score.Mridangam2020.sarva_20_06_19
    , setLocation ("Solkattu.Score.Mridangam2020",301,"sarva_20_06_19_reduce5") $ Single Solkattu.Score.Mridangam2020.sarva_20_06_19_reduce5
    , setLocation ("Solkattu.Score.Mridangam2020",315,"e_20_07_03") $ Single Solkattu.Score.Mridangam2020.e_20_07_03
    , setLocation ("Solkattu.Score.Mridangam2020",328,"e_20_07_17") $ Single Solkattu.Score.Mridangam2020.e_20_07_17
    , setLocation ("Solkattu.Score.Mridangam2020",341,"thani_exercise") $ Single Solkattu.Score.Mridangam2020.thani_exercise
    , setLocation ("Solkattu.Score.Mridangam2020",362,"e_20_11_01_npk") $ Single Solkattu.Score.Mridangam2020.e_20_11_01_npk
    , setLocation ("Solkattu.Score.Mridangam2020",378,"sketch_20_11_08") $ Single Solkattu.Score.Mridangam2020.sketch_20_11_08
    , setLocation ("Solkattu.Score.Mridangam2020",387,"e_20_12_06") $ Single Solkattu.Score.Mridangam2020.e_20_12_06
    , setLocation ("Solkattu.Score.Mridangam2021",15,"e_kanda") $ Single Solkattu.Score.Mridangam2021.e_kanda
    , setLocation ("Solkattu.Score.Mridangam2021",60,"e_21_02_07") $ Single Solkattu.Score.Mridangam2021.e_21_02_07
    , setLocation ("Solkattu.Score.Mridangam2021",65,"e_nd_d") $ Single Solkattu.Score.Mridangam2021.e_nd_d
    , setLocation ("Solkattu.Score.Mridangam2021",83,"e_fours") $ Single Solkattu.Score.Mridangam2021.e_fours
    , setLocation ("Solkattu.Score.Mridangam2021",103,"e_tisram") $ Single Solkattu.Score.Mridangam2021.e_tisram
    , setLocation ("Solkattu.Score.Mridangam2021",115,"s_tisram_sarva") $ Single Solkattu.Score.Mridangam2021.s_tisram_sarva
    , setLocation ("Solkattu.Score.Mridangam2021",119,"e_tisram_tdgno") $ Single Solkattu.Score.Mridangam2021.e_tisram_tdgno
    , setLocation ("Solkattu.Score.Mridangam2021",126,"e_5s") $ Single Solkattu.Score.Mridangam2021.e_5s
    , setLocation ("Solkattu.Score.Mridangam2021",131,"e_gumiki") $ Single Solkattu.Score.Mridangam2021.e_gumiki
    , setLocation ("Solkattu.Score.Mridangam2021",146,"sketch_21_06_12") $ Single Solkattu.Score.Mridangam2021.sketch_21_06_12
    , setLocation ("Solkattu.Score.Mridangam2021",152,"e_21_08_15") $ Single Solkattu.Score.Mridangam2021.e_21_08_15
    , setLocation ("Solkattu.Score.Mridangam2021",235,"e_21_10_10") $ Single Solkattu.Score.Mridangam2021.e_21_10_10
    , setLocation ("Solkattu.Score.Mridangam2022",11,"e_n_dd_dd") $ Single Solkattu.Score.Mridangam2022.e_n_dd_dd
    , setLocation ("Solkattu.Score.Mridangam2022",24,"e_n_dd_dd3") $ Single Solkattu.Score.Mridangam2022.e_n_dd_dd3
    , setLocation ("Solkattu.Score.Mridangam2022",37,"c_22_02_20") $ Single Solkattu.Score.Mridangam2022.c_22_02_20
    , setLocation ("Solkattu.Score.Mridangam2022",50,"c_22_03_02") $ Single Solkattu.Score.Mridangam2022.c_22_03_02
    , setLocation ("Solkattu.Score.Mridangam2022",62,"x_22_07_09") $ Single Solkattu.Score.Mridangam2022.x_22_07_09
    , setLocation ("Solkattu.Score.Mridangam2022",89,"s_22_09_25") $ Single Solkattu.Score.Mridangam2022.s_22_09_25
    , setLocation ("Solkattu.Score.Mridangam2022",103,"e_22_10_16") $ Single Solkattu.Score.Mridangam2022.e_22_10_16
    , setLocation ("Solkattu.Score.Mridangam2022",110,"t_endaro_ending") $ Single Solkattu.Score.Mridangam2022.t_endaro_ending
    , setLocation ("Solkattu.Score.MridangamSarva",19,"kir1") $ Single Solkattu.Score.MridangamSarva.kir1
    , setLocation ("Solkattu.Score.MridangamSarva",24,"kir2") $ Single Solkattu.Score.MridangamSarva.kir2
    , setLocation ("Solkattu.Score.MridangamSarva",44,"kir3") $ Single Solkattu.Score.MridangamSarva.kir3
    , setLocation ("Solkattu.Score.MridangamSarva",50,"kir4") $ Single Solkattu.Score.MridangamSarva.kir4
    , setLocation ("Solkattu.Score.MridangamSarva",55,"kir5") $ Single Solkattu.Score.MridangamSarva.kir5
    , setLocation ("Solkattu.Score.MridangamSarva",64,"mel1") $ Single Solkattu.Score.MridangamSarva.mel1
    , setLocation ("Solkattu.Score.MridangamSarva",69,"mel2") $ Single Solkattu.Score.MridangamSarva.mel2
    , setLocation ("Solkattu.Score.MridangamSarva",76,"dinna_kitataka") $ Single Solkattu.Score.MridangamSarva.dinna_kitataka
    , setLocation ("Solkattu.Score.MridangamSarva",90,"farans") $ Single Solkattu.Score.MridangamSarva.farans
    , setLocation ("Solkattu.Score.MridangamSarva",103,"kir6") $ Single Solkattu.Score.MridangamSarva.kir6
    , setLocation ("Solkattu.Score.MridangamSarva",125,"kir_misra_1") $ Single Solkattu.Score.MridangamSarva.kir_misra_1
    , setLocation ("Solkattu.Score.MridangamSarva",131,"kir_misra_2") $ Single Solkattu.Score.MridangamSarva.kir_misra_2
    , setLocation ("Solkattu.Score.MridangamSarva",136,"c_17_10_23a") $ Single Solkattu.Score.MridangamSarva.c_17_10_23a
    , setLocation ("Solkattu.Score.MridangamSarva",142,"c_17_10_23b") $ Single Solkattu.Score.MridangamSarva.c_17_10_23b
    , setLocation ("Solkattu.Score.MridangamSarva",148,"c_18_05_25") $ Single Solkattu.Score.MridangamSarva.c_18_05_25
    , setLocation ("Solkattu.Score.MridangamTirmanam",14,"tir_short_adi") $ Single Solkattu.Score.MridangamTirmanam.tir_short_adi
    , setLocation ("Solkattu.Score.MridangamTirmanam",22,"tir_long_adi") $ Single Solkattu.Score.MridangamTirmanam.tir_long_adi
    , setLocation ("Solkattu.Score.MridangamTirmanam",32,"tir_sam_adi_kirkalam") $ Single Solkattu.Score.MridangamTirmanam.tir_sam_adi_kirkalam
    , setLocation ("Solkattu.Score.MridangamTirmanam",37,"tir_long_rupaka") $ Single Solkattu.Score.MridangamTirmanam.tir_long_rupaka
    , setLocation ("Solkattu.Score.Solkattu2013",20,"c_13_07_23") $ Single Solkattu.Score.Solkattu2013.c_13_07_23
    , setLocation ("Solkattu.Score.Solkattu2013",27,"c_13_08_14") $ Single Solkattu.Score.Solkattu2013.c_13_08_14
    , setLocation ("Solkattu.Score.Solkattu2013",68,"c_yt1") $ Single Solkattu.Score.Solkattu2013.c_yt1
    , setLocation ("Solkattu.Score.Solkattu2013",80,"c_13_10_29") $ Single Solkattu.Score.Solkattu2013.c_13_10_29
    , setLocation ("Solkattu.Score.Solkattu2013",94,"c_13_11_05") $ Single Solkattu.Score.Solkattu2013.c_13_11_05
    , setLocation ("Solkattu.Score.Solkattu2013",102,"c_13_11_12") $ Single Solkattu.Score.Solkattu2013.c_13_11_12
    , setLocation ("Solkattu.Score.Solkattu2013",118,"c_13_12_11") $ Single Solkattu.Score.Solkattu2013.c_13_12_11
    , setLocation ("Solkattu.Score.Solkattu2013",156,"k1_1") $ Single Solkattu.Score.Solkattu2013.k1_1
    , setLocation ("Solkattu.Score.Solkattu2013",173,"k1_2") $ Single Solkattu.Score.Solkattu2013.k1_2
    , setLocation ("Solkattu.Score.Solkattu2013",186,"k1_3") $ Single Solkattu.Score.Solkattu2013.k1_3
    , setLocation ("Solkattu.Score.Solkattu2013",220,"k3s") $ Single Solkattu.Score.Solkattu2013.k3s
    , setLocation ("Solkattu.Score.Solkattu2013",254,"t_sarva1") $ Single Solkattu.Score.Solkattu2013.t_sarva1
    , setLocation ("Solkattu.Score.Solkattu2013",268,"t1s") $ Single Solkattu.Score.Solkattu2013.t1s
    , setLocation ("Solkattu.Score.Solkattu2013",288,"t2s") $ Single Solkattu.Score.Solkattu2013.t2s
    , setLocation ("Solkattu.Score.Solkattu2013",318,"t3s") $ Single Solkattu.Score.Solkattu2013.t3s
    , setLocation ("Solkattu.Score.Solkattu2013",352,"t4s2") $ Single Solkattu.Score.Solkattu2013.t4s2
    , setLocation ("Solkattu.Score.Solkattu2013",377,"t4s3") $ Single Solkattu.Score.Solkattu2013.t4s3
    , setLocation ("Solkattu.Score.Solkattu2013",400,"t5s") $ Single Solkattu.Score.Solkattu2013.t5s
    , setLocation ("Solkattu.Score.Solkattu2013",453,"koraippu_misra_no_karvai") $ Single Solkattu.Score.Solkattu2013.koraippu_misra_no_karvai
    , setLocation ("Solkattu.Score.Solkattu2013",496,"koraippu_misra") $ Single Solkattu.Score.Solkattu2013.koraippu_misra
    , setLocation ("Solkattu.Score.Solkattu2013",534,"tir_18") $ Single Solkattu.Score.Solkattu2013.tir_18
    , setLocation ("Solkattu.Score.Solkattu2014",18,"c_14_01_01") $ Single Solkattu.Score.Solkattu2014.c_14_01_01
    , setLocation ("Solkattu.Score.Solkattu2014",43,"c_14_01_14") $ Single Solkattu.Score.Solkattu2014.c_14_01_14
    , setLocation ("Solkattu.Score.Solkattu2014",80,"c_14_02_05") $ Single Solkattu.Score.Solkattu2014.c_14_02_05
    , setLocation ("Solkattu.Score.Solkattu2014",124,"c_14_02_20") $ Single Solkattu.Score.Solkattu2014.c_14_02_20
    , setLocation ("Solkattu.Score.Solkattu2014",152,"c_14_02_27") $ Single Solkattu.Score.Solkattu2014.c_14_02_27
    , setLocation ("Solkattu.Score.Solkattu2014",186,"c_14_03_13") $ Single Solkattu.Score.Solkattu2014.c_14_03_13
    , setLocation ("Solkattu.Score.Solkattu2014",208,"c_14_03_26") $ Single Solkattu.Score.Solkattu2014.c_14_03_26
    , setLocation ("Solkattu.Score.Solkattu2014",235,"c_14_04_21") $ Single Solkattu.Score.Solkattu2014.c_14_04_21
    , setLocation ("Solkattu.Score.Solkattu2014",250,"c_14_04_29") $ Single Solkattu.Score.Solkattu2014.c_14_04_29
    , setLocation ("Solkattu.Score.Solkattu2014",286,"c_14_06_06") $ Single Solkattu.Score.Solkattu2014.c_14_06_06
    , setLocation ("Solkattu.Score.Solkattu2016",13,"c_16_09_28") $ Single Solkattu.Score.Solkattu2016.c_16_09_28
    , setLocation ("Solkattu.Score.Solkattu2016",39,"c_16_12_06_sriram1") $ Single Solkattu.Score.Solkattu2016.c_16_12_06_sriram1
    , setLocation ("Solkattu.Score.Solkattu2016",75,"c_16_12_06_sriram2") $ Single Solkattu.Score.Solkattu2016.c_16_12_06_sriram2
    , setLocation ("Solkattu.Score.Solkattu2016",97,"c_16_12_06_janahan1") $ Single Solkattu.Score.Solkattu2016.c_16_12_06_janahan1
    , setLocation ("Solkattu.Score.Solkattu2016",106,"c_16_12_06_janahan2") $ Single Solkattu.Score.Solkattu2016.c_16_12_06_janahan2
    , setLocation ("Solkattu.Score.Solkattu2017",19,"koraippu_janahan") $ Single Solkattu.Score.Solkattu2017.koraippu_janahan
    , setLocation ("Solkattu.Score.Solkattu2017",79,"e_spacing") $ Single Solkattu.Score.Solkattu2017.e_spacing
    , setLocation ("Solkattu.Score.Solkattu2017",94,"c_17_02_06") $ Single Solkattu.Score.Solkattu2017.c_17_02_06
    , setLocation ("Solkattu.Score.Solkattu2017",104,"c_17_03_20") $ Single Solkattu.Score.Solkattu2017.c_17_03_20
    , setLocation ("Solkattu.Score.Solkattu2017",130,"c_17_09_25") $ Single Solkattu.Score.Solkattu2017.c_17_09_25
    , setLocation ("Solkattu.Score.Solkattu2017",155,"c_17_04_04") $ Single Solkattu.Score.Solkattu2017.c_17_04_04
    , setLocation ("Solkattu.Score.Solkattu2017",181,"c_17_04_23") $ Single Solkattu.Score.Solkattu2017.c_17_04_23
    , setLocation ("Solkattu.Score.Solkattu2017",206,"c_17_05_10") $ Single Solkattu.Score.Solkattu2017.c_17_05_10
    , setLocation ("Solkattu.Score.Solkattu2017",253,"c_17_05_19") $ Single Solkattu.Score.Solkattu2017.c_17_05_19
    , setLocation ("Solkattu.Score.Solkattu2017",259,"c_17_05_19_janahan") $ Single Solkattu.Score.Solkattu2017.c_17_05_19_janahan
    , setLocation ("Solkattu.Score.Solkattu2017",283,"c_17_06_02_janahan") $ Single Solkattu.Score.Solkattu2017.c_17_06_02_janahan
    , setLocation ("Solkattu.Score.Solkattu2017",295,"c_17_06_15") $ Single Solkattu.Score.Solkattu2017.c_17_06_15
    , setLocation ("Solkattu.Score.Solkattu2017",310,"c_17_06_19") $ Single Solkattu.Score.Solkattu2017.c_17_06_19
    , setLocation ("Solkattu.Score.Solkattu2017",337,"c_17_06_19_koraippu") $ Single Solkattu.Score.Solkattu2017.c_17_06_19_koraippu
    , setLocation ("Solkattu.Score.Solkattu2017",369,"c_17_07_13") $ Single Solkattu.Score.Solkattu2017.c_17_07_13
    , setLocation ("Solkattu.Score.Solkattu2017",460,"c_17_07_19") $ Single Solkattu.Score.Solkattu2017.c_17_07_19
    , setLocation ("Solkattu.Score.Solkattu2017",473,"c_17_08_21") $ Single Solkattu.Score.Solkattu2017.c_17_08_21
    , setLocation ("Solkattu.Score.Solkattu2017",493,"c_17_08_29") $ Single Solkattu.Score.Solkattu2017.c_17_08_29
    , setLocation ("Solkattu.Score.Solkattu2017",556,"c_17_10_23") $ Single Solkattu.Score.Solkattu2017.c_17_10_23
    , setLocation ("Solkattu.Score.Solkattu2017",620,"c_20_12_12_kanda") $ Single Solkattu.Score.Solkattu2017.c_20_12_12_kanda
    , setLocation ("Solkattu.Score.Solkattu2017",709,"c_17_12_11") $ Single Solkattu.Score.Solkattu2017.c_17_12_11
    , setLocation ("Solkattu.Score.Solkattu2017",729,"speaking1") $ Single Solkattu.Score.Solkattu2017.speaking1
    , setLocation ("Solkattu.Score.Solkattu2018",18,"yt_mannargudi1") $ Single Solkattu.Score.Solkattu2018.yt_mannargudi1
    , setLocation ("Solkattu.Score.Solkattu2018",49,"e_18_02_26") $ Single Solkattu.Score.Solkattu2018.e_18_02_26
    , setLocation ("Solkattu.Score.Solkattu2018",71,"yt_mannargudi2") $ Single Solkattu.Score.Solkattu2018.yt_mannargudi2
    , setLocation ("Solkattu.Score.Solkattu2018",112,"yt_pmi1") $ Single Solkattu.Score.Solkattu2018.yt_pmi1
    , setLocation ("Solkattu.Score.Solkattu2018",154,"yt_karaikudi1") $ Single Solkattu.Score.Solkattu2018.yt_karaikudi1
    , setLocation ("Solkattu.Score.Solkattu2018",210,"c_18_03_19") $ Single Solkattu.Score.Solkattu2018.c_18_03_19
    , setLocation ("Solkattu.Score.Solkattu2018",257,"c_18_03_28") $ Single Solkattu.Score.Solkattu2018.c_18_03_28
    , setLocation ("Solkattu.Score.Solkattu2018",301,"c_18_04_25") $ Single Solkattu.Score.Solkattu2018.c_18_04_25
    , setLocation ("Solkattu.Score.Solkattu2018",337,"c_18_05_25") $ Single Solkattu.Score.Solkattu2018.c_18_05_25
    , setLocation ("Solkattu.Score.Solkattu2018",393,"misra_tani") $ Solkattu.Score.Solkattu2018.misra_tani
    , setLocation ("Solkattu.Score.Solkattu2018",409,"misra_tani1") $ Single Solkattu.Score.Solkattu2018.misra_tani1
    , setLocation ("Solkattu.Score.Solkattu2018",434,"misra_tani2") $ Single Solkattu.Score.Solkattu2018.misra_tani2
    , setLocation ("Solkattu.Score.Solkattu2018",456,"misra_to_mohra1a") $ Single Solkattu.Score.Solkattu2018.misra_to_mohra1a
    , setLocation ("Solkattu.Score.Solkattu2018",480,"misra_to_mohra1b") $ Single Solkattu.Score.Solkattu2018.misra_to_mohra1b
    , setLocation ("Solkattu.Score.Solkattu2018",528,"to_mohra_farans") $ Single Solkattu.Score.Solkattu2018.to_mohra_farans
    , setLocation ("Solkattu.Score.Solkattu2018",562,"misra_to_mohra3") $ Single Solkattu.Score.Solkattu2018.misra_to_mohra3
    , setLocation ("Solkattu.Score.Solkattu2018",581,"misra_to_mohra4") $ Single Solkattu.Score.Solkattu2018.misra_to_mohra4
    , setLocation ("Solkattu.Score.Solkattu2018",614,"misra_mohras") $ Single Solkattu.Score.Solkattu2018.misra_mohras
    , setLocation ("Solkattu.Score.Solkattu2018",640,"misra_muktayi1") $ Single Solkattu.Score.Solkattu2018.misra_muktayi1
    , setLocation ("Solkattu.Score.Solkattu2018",662,"trikalam1") $ Single Solkattu.Score.Solkattu2018.trikalam1
    , setLocation ("Solkattu.Score.Solkattu2018",685,"trikalam2") $ Single Solkattu.Score.Solkattu2018.trikalam2
    , setLocation ("Solkattu.Score.Solkattu2018",696,"e_sarva1") $ Single Solkattu.Score.Solkattu2018.e_sarva1
    , setLocation ("Solkattu.Score.Solkattu2018",707,"e_sarva2") $ Single Solkattu.Score.Solkattu2018.e_sarva2
    , setLocation ("Solkattu.Score.Solkattu2018",723,"e_misra_tisra") $ Single Solkattu.Score.Solkattu2018.e_misra_tisra
    , setLocation ("Solkattu.Score.Solkattu2018",739,"adi_tani") $ Solkattu.Score.Solkattu2018.adi_tani
    , setLocation ("Solkattu.Score.Solkattu2018",757,"adi_tani_misra") $ Solkattu.Score.Solkattu2018.adi_tani_misra
    , setLocation ("Solkattu.Score.Solkattu2018",770,"adi_tani1") $ Single Solkattu.Score.Solkattu2018.adi_tani1
    , setLocation ("Solkattu.Score.Solkattu2018",827,"e_sarva1_tisra") $ Single Solkattu.Score.Solkattu2018.e_sarva1_tisra
    , setLocation ("Solkattu.Score.Solkattu2018",845,"e_adi_tisra_misra2") $ Single Solkattu.Score.Solkattu2018.e_adi_tisra_misra2
    , setLocation ("Solkattu.Score.Solkattu2018",902,"e_adi_tisra") $ Single Solkattu.Score.Solkattu2018.e_adi_tisra
    , setLocation ("Solkattu.Score.Solkattu2018",955,"c_18_08_03") $ Single Solkattu.Score.Solkattu2018.c_18_08_03
    , setLocation ("Solkattu.Score.Solkattu2018",971,"c_18_08_03_misra") $ Single Solkattu.Score.Solkattu2018.c_18_08_03_misra
    , setLocation ("Solkattu.Score.Solkattu2018",988,"adi_tani2") $ Single Solkattu.Score.Solkattu2018.adi_tani2
    , setLocation ("Solkattu.Score.Solkattu2018",1022,"adi_tani2_misra") $ Single Solkattu.Score.Solkattu2018.adi_tani2_misra
    , setLocation ("Solkattu.Score.Solkattu2018",1050,"adi_muktayi") $ Single Solkattu.Score.Solkattu2018.adi_muktayi
    , setLocation ("Solkattu.Score.Solkattu2018",1073,"adi_muktayi_misra") $ Single Solkattu.Score.Solkattu2018.adi_muktayi_misra
    , setLocation ("Solkattu.Score.Solkattu2018",1092,"misra_trikalam") $ Single Solkattu.Score.Solkattu2018.misra_trikalam
    , setLocation ("Solkattu.Score.Solkattu2018",1138,"c_18_09_25") $ Single Solkattu.Score.Solkattu2018.c_18_09_25
    , setLocation ("Solkattu.Score.Solkattu2018",1152,"c_18_09_25_misra") $ Single Solkattu.Score.Solkattu2018.c_18_09_25_misra
    , setLocation ("Solkattu.Score.Solkattu2018",1166,"c_18_10_06") $ Single Solkattu.Score.Solkattu2018.c_18_10_06
    , setLocation ("Solkattu.Score.Solkattu2018",1177,"c_18_10_22") $ Single Solkattu.Score.Solkattu2018.c_18_10_22
    , setLocation ("Solkattu.Score.Solkattu2018",1191,"c_18_10_29") $ Single Solkattu.Score.Solkattu2018.c_18_10_29
    , setLocation ("Solkattu.Score.Solkattu2018",1209,"tisra_mohra") $ Single Solkattu.Score.Solkattu2018.tisra_mohra
    , setLocation ("Solkattu.Score.Solkattu2019",14,"c_19_04_15") $ Single Solkattu.Score.Solkattu2019.c_19_04_15
    , setLocation ("Solkattu.Score.Solkattu2019",44,"c_19_06_17") $ Single Solkattu.Score.Solkattu2019.c_19_06_17
    , setLocation ("Solkattu.Score.Solkattu2019",65,"c_19_07_15") $ Single Solkattu.Score.Solkattu2019.c_19_07_15
    , setLocation ("Solkattu.Score.Solkattu2019",118,"e_19_09_23_kandam") $ Single Solkattu.Score.Solkattu2019.e_19_09_23_kandam
    , setLocation ("Solkattu.Score.Solkattu2019",128,"e_19_10_14_kandam") $ Single Solkattu.Score.Solkattu2019.e_19_10_14_kandam
    , setLocation ("Solkattu.Score.Solkattu2019",151,"c_19_10_28_kandam") $ Single Solkattu.Score.Solkattu2019.c_19_10_28_kandam
    , setLocation ("Solkattu.Score.Solkattu2019",171,"e_19_11_11_kandam") $ Single Solkattu.Score.Solkattu2019.e_19_11_11_kandam
    , setLocation ("Solkattu.Score.Solkattu2020",18,"e_20_01_27") $ Single Solkattu.Score.Solkattu2020.e_20_01_27
    , setLocation ("Solkattu.Score.Solkattu2020",28,"c_20_04_03") $ Single Solkattu.Score.Solkattu2020.c_20_04_03
    , setLocation ("Solkattu.Score.Solkattu2020",74,"c_20_10_25") $ Single Solkattu.Score.Solkattu2020.c_20_10_25
    , setLocation ("Solkattu.Score.Solkattu2020",173,"kendang_farans") $ Single Solkattu.Score.Solkattu2020.kendang_farans
    , setLocation ("Solkattu.Score.Solkattu2021",16,"kon_21_01_24") $ Single Solkattu.Score.Solkattu2021.kon_21_01_24
    , setLocation ("Solkattu.Score.Solkattu2021",30,"kon_21_02_21") $ Single Solkattu.Score.Solkattu2021.kon_21_02_21
    , setLocation ("Solkattu.Score.Solkattu2021",45,"kon_35_kanda") $ Single Solkattu.Score.Solkattu2021.kon_35_kanda
    , setLocation ("Solkattu.Score.Solkattu2021",45,"kon_35_misra") $ Single Solkattu.Score.Solkattu2021.kon_35_misra
    , setLocation ("Solkattu.Score.Solkattu2021",60,"kon_tadit_tarikitathom") $ Single Solkattu.Score.Solkattu2021.kon_tadit_tarikitathom
    , setLocation ("Solkattu.Score.Solkattu2021",71,"april_tani") $ Solkattu.Score.Solkattu2021.april_tani
    , setLocation ("Solkattu.Score.Solkattu2021",87,"koraippu_development") $ Single Solkattu.Score.Solkattu2021.koraippu_development
    , setLocation ("Solkattu.Score.Solkattu2021",111,"c_mohra_korvai") $ Single Solkattu.Score.Solkattu2021.c_mohra_korvai
    , setLocation ("Solkattu.Score.Solkattu2021",127,"e_21_04_25") $ Single Solkattu.Score.Solkattu2021.e_21_04_25
    , setLocation ("Solkattu.Score.SolkattuMohra",55,"c_mohra") $ Single Solkattu.Score.SolkattuMohra.c_mohra
    , setLocation ("Solkattu.Score.SolkattuMohra",95,"c_mohra2") $ Single Solkattu.Score.SolkattuMohra.c_mohra2
    , setLocation ("Solkattu.Score.SolkattuMohra",113,"c_mohra_youtube") $ Single Solkattu.Score.SolkattuMohra.c_mohra_youtube
    , setLocation ("Solkattu.Score.SolkattuMohra",140,"misra1") $ Single Solkattu.Score.SolkattuMohra.misra1
    ]
