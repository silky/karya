module Instrument.Parse_test where
-- import qualified Data.Word as Word
import Util.Test

import qualified Midi.Midi as Midi
import qualified Instrument.Parse as Parse
import qualified Perform.Midi.Instrument as Instrument


test_parse_file = do
    patches <- Parse.patch_file "synth" "Instrument/test_patch_file"
    let inits = map Instrument.patch_initialize patches
        init_msgs = [[m | Midi.ChannelMessage _ m <- msgs]
            | Instrument.InitializeMidi msgs <- inits]
    equal init_msgs
        [[Midi.ControlChange 0 0, Midi.ControlChange 32 0, Midi.ProgramChange 0]
        ,[Midi.ControlChange 0 0, Midi.ControlChange 32 0, Midi.ProgramChange 1]
        ,[Midi.ControlChange 0 0, Midi.ControlChange 32 1, Midi.ProgramChange 0]
        ,[Midi.ControlChange 0 0, Midi.ControlChange 32 1, Midi.ProgramChange 1]
        ]
    equal (map Instrument.patch_tags patches)
        (replicate 3 [("category", "boring")]
            ++ [[("category", "interesting")]])

test_parse_sysex = do
    let parse p s = case Parse.parse_sysex p "" s of
            Left err -> Left (show err)
            Right v -> Right v
    equal (parse s_parser sysex0) (Right [0, 0])

s_parser = do
    Parse.start_sysex 0x42
    bs <- Parse.to_eox
    Parse.end_sysex
    return bs

sysex0 = [0xf0, 0x42, 0, 0, 0xf7]

{-
sysex1 :: [Word.Word8]
sysex1 =
    [ 0xf0, 0x42, 0x30, 0x46, 0x40, 0x01, 0x00, 0x44, 0x61, 0x72, 0x6b, 0x20,
    0x46, 0x6f, 0x00, 0x72, 0x65, 0x73, 0x74, 0x20, 0x20, 0x20, 0x00, 0x20,
    0x20, 0x01, 0x00, 0x12, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2e,
    0x14, 0x3d, 0x00, 0x14, 0x34, 0x14, 0x35, 0x14, 0x00, 0x00, 0x00, 0x00,
    0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x34, 0x09, 0x63,
    0x20, 0x48, 0x00, 0x48, 0x2b, 0x14, 0x2f, 0x00, 0x00, 0x54, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x14, 0x63, 0x14, 0x63,
    0x14, 0x63, 0x00, 0x14, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x20, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x54, 0x22, 0x00, 0x63, 0x26, 0x34, 0x2f, 0x00,
    0x14, 0x00, 0x40, 0x00, 0x00, 0x3e, 0x00, 0x00, 0x0f, 0x47, 0x00, 0x0a,
    0x00, 0x00, 0x03, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x0b, 0x1a, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x03, 0x14, 0x13, 0x00, 0x34, 0x00, 0x00, 0x00, 0x17,
    0x63, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x7e, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0c,
    0x00, 0x00, 0x00, 0x0c, 0x01, 0x00, 0x00, 0x00, 0x3c, 0x32, 0x00, 0x32,
    0x06, 0x00, 0x16, 0x0a, 0x00, 0x00, 0x00, 0x01, 0x54, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x08, 0x02, 0x25, 0x01, 0x7c, 0x1a, 0x3f, 0x00, 0x00, 0x00,
    0x32, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x00, 0x00, 0x38, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c, 0x32, 0x32, 0x06,
    0x00, 0x16, 0x00, 0x0a, 0x00, 0x00, 0x03, 0x63, 0x01, 0x00, 0x40, 0x00,
    0x00, 0x2e, 0x07, 0x00, 0x04, 0x70, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0b,
    0x00, 0x1c, 0x00, 0x04, 0x03, 0x04, 0x01, 0x04, 0x12, 0x0f, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x02, 0x00, 0x76, 0x00, 0x3c, 0x32, 0x32, 0x06, 0x00, 0x00,
    0x16, 0x0a, 0x00, 0x00, 0x02, 0x01, 0x00, 0x63, 0x63, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x63, 0x00, 0x00, 0x63, 0x00, 0x00, 0x4b, 0x02, 0x13,
    0x66, 0x5c, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x45, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x0f, 0x32, 0x01, 0x63, 0x2c, 0x00, 0x3c, 0x3c, 0x00, 0x1f, 0x02,
    0x63, 0x08, 0x00, 0x00, 0x00, 0x00, 0x23, 0x00, 0x1e, 0x63, 0x00, 0x63,
    0x3c, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x63,
    0x31, 0x3c, 0x00, 0x3c, 0x00, 0x1f, 0x02, 0x63, 0x08, 0x00, 0x00, 0x00,
    0x00, 0x23, 0x17, 0x14, 0x63, 0x63, 0x00, 0x3c, 0x3c, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x3c, 0x3c, 0x00, 0x00, 0x08, 0x05,
    0x00, 0x17, 0x71, 0x63, 0x3c, 0x3c, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x26, 0x56, 0x14, 0x63, 0x14, 0x5f, 0x2b, 0x00, 0x00,
    0x00, 0x00, 0x2d, 0x00, 0x00, 0x0f, 0x01, 0x6d, 0x00, 0x00, 0x00, 0x40,
    0x08, 0x3d, 0x00, 0x7f, 0x64, 0x00, 0x00, 0x06, 0x6e, 0x00, 0x00, 0x19,
    0x00, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x63, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x04, 0x00,
    0x00, 0x16, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x1e, 0x3c, 0x14, 0x0f, 0x63, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x02, 0x01,
    0x5a, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00,
    0x32, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00,
    0x00, 0x64, 0x02, 0x00, 0x56, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x64,
    0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x08, 0x00, 0x64, 0x00, 0x57, 0x32,
    0x64, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x64, 0x20, 0x00,
    0x00, 0x00, 0x64, 0x00, 0x54, 0x00, 0x00, 0x19, 0x00, 0x00, 0x00, 0x64,
    0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x64, 0x00, 0x01, 0x60,
    0x00, 0x32, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00,
    0x00, 0x00, 0x00, 0x64, 0x00, 0xf7
    ]
-}

