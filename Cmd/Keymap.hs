{-# LANGUAGE ViewPatterns #-}
{- | Support for efficient keymaps.

    The sequece of Cmds which return Continue or Done is flexible, but probably
    inefficient in the presence of hundreds of commands.  In addition, it can't
    warn about Cmds that respond to overlapping Msgs, i.e. respond to the same
    key.

    Keymaps provide an efficient way to respond to a useful subset of Msgs,
    i.e.  those which are considered 'key down' type msgs.  The exact
    definition is in 'Bindable'.
-}
module Cmd.Keymap where
import Control.Monad
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set

import qualified Util.Log as Log
import qualified Util.Seq as Seq

import qualified Midi.Midi as Midi
import qualified Ui.Key as Key
import qualified Ui.UiMsg as UiMsg

import qualified Cmd.Msg as Msg
import qualified Cmd.Cmd as Cmd


-- * building

-- | Simple cmd with no modifiers.
bind_key :: Key.Key -> String -> Cmd.CmdM m -> [Binding m]
bind_key = bind_mod []

bind_char :: Char -> String -> Cmd.CmdM m -> [Binding m]
bind_char char = bind_key (Key.KeyChar char)

-- | Bind a key with the given modifiers.
bind_mod :: [SimpleMod] -> Key.Key -> String -> Cmd.CmdM m -> [Binding m]
bind_mod smods bindable desc cmd = bind smods (Key bindable) desc (const cmd)

-- | 'bind_click' passes the Msg to the cmd, since mouse cmds are more likely
-- to want the msg to find out where the click was.  @clicks@ is 0 for a single
-- click, 1 for a double click, etc.
bind_click :: [SimpleMod] -> UiMsg.MouseButton -> Int -> String
    -> (Msg.Msg -> Cmd.CmdM m) -> [Binding m]
bind_click smods btn clicks desc cmd = bind smods (Click btn clicks) desc cmd

-- | A 'bind_drag' binds both the click and the drag.  It's conceivable to have
-- click and drag bound to different commands, but I don't have any yet.
bind_drag :: [SimpleMod] -> UiMsg.MouseButton -> String
    -> (Msg.Msg -> Cmd.CmdM m) -> [Binding m]
bind_drag smods btn desc cmd = bind smods (Click btn 0) desc cmd
    -- You can't have a drag without having that button down!
    ++ bind (Mouse btn : smods) (Drag btn) desc cmd

-- | Bind a key with the given modifiers.
bind :: [SimpleMod] -> Bindable -> String
    -> (Msg.Msg -> Cmd.CmdM m) -> [Binding m]
bind smods bindable desc cmd =
    [(key_spec mods bindable, cspec desc cmd) | mods <- all_mods]
    where
    all_mods = if null smods then [[]]
        else Seq.cartesian (map simple_to_mods smods)

-- ** CmdMap

-- | Create a CmdMap for efficient lookup and return warnings encountered
-- during construction.
make_cmd_map :: (Monad m) => [Binding m] -> (CmdMap m, [String])
make_cmd_map bindings = (Map.fromList bindings, warns)
    where
    warns = ["cmds overlap, picking the last one: " ++ Seq.join ", " cmds
        | cmds <- overlaps bindings]

-- | Create a cmd that dispatches into the given CmdMap.
--
-- To look up a cmd, the Msg is restricted to a 'Bindable'.  Then modifiers
-- that are allowed to overlap (such as keys) are stripped out of the mods and
-- the KeySpec is looked up in the keymap.
make_cmd :: (Monad m) => CmdMap m -> Msg.Msg -> Cmd.CmdM m
make_cmd cmd_map msg = do
    bindable <- Cmd.require (msg_to_bindable msg)
    mods <- mods_down
    case Map.lookup (KeySpec mods bindable) cmd_map of
        Nothing -> do
            -- Log.notice $ "no match for " ++ show (KeySpec mods bindable)
            --     ++ " in " ++ show (Map.keys cmd_map)
            return Cmd.Continue
        Just (CmdSpec name cmd) -> do
            Log.notice $ "running command " ++ show name
            cmd msg
            -- TODO move quit back into its own cmd and turn this on
            -- return Cmd.Done


-- | The Msg contains the low level key information, but most commands should
-- probably use these higher level modifiers.  That way left and right shifts
-- work the same, and cmds can use Command as customary on the Mac and Control
-- as customary on linux.
--
-- Things you have to inspect the Msg directly for:
--
-- - differentiate ShiftL and ShiftR
--
-- - chorded keys
--
-- - use option on the mac
data SimpleMod =
    Shift
    -- | Primary command key: command on mac, control on linux and windows
    -- This should be used for core and global commands.
    | PrimaryCommand
    -- | Secondary comamnd key: control or option on mac, alt on linux and
    -- windows.  I'm not sure what this should be used for, but it should be
    -- different than Mod1 stuff.  Maybe static config user-added commands.
    | SecondaryCommand
    -- | Having mouse here allows for mouse button chording.
    | Mouse UiMsg.MouseButton
    deriving (Eq, Ord, Show)

-- * implementation

-- | TODO This is a hardcoded mac layout, when I support other platforms
-- it'll have to be configurable.
simple_mod_map :: [(SimpleMod, [Key.Key])]
simple_mod_map =
    [ (Shift, [Key.ShiftL, Key.ShiftR])
    , (PrimaryCommand, [Key.MetaL, Key.MetaR])
    -- AltL is the mac's option key.
    , (SecondaryCommand, [Key.ControlL, Key.ControlR, Key.AltL, Key.AltR])
    ]

simple_to_mods :: SimpleMod -> [Cmd.Modifier]
simple_to_mods (Mouse btn) = [Cmd.MouseMod btn Nothing]
simple_to_mods simple = maybe [] (map Cmd.KeyMod) (lookup simple simple_mod_map)

-- ** Binding

type Binding m = (KeySpec, CmdSpec m)

data KeySpec = KeySpec (Set.Set Cmd.Modifier) Bindable deriving (Eq, Ord, Show)

key_spec :: [Cmd.Modifier] -> Bindable -> KeySpec
key_spec mods bindable = KeySpec (Set.fromList mods) bindable

-- | Pair a Cmd with a descriptive string that can be used for logging, undo,
-- etc.
data CmdSpec m = CmdSpec String (Msg.Msg -> Cmd.CmdM m)

cspec :: String -> (Msg.Msg -> Cmd.CmdM m) -> CmdSpec m
cspec = CmdSpec

-- | Make a CmdSpec for a CmdM, i.e. a Cmd that doesn't take a Msg.
cspec_ :: String -> Cmd.CmdM m -> CmdSpec m
cspec_ desc cmd = CmdSpec desc (const cmd)

-- ** CmdMap

type CmdMap m = Map.Map KeySpec (CmdSpec m)

overlaps :: [Binding m] -> [[String]]
overlaps bindings =
    [map cmd_name grp | grp <- Seq.group_with fst bindings, length grp > 1]
    where cmd_name (kspec, CmdSpec name _) = show kspec ++ ": " ++ name

-- | Return the mods currently down, stripping out non-modifier keys and notes,
-- so that overlapping keys will still match.  Mouse mods are not filtered, so
-- each mouse chord can be bound individually.
mods_down :: (Monad m) => Cmd.CmdT m (Set.Set Cmd.Modifier)
mods_down = do
    mods <- fmap (filter is_mod . Map.keys) Cmd.keys_down
    return $ Set.fromList mods
    where
    is_mod (Cmd.KeyMod key) = Set.member key Key.modifiers
    is_mod (Cmd.MidiMod _ _) = False
    is_mod (Cmd.MouseMod _ _) = True

msg_to_bindable :: Msg.Msg -> Maybe Bindable
msg_to_bindable msg = case msg of
    (Msg.key -> Just key) -> Just $ Key key
    (Msg.mouse -> Just mouse) -> case UiMsg.mouse_state mouse of
        UiMsg.MouseDown btn -> Just $ Click btn (UiMsg.mouse_clicks mouse)
        UiMsg.MouseDrag btn -> Just $ Drag btn
        _ -> Nothing
    (Msg.midi -> Just (Midi.ChannelMessage chan (Midi.NoteOn key _))) ->
        Just $ Note chan key
    _ -> Nothing

data Bindable = Key Key.Key
    | Click UiMsg.MouseButton Int
    | Drag UiMsg.MouseButton
    -- | Channel can be used to restrict bindings to a certain keyboard.  This
    -- should probably be something more abstract though, such as a device
    -- which can be set by the static config.
    | Note Midi.Channel Midi.Key
    deriving (Eq, Ord, Show, Read)


-- * key layout

-- This way I can set up the mapping relative to key position and have it come
-- out right for both qwerty and dvorak.  It makes the overlapping-ness of
-- non-mapped keys hard to predict though.

qwerty = "1234567890-="
    ++ "qwertyuiop[]\\"
    ++ "asdfghjkl;'"
    ++ "zxcvbnm,./"

dvorak = "1234567890-="
    ++ "',.pyfgcrl[]\\"
    ++ "aoeuidhtns/"
    ++ ";qjkxbmwvz"

qwerty_to_dvorak = Map.fromList (zip qwerty dvorak)
-- TODO presumably this should eventually be easier to change
hardcoded_kbd_layout :: Map.Map Char Char
hardcoded_kbd_layout = qwerty_to_dvorak
