-- Copyright 2019 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Synth.Sampler.Patch.Metronome where
import qualified Data.Map as Map

import qualified Util.Num as Num
import qualified Util.Seq as Seq
import qualified Cmd.Instrument.ImInst as ImInst
import qualified Perform.Im.Patch as Im.Patch
import qualified Perform.NN as NN
import qualified Perform.Pitch as Pitch

import qualified Synth.Sampler.Patch as Patch
import qualified Synth.Sampler.Patch.Util as Util
import qualified Synth.Sampler.Sample as Sample
import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Note as Note
import qualified Synth.Shared.Signal as Signal

import           Global


patches :: [Patch.DbPatch]
patches = (:[]) $ Patch.DbPatch $ (Patch.patch "metronome")
    { Patch._dir = "metronome"
    , Patch._convert = convert
    , Patch._karyaPatch = ImInst.make_patch $ Im.Patch.patch
        { Im.Patch.patch_controls = mconcat
            [ Control.supportPitch
            , Control.supportDyn
            ]
        }
    }

convert :: Note.Note -> Patch.ConvertM Sample.Sample
convert note = do
    pitch <- Util.initialPitch note
    let (fname, ratio) = Util.findPitchRatio nnToSample pitch
    let dynVal = Note.initial0 Control.dynamic note
    return $ (Sample.make fname)
        { Sample.envelope = Signal.constant (dynVal + 0.35)
        , Sample.ratios = Signal.constant ratio
        }

nnToSample :: Map Pitch.NoteNumber FilePath
nnToSample = Map.fromList $
    zip (take 13 $ Seq.range_ NN.c3 3)
        (map (\i -> "s-" <> untxt (Num.zeroPad 3 i) <> ".flac") [1..])