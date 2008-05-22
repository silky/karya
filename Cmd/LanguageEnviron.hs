{- | Top-level module for the interpreter in Language.  It has to be
interpreted, so it should just put useful things into scope but not actually
define anything itself.  Those definitions go in LanguageCmds.
-}
module Cmd.LanguageEnviron where
import qualified Control.Monad.Identity as Identity

import Ui.Types

import qualified Util.Log as Log

import qualified Ui.Block as Block
import qualified Ui.Ruler as Ruler
import qualified Ui.Track as Track
import qualified Ui.Event as Event
import qualified Ui.State as State
import qualified Ui.Update as Update

import qualified Ui.TestSetup as TestSetup

import qualified Cmd.Cmd as Cmd
import Cmd.LanguageCmds


-- | Automatically added to language text by Language.mangle_text so it can
-- pretend to be running in the "real" CmdT.
run :: Cmd.CmdT Identity.Identity String -> State.State -> Cmd.State
    -> Cmd.CmdVal String
run cmd ui_state cmd_state =
    Identity.runIdentity (Cmd.run "" ui_state cmd_state cmd)
