-- Copyright 2014 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for scale tests.
module Derive.Scale.ScaleTest where
import qualified Data.List as List

import qualified Util.CallStack as CallStack
import qualified Util.Texts as Texts
import qualified Ui.UiTest as UiTest
import qualified Cmd.CmdTest as CmdTest
import qualified Derive.DeriveTest as DeriveTest
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Scale as Scale
import qualified Derive.Score as Score

import qualified Perform.Pitch as Pitch
import Global


key_environ :: Text -> Env.Environ
key_environ key = Env.insert_val EnvKey.key key mempty

get_scale :: CallStack.Stack => [Scale.Definition] -> Text -> Scale.Scale
get_scale scales scale_id =
    fromMaybe (error $ "no scale: " <> show scale_id) $
        List.find ((== Pitch.ScaleId scale_id) . Scale.scale_id)
            [scale | Scale.Simple scale <- scales]

input_to_note :: Scale.Scale -> Env.Environ
    -> (Pitch.Octave, Pitch.PitchClass, Pitch.Accidentals) -> Text
input_to_note scale env =
    either pretty Pitch.note_text
    . Scale.scale_input_to_note scale env
    . ascii_kbd

ascii_kbd :: (Pitch.Octave, Pitch.PitchClass, Pitch.Accidentals)
    -> Pitch.Input
ascii_kbd (oct, pc, accs) = CmdTest.ascii_kbd $ CmdTest.pitch oct pc accs

note_to_call :: Text -> Text -> [Text] -> ([Maybe Pitch.NoteNumber], [Text])
note_to_call scale title =
    DeriveTest.extract Score.initial_nn
    . DeriveTest.derive_tracks (Texts.join2 " | " ("scale=" <> scale) title)
    . UiTest.note_track1
