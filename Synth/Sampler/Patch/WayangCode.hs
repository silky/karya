-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

module Synth.Sampler.Patch.WayangCode where
import qualified Util.Doc as Doc
import qualified Cmd.Instrument.Bali as Bali
import qualified Cmd.Instrument.ImInst as ImInst
import qualified Derive.Args as Args
import qualified Derive.C.Bali.Gender as Gender
import qualified Derive.C.Prelude.Note as Note
import qualified Derive.Call as Call
import qualified Derive.Call.Module as Module
import qualified Derive.Call.Sub as Sub
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Instrument.DUtil as DUtil
import qualified Derive.Sig as Sig
import qualified Derive.Typecheck as Typecheck

import qualified Perform.Pitch as Pitch

import Global


code :: ImInst.Code
code = mconcat
    [ ImInst.null_call note
    ]

note :: Derive.Generator Derive.Note
note = DUtil.zero_duration "note"
    "When zero duration, and use-weak=t, use the `weak` call.\
    \ When use-symbolic-pitch=t, tell the samples to use pitch by name rather\
    \ than nn."
    (Sub.inverting $ \args -> transform args $ if_env "use-weak" (Just True)
        (weak_call args)
        (Call.multiply_dynamic 0.65 (Bali.reapply_mute args)))
    (Sub.inverting $ \args -> transform args (note args))
    where
    note = Note.default_note Note.use_attributes
    transform args =
        when_env "use-symbolic-pitch" (Just True) (with_symbolic_pitch args)
            . with_variation

weak_call :: Derive.PassedArgs a -> Derive.NoteDeriver
weak_call args =
    Gender.weak (Sig.control "strength" 0.5) (Args.set_duration dur args)
    where dur = Args.next args - Args.start args

-- * shared

-- TODO these can be shared for all sampler patches

c_with_variation :: Derive.Transformer Derive.Note
c_with_variation = Derive.transformer Module.instrument "with-variation" mempty
    ("Set " <> Doc.pretty Controls.variation <> " randomly.") $
    Sig.call0t $ \_args -> with_variation

with_variation :: Derive.Deriver a -> Derive.Deriver a
with_variation deriver =
    ifM (Derive.is_control_set Controls.variation) deriver $ do
        n <- Call.random
        Derive.with_constant_control Controls.variation n deriver

with_symbolic_pitch :: Derive.PassedArgs x -> Derive.Deriver a
    -> Derive.Deriver a
with_symbolic_pitch args deriver = do
    note <- Call.get_symbolic_pitch =<< Args.real_start args
    Derive.with_val EnvKey.patch_element (Pitch.note_text note) deriver

-- * util

-- TODO move to Derive.Call?

if_env :: (Eq val, Typecheck.Typecheck val) => EnvKey.Key -> Maybe val
    -> Derive.Deriver a -> Derive.Deriver a -> Derive.Deriver a
if_env key val is_set not_set =
    ifM ((==val) <$> Derive.lookup_val key) is_set not_set

when_env :: (Eq val, Typecheck.Typecheck val) => EnvKey.Key -> Maybe val
    -> (Derive.Deriver a -> Derive.Deriver a)
    -> Derive.Deriver a -> Derive.Deriver a
when_env key val transformer deriver =
    if_env key val (transformer deriver) deriver