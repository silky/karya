-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Synth.Sampler.Patch.WayangCode where
import qualified Cmd.Instrument.Bali as Bali
import qualified Cmd.Instrument.ImInst as ImInst
import qualified Derive.C.Bali.Gender as Gender
import qualified Derive.C.Prelude.Note as Note
import qualified Derive.Call as Call
import qualified Derive.Call.Sub as Sub
import qualified Derive.Derive as Derive
import qualified Derive.Instrument.DUtil as DUtil

import qualified Synth.Sampler.Patch.Lib.Code as Code


code :: ImInst.Code
code = mconcat
    [ ImInst.null_call note
    ]

note :: Derive.Generator Derive.Note
note = DUtil.zero_duration "note"
    "When zero duration, and use-weak=t, use the `weak` call.\
    \ When `symbolic-pitch=t`, tell the samples to use pitch by name rather\
    \ than nn."
    (Sub.inverting $ \args -> transform $ Call.if_env "use-weak" (Just True)
        (Gender.weak_call args)
        (Call.multiply_dynamic 0.65 (Bali.reapply_mute args)))
    (Sub.inverting $ \args -> transform (note args))
    where
    note = Note.default_note Note.use_attributes
    transform = Code.withVariation
