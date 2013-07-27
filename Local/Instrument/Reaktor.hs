-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Native Instruments' Reaktor softsynth.
module Local.Instrument.Reaktor where
import qualified Data.Set as Set

import Util.Control
import qualified Midi.CC as CC
import qualified Derive.Attrs as Attrs
import qualified Derive.Controls as Controls
import qualified Derive.Score as Score

import qualified Perform.Midi.Instrument as Instrument
import qualified App.MidiInst as MidiInst


load :: FilePath -> IO [MidiInst.SynthDesc]
load _dir = return $ MidiInst.make
    (MidiInst.softsynth "reak" "Native Instruments Reaktor" pb_range [])
    { MidiInst.extra_patches = MidiInst.with_empty_code patches }

pb_range = (-96, 96)

filter_composite :: Instrument.Composite
filter_composite = (Score.instrument "reak" "filter", Just (c "res"),
        Set.fromList $ map c ["mix", "q", "lp-hp", "2-4-pole"])
    where c = Score.control

patches :: [Instrument.Patch]
patches =
    -- My own patches.
    [ MidiInst.pressure $ MidiInst.patch pb_range "fm1" [(4, c "depth")]
    , Instrument.text #= "Tunable comb filter that processes an audio signal." $
        MidiInst.patch pb_range "comb" [(1, c "mix"), (4, c "fbk")]
    , Instrument.text #= "Tunable filter that processes an audio signal." $
        MidiInst.patch pb_range "filter"
            [ (1, c "mix")
            , (CC.cc14, c "q")
            , (CC.cc15, c "lp-hp")
            , (CC.cc16, c "2-4-pole")
            ]

    -- Factory patches.
    , MidiInst.patch pb_range "lazerbass"
        -- In 'parameter', replace bend input of 'Basic Pitch prepare' with 96,
        -- replace 'M.tr' input of 'Global P/G' with 0.
        -- Rebind ccs for c1 and c2.
        [ (CC.cc14, Controls.mc1), (CC.cc15, Controls.mc2)
        ]
    , MidiInst.patch pb_range "steam"
        -- Steampipe2, set pitch bend range to 96.
        []

    -- Commercial patches.

    , MidiInst.patch pb_range "spark"
        [ (4, Controls.mc1), (11, Controls.mc2), (1, Controls.mc3)
        , (CC.cc14, Controls.fc)
        , (CC.cc15, Controls.q)
        ]
    , MidiInst.patch pb_range "prism"
        [ (1, Controls.mc1)
        , (11, Controls.mc2)
        ]

    -- Downloaded patches.

    , MidiInst.patch pb_range "shark"
        -- Downloaded from NI, Shark.ens.
        -- Modifications: pitchbend to 96, signal smoothers from 100ms to 10ms.
        [ (4, Controls.fc), (3, Controls.q) -- 1st filter
        , (10, c "color")
        ]

    , Instrument.text #= "Herald brass physical model." $
        -- Downloaded from NI, Herald_Brass_V2.ens.
        -- Modifications: disconnect the PM port and replace with pitch bend of
        -- 96.  Assign controls to knobs.
        -- Flutter and vib are just macros for air and emb controls, but seem
        -- useful.
        MidiInst.pressure $ MidiInst.patch pb_range "herald"
            [ (CC.mod, Controls.vib)
            , (CC.vib_speed, Controls.vib_speed)
            , (CC.cc14, c "atk") -- tongue attack
            , (CC.cc15, c "buzz") -- tongue buzz
            , (CC.cc16, c "buzz-len") -- tongue buzz length
            , (CC.cc17, c "emb") -- lips embouchure
            , (CC.cc18, c "stiff") -- lips stiffness
            -- , (CC.cc19, c "noise") -- lips noise, not implemented
            , (CC.cc20, c "finger") -- bore finger time

            , (CC.cc21, c "flut") -- flutter tongue
            , (CC.cc22, c "flut-speed") -- flutter tongue speed
            ]

    , Instrument.text #= "Serenade bowed string physical model." $
        -- Downloaded from NI, Serenade.ens.
        -- Modifications: Remove gesture and replace with a direct mapping to
        -- cc2.  Add pitch bend to pitch.  Assign controls to knobs.
        --
        -- It's important to put the pitch bend in "Bowed String", after the
        -- tuner.
        --
        -- I map breath to only one bowing direction, since deciding on which
        -- direction the bow is going all the time seems like a pain, and
        -- probably has minimal affect on the sound.  If dropping to
        -- 0 momentarily sounds like a direction change then that's good
        -- enough.
        Instrument.keyswitches #=
            Instrument.cc_keyswitches CC.cc20 [(Attrs.pizz, 127), (mempty, 0)] $
        MidiInst.pressure $ MidiInst.patch (-24, 24) "serenade"
            [ (CC.mod, Controls.vib)
            , (CC.vib_speed, Controls.vib_speed)
            , (CC.cc14, c "bow-speed")
            , (CC.cc15, c "bow-force")
            , (CC.cc16, c "bow-pos")
            , (CC.cc17, c "string-jitter")
            , (CC.cc18, c "string-buzz")
            , (CC.cc21, c "pizz-tone")
            , (CC.cc22, c "pizz-time")
            , (CC.cc23, c "pizz-level")
            ]
    ]
    where c = Score.control
