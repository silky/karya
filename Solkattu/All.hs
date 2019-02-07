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
import Solkattu.Metadata (setLocation)
import qualified Solkattu.Score.Mridangam2013
import qualified Solkattu.Score.Mridangam2015
import qualified Solkattu.Score.Mridangam2016
import qualified Solkattu.Score.Mridangam2017
import qualified Solkattu.Score.Mridangam2018
import qualified Solkattu.Score.MridangamSarva
import qualified Solkattu.Score.Solkattu2013
import qualified Solkattu.Score.Solkattu2014
import qualified Solkattu.Score.Solkattu2016
import qualified Solkattu.Score.Solkattu2017
import qualified Solkattu.Score.Solkattu2018
import qualified Solkattu.Score.SolkattuMohra


korvais :: [Korvai.Korvai]
korvais = map Korvai.inferMetadata
    [ setLocation ("Solkattu.Score.Mridangam2013",15,"dinnagina_sequence") Solkattu.Score.Mridangam2013.dinnagina_sequence
    , setLocation ("Solkattu.Score.Mridangam2013",85,"t_17_02_13") Solkattu.Score.Mridangam2013.t_17_02_13
    , setLocation ("Solkattu.Score.Mridangam2013",98,"din_nadin") Solkattu.Score.Mridangam2013.din_nadin
    , setLocation ("Solkattu.Score.Mridangam2013",105,"nadin_ka") Solkattu.Score.Mridangam2013.nadin_ka
    , setLocation ("Solkattu.Score.Mridangam2013",110,"nadindin") Solkattu.Score.Mridangam2013.nadindin
    , setLocation ("Solkattu.Score.Mridangam2013",130,"nadindin_negative") Solkattu.Score.Mridangam2013.nadindin_negative
    , setLocation ("Solkattu.Score.Mridangam2013",143,"namita_dimita") Solkattu.Score.Mridangam2013.namita_dimita
    , setLocation ("Solkattu.Score.Mridangam2013",150,"namita_dimita_seq") Solkattu.Score.Mridangam2013.namita_dimita_seq
    , setLocation ("Solkattu.Score.Mridangam2013",182,"janahan_exercise") Solkattu.Score.Mridangam2013.janahan_exercise
    , setLocation ("Solkattu.Score.Mridangam2013",186,"nakanadin") Solkattu.Score.Mridangam2013.nakanadin
    , setLocation ("Solkattu.Score.Mridangam2013",193,"farans") Solkattu.Score.Mridangam2013.farans
    , setLocation ("Solkattu.Score.Mridangam2013",239,"eddupu6") Solkattu.Score.Mridangam2013.eddupu6
    , setLocation ("Solkattu.Score.Mridangam2013",250,"eddupu10") Solkattu.Score.Mridangam2013.eddupu10
    , setLocation ("Solkattu.Score.Mridangam2015",13,"c_1") Solkattu.Score.Mridangam2015.c_1
    , setLocation ("Solkattu.Score.Mridangam2015",23,"c_2") Solkattu.Score.Mridangam2015.c_2
    , setLocation ("Solkattu.Score.Mridangam2015",33,"c_3") Solkattu.Score.Mridangam2015.c_3
    , setLocation ("Solkattu.Score.Mridangam2016",12,"t_16_11_14") Solkattu.Score.Mridangam2016.t_16_11_14
    , setLocation ("Solkattu.Score.Mridangam2017",11,"c_17_07_10") Solkattu.Score.Mridangam2017.c_17_07_10
    , setLocation ("Solkattu.Score.Mridangam2017",15,"e_1") Solkattu.Score.Mridangam2017.e_1
    , setLocation ("Solkattu.Score.Mridangam2017",24,"e_2") Solkattu.Score.Mridangam2017.e_2
    , setLocation ("Solkattu.Score.Mridangam2018",13,"e_323_1") Solkattu.Score.Mridangam2018.e_323_1
    , setLocation ("Solkattu.Score.Mridangam2018",27,"e_323_2") Solkattu.Score.Mridangam2018.e_323_2
    , setLocation ("Solkattu.Score.Mridangam2018",37,"e_18_03_19") Solkattu.Score.Mridangam2018.e_18_03_19
    , setLocation ("Solkattu.Score.Mridangam2018",45,"e_18_03_28") Solkattu.Score.Mridangam2018.e_18_03_28
    , setLocation ("Solkattu.Score.Mridangam2018",50,"e_18_05_25") Solkattu.Score.Mridangam2018.e_18_05_25
    , setLocation ("Solkattu.Score.Mridangam2018",57,"tir_18_05_25") Solkattu.Score.Mridangam2018.tir_18_05_25
    , setLocation ("Solkattu.Score.Mridangam2018",62,"tir_18_06_15") Solkattu.Score.Mridangam2018.tir_18_06_15
    , setLocation ("Solkattu.Score.Mridangam2018",94,"e_18_06_22") Solkattu.Score.Mridangam2018.e_18_06_22
    , setLocation ("Solkattu.Score.Mridangam2018",149,"c_18_07_02_sarva") Solkattu.Score.Mridangam2018.c_18_07_02_sarva
    , setLocation ("Solkattu.Score.Mridangam2018",158,"e_misra_tisram") Solkattu.Score.Mridangam2018.e_misra_tisram
    , setLocation ("Solkattu.Score.Mridangam2018",178,"e_18_11_12") Solkattu.Score.Mridangam2018.e_18_11_12
    , setLocation ("Solkattu.Score.Mridangam2018",199,"e_18_11_19") Solkattu.Score.Mridangam2018.e_18_11_19
    , setLocation ("Solkattu.Score.Mridangam2018",211,"e_18_12_08") Solkattu.Score.Mridangam2018.e_18_12_08
    , setLocation ("Solkattu.Score.Mridangam2018",220,"e_18_12_08_b") Solkattu.Score.Mridangam2018.e_18_12_08_b
    , setLocation ("Solkattu.Score.Mridangam2018",227,"p5_variations") Solkattu.Score.Mridangam2018.p5_variations
    , setLocation ("Solkattu.Score.Mridangam2018",250,"e_npkt") Solkattu.Score.Mridangam2018.e_npkt
    , setLocation ("Solkattu.Score.MridangamSarva",19,"kir1") Solkattu.Score.MridangamSarva.kir1
    , setLocation ("Solkattu.Score.MridangamSarva",24,"kir2") Solkattu.Score.MridangamSarva.kir2
    , setLocation ("Solkattu.Score.MridangamSarva",44,"kir3") Solkattu.Score.MridangamSarva.kir3
    , setLocation ("Solkattu.Score.MridangamSarva",50,"kir4") Solkattu.Score.MridangamSarva.kir4
    , setLocation ("Solkattu.Score.MridangamSarva",55,"kir5") Solkattu.Score.MridangamSarva.kir5
    , setLocation ("Solkattu.Score.MridangamSarva",64,"mel1") Solkattu.Score.MridangamSarva.mel1
    , setLocation ("Solkattu.Score.MridangamSarva",69,"mel2") Solkattu.Score.MridangamSarva.mel2
    , setLocation ("Solkattu.Score.MridangamSarva",76,"dinna_kitataka") Solkattu.Score.MridangamSarva.dinna_kitataka
    , setLocation ("Solkattu.Score.MridangamSarva",90,"farans") Solkattu.Score.MridangamSarva.farans
    , setLocation ("Solkattu.Score.MridangamSarva",103,"kir6") Solkattu.Score.MridangamSarva.kir6
    , setLocation ("Solkattu.Score.MridangamSarva",125,"kir_misra_1") Solkattu.Score.MridangamSarva.kir_misra_1
    , setLocation ("Solkattu.Score.MridangamSarva",131,"kir_misra_2") Solkattu.Score.MridangamSarva.kir_misra_2
    , setLocation ("Solkattu.Score.MridangamSarva",136,"c_17_10_23a") Solkattu.Score.MridangamSarva.c_17_10_23a
    , setLocation ("Solkattu.Score.MridangamSarva",142,"c_17_10_23b") Solkattu.Score.MridangamSarva.c_17_10_23b
    , setLocation ("Solkattu.Score.MridangamSarva",148,"c_18_05_25") Solkattu.Score.MridangamSarva.c_18_05_25
    , setLocation ("Solkattu.Score.Solkattu2013",21,"c_13_07_23") Solkattu.Score.Solkattu2013.c_13_07_23
    , setLocation ("Solkattu.Score.Solkattu2013",28,"c_13_08_14") Solkattu.Score.Solkattu2013.c_13_08_14
    , setLocation ("Solkattu.Score.Solkattu2013",69,"c_yt1") Solkattu.Score.Solkattu2013.c_yt1
    , setLocation ("Solkattu.Score.Solkattu2013",81,"c_13_10_29") Solkattu.Score.Solkattu2013.c_13_10_29
    , setLocation ("Solkattu.Score.Solkattu2013",95,"c_13_11_05") Solkattu.Score.Solkattu2013.c_13_11_05
    , setLocation ("Solkattu.Score.Solkattu2013",103,"c_13_11_12") Solkattu.Score.Solkattu2013.c_13_11_12
    , setLocation ("Solkattu.Score.Solkattu2013",119,"c_13_12_11") Solkattu.Score.Solkattu2013.c_13_12_11
    , setLocation ("Solkattu.Score.Solkattu2013",157,"k1_1") Solkattu.Score.Solkattu2013.k1_1
    , setLocation ("Solkattu.Score.Solkattu2013",174,"k1_2") Solkattu.Score.Solkattu2013.k1_2
    , setLocation ("Solkattu.Score.Solkattu2013",187,"k1_3") Solkattu.Score.Solkattu2013.k1_3
    , setLocation ("Solkattu.Score.Solkattu2013",221,"k3s") Solkattu.Score.Solkattu2013.k3s
    , setLocation ("Solkattu.Score.Solkattu2013",255,"t_sarva1") Solkattu.Score.Solkattu2013.t_sarva1
    , setLocation ("Solkattu.Score.Solkattu2013",269,"t1s") Solkattu.Score.Solkattu2013.t1s
    , setLocation ("Solkattu.Score.Solkattu2013",289,"t2s") Solkattu.Score.Solkattu2013.t2s
    , setLocation ("Solkattu.Score.Solkattu2013",319,"t3s") Solkattu.Score.Solkattu2013.t3s
    , setLocation ("Solkattu.Score.Solkattu2013",353,"t4s2") Solkattu.Score.Solkattu2013.t4s2
    , setLocation ("Solkattu.Score.Solkattu2013",378,"t4s3") Solkattu.Score.Solkattu2013.t4s3
    , setLocation ("Solkattu.Score.Solkattu2013",401,"t5s") Solkattu.Score.Solkattu2013.t5s
    , setLocation ("Solkattu.Score.Solkattu2013",454,"koraippu_misra_no_karvai") Solkattu.Score.Solkattu2013.koraippu_misra_no_karvai
    , setLocation ("Solkattu.Score.Solkattu2013",497,"koraippu_misra") Solkattu.Score.Solkattu2013.koraippu_misra
    , setLocation ("Solkattu.Score.Solkattu2013",535,"tir_18") Solkattu.Score.Solkattu2013.tir_18
    , setLocation ("Solkattu.Score.Solkattu2014",18,"c_14_01_01") Solkattu.Score.Solkattu2014.c_14_01_01
    , setLocation ("Solkattu.Score.Solkattu2014",43,"c_14_01_14") Solkattu.Score.Solkattu2014.c_14_01_14
    , setLocation ("Solkattu.Score.Solkattu2014",79,"c_14_02_05") Solkattu.Score.Solkattu2014.c_14_02_05
    , setLocation ("Solkattu.Score.Solkattu2014",117,"c_14_02_20") Solkattu.Score.Solkattu2014.c_14_02_20
    , setLocation ("Solkattu.Score.Solkattu2014",145,"c_14_02_27") Solkattu.Score.Solkattu2014.c_14_02_27
    , setLocation ("Solkattu.Score.Solkattu2014",179,"c_14_03_13") Solkattu.Score.Solkattu2014.c_14_03_13
    , setLocation ("Solkattu.Score.Solkattu2014",201,"c_14_03_26") Solkattu.Score.Solkattu2014.c_14_03_26
    , setLocation ("Solkattu.Score.Solkattu2014",228,"c_14_04_21") Solkattu.Score.Solkattu2014.c_14_04_21
    , setLocation ("Solkattu.Score.Solkattu2014",243,"c_14_04_29") Solkattu.Score.Solkattu2014.c_14_04_29
    , setLocation ("Solkattu.Score.Solkattu2014",279,"c_14_06_06") Solkattu.Score.Solkattu2014.c_14_06_06
    , setLocation ("Solkattu.Score.Solkattu2016",13,"c_16_09_28") Solkattu.Score.Solkattu2016.c_16_09_28
    , setLocation ("Solkattu.Score.Solkattu2016",39,"c_16_12_06_sriram1") Solkattu.Score.Solkattu2016.c_16_12_06_sriram1
    , setLocation ("Solkattu.Score.Solkattu2016",75,"c_16_12_06_sriram2") Solkattu.Score.Solkattu2016.c_16_12_06_sriram2
    , setLocation ("Solkattu.Score.Solkattu2016",97,"c_16_12_06_janahan1") Solkattu.Score.Solkattu2016.c_16_12_06_janahan1
    , setLocation ("Solkattu.Score.Solkattu2016",106,"c_16_12_06_janahan2") Solkattu.Score.Solkattu2016.c_16_12_06_janahan2
    , setLocation ("Solkattu.Score.Solkattu2017",19,"koraippu_janahan") Solkattu.Score.Solkattu2017.koraippu_janahan
    , setLocation ("Solkattu.Score.Solkattu2017",78,"e_spacing") Solkattu.Score.Solkattu2017.e_spacing
    , setLocation ("Solkattu.Score.Solkattu2017",93,"c_17_02_06") Solkattu.Score.Solkattu2017.c_17_02_06
    , setLocation ("Solkattu.Score.Solkattu2017",103,"c_17_03_20") Solkattu.Score.Solkattu2017.c_17_03_20
    , setLocation ("Solkattu.Score.Solkattu2017",126,"c_17_09_25") Solkattu.Score.Solkattu2017.c_17_09_25
    , setLocation ("Solkattu.Score.Solkattu2017",151,"c_17_04_04") Solkattu.Score.Solkattu2017.c_17_04_04
    , setLocation ("Solkattu.Score.Solkattu2017",177,"c_17_04_23") Solkattu.Score.Solkattu2017.c_17_04_23
    , setLocation ("Solkattu.Score.Solkattu2017",202,"c_17_05_10") Solkattu.Score.Solkattu2017.c_17_05_10
    , setLocation ("Solkattu.Score.Solkattu2017",250,"c_17_05_11") Solkattu.Score.Solkattu2017.c_17_05_11
    , setLocation ("Solkattu.Score.Solkattu2017",278,"c_17_05_19") Solkattu.Score.Solkattu2017.c_17_05_19
    , setLocation ("Solkattu.Score.Solkattu2017",284,"c_17_05_19_janahan") Solkattu.Score.Solkattu2017.c_17_05_19_janahan
    , setLocation ("Solkattu.Score.Solkattu2017",308,"c_17_06_02_janahan") Solkattu.Score.Solkattu2017.c_17_06_02_janahan
    , setLocation ("Solkattu.Score.Solkattu2017",320,"c_17_06_15") Solkattu.Score.Solkattu2017.c_17_06_15
    , setLocation ("Solkattu.Score.Solkattu2017",335,"c_17_06_19") Solkattu.Score.Solkattu2017.c_17_06_19
    , setLocation ("Solkattu.Score.Solkattu2017",362,"c_17_06_19_koraippu") Solkattu.Score.Solkattu2017.c_17_06_19_koraippu
    , setLocation ("Solkattu.Score.Solkattu2017",387,"c_17_07_13") Solkattu.Score.Solkattu2017.c_17_07_13
    , setLocation ("Solkattu.Score.Solkattu2017",478,"c_17_07_19") Solkattu.Score.Solkattu2017.c_17_07_19
    , setLocation ("Solkattu.Score.Solkattu2017",491,"c_17_08_21") Solkattu.Score.Solkattu2017.c_17_08_21
    , setLocation ("Solkattu.Score.Solkattu2017",511,"c_17_08_29") Solkattu.Score.Solkattu2017.c_17_08_29
    , setLocation ("Solkattu.Score.Solkattu2017",574,"c_17_10_23") Solkattu.Score.Solkattu2017.c_17_10_23
    , setLocation ("Solkattu.Score.Solkattu2017",634,"c_17_12_11") Solkattu.Score.Solkattu2017.c_17_12_11
    , setLocation ("Solkattu.Score.Solkattu2017",654,"speaking1") Solkattu.Score.Solkattu2017.speaking1
    , setLocation ("Solkattu.Score.Solkattu2018",17,"yt_mannargudi1") Solkattu.Score.Solkattu2018.yt_mannargudi1
    , setLocation ("Solkattu.Score.Solkattu2018",48,"e_18_02_26") Solkattu.Score.Solkattu2018.e_18_02_26
    , setLocation ("Solkattu.Score.Solkattu2018",70,"yt_mannargudi2") Solkattu.Score.Solkattu2018.yt_mannargudi2
    , setLocation ("Solkattu.Score.Solkattu2018",111,"yt_pmi1") Solkattu.Score.Solkattu2018.yt_pmi1
    , setLocation ("Solkattu.Score.Solkattu2018",153,"yt_karaikudi1") Solkattu.Score.Solkattu2018.yt_karaikudi1
    , setLocation ("Solkattu.Score.Solkattu2018",209,"c_18_03_19") Solkattu.Score.Solkattu2018.c_18_03_19
    , setLocation ("Solkattu.Score.Solkattu2018",256,"c_18_03_28") Solkattu.Score.Solkattu2018.c_18_03_28
    , setLocation ("Solkattu.Score.Solkattu2018",300,"c_18_04_25") Solkattu.Score.Solkattu2018.c_18_04_25
    , setLocation ("Solkattu.Score.Solkattu2018",336,"c_18_05_25") Solkattu.Score.Solkattu2018.c_18_05_25
    , setLocation ("Solkattu.Score.Solkattu2018",405,"misra_tani1") Solkattu.Score.Solkattu2018.misra_tani1
    , setLocation ("Solkattu.Score.Solkattu2018",430,"misra_tani2") Solkattu.Score.Solkattu2018.misra_tani2
    , setLocation ("Solkattu.Score.Solkattu2018",452,"misra_to_mohra1a") Solkattu.Score.Solkattu2018.misra_to_mohra1a
    , setLocation ("Solkattu.Score.Solkattu2018",477,"misra_to_mohra1b") Solkattu.Score.Solkattu2018.misra_to_mohra1b
    , setLocation ("Solkattu.Score.Solkattu2018",525,"to_mohra_farans") Solkattu.Score.Solkattu2018.to_mohra_farans
    , setLocation ("Solkattu.Score.Solkattu2018",559,"misra_to_mohra3") Solkattu.Score.Solkattu2018.misra_to_mohra3
    , setLocation ("Solkattu.Score.Solkattu2018",578,"misra_to_mohra4") Solkattu.Score.Solkattu2018.misra_to_mohra4
    , setLocation ("Solkattu.Score.Solkattu2018",611,"misra_mohras") Solkattu.Score.Solkattu2018.misra_mohras
    , setLocation ("Solkattu.Score.Solkattu2018",637,"misra_muktayi1") Solkattu.Score.Solkattu2018.misra_muktayi1
    , setLocation ("Solkattu.Score.Solkattu2018",659,"trikalam1") Solkattu.Score.Solkattu2018.trikalam1
    , setLocation ("Solkattu.Score.Solkattu2018",682,"trikalam2") Solkattu.Score.Solkattu2018.trikalam2
    , setLocation ("Solkattu.Score.Solkattu2018",694,"e_sarva1") Solkattu.Score.Solkattu2018.e_sarva1
    , setLocation ("Solkattu.Score.Solkattu2018",705,"e_sarva2") Solkattu.Score.Solkattu2018.e_sarva2
    , setLocation ("Solkattu.Score.Solkattu2018",721,"e_misra_tisra") Solkattu.Score.Solkattu2018.e_misra_tisra
    , setLocation ("Solkattu.Score.Solkattu2018",755,"adi_tani1") Solkattu.Score.Solkattu2018.adi_tani1
    , setLocation ("Solkattu.Score.Solkattu2018",812,"e_sarva1_tisra") Solkattu.Score.Solkattu2018.e_sarva1_tisra
    , setLocation ("Solkattu.Score.Solkattu2018",836,"e_adi_tisra") Solkattu.Score.Solkattu2018.e_adi_tisra
    , setLocation ("Solkattu.Score.Solkattu2018",889,"c_18_08_03") Solkattu.Score.Solkattu2018.c_18_08_03
    , setLocation ("Solkattu.Score.Solkattu2018",905,"adi_tani2") Solkattu.Score.Solkattu2018.adi_tani2
    , setLocation ("Solkattu.Score.Solkattu2018",939,"adi_muktayi") Solkattu.Score.Solkattu2018.adi_muktayi
    , setLocation ("Solkattu.Score.Solkattu2018",965,"misra_trikalam") Solkattu.Score.Solkattu2018.misra_trikalam
    , setLocation ("Solkattu.Score.Solkattu2018",1011,"c_18_09_25") Solkattu.Score.Solkattu2018.c_18_09_25
    , setLocation ("Solkattu.Score.Solkattu2018",1025,"c_18_09_25_misra") Solkattu.Score.Solkattu2018.c_18_09_25_misra
    , setLocation ("Solkattu.Score.Solkattu2018",1039,"c_18_10_06") Solkattu.Score.Solkattu2018.c_18_10_06
    , setLocation ("Solkattu.Score.Solkattu2018",1050,"c_18_10_22") Solkattu.Score.Solkattu2018.c_18_10_22
    , setLocation ("Solkattu.Score.Solkattu2018",1064,"c_18_10_29") Solkattu.Score.Solkattu2018.c_18_10_29
    , setLocation ("Solkattu.Score.Solkattu2018",1082,"tisra_mohra") Solkattu.Score.Solkattu2018.tisra_mohra
    , setLocation ("Solkattu.Score.SolkattuMohra",64,"c_mohra") Solkattu.Score.SolkattuMohra.c_mohra
    , setLocation ("Solkattu.Score.SolkattuMohra",90,"c_mohra2") Solkattu.Score.SolkattuMohra.c_mohra2
    , setLocation ("Solkattu.Score.SolkattuMohra",108,"c_mohra_youtube") Solkattu.Score.SolkattuMohra.c_mohra_youtube
    ]
