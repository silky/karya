-- Copyright 2016 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | The 'Note' type and support.
module Synth.Shared.Note where
import qualified Crypto.Hash.MD5 as MD5
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Base64.URL as Base64.URL
import qualified Data.ByteString.Char8 as ByteString.Char8
import qualified Data.ByteString.Lazy as ByteString.Lazy
import qualified Data.Map.Strict as Map

import qualified Util.Pretty as Pretty
import qualified Util.Serialize as Serialize
import           Util.Serialize (get, put)

import qualified Derive.Attrs as Attrs
import qualified Derive.ScoreT as ScoreT
import qualified Derive.Stack as Stack

import qualified Perform.Pitch as Pitch
import qualified Synth.Shared.Control as Control
import qualified Synth.Shared.Signal as Signal
import qualified Ui.Id as Id

import           Global
import           Synth.Types


-- | IR for im.  These are the inputs for im synthesizers.
data Note = Note {
    -- | Map this note to one of the synthesizer's patches.
    patch :: !PatchName
    -- | Unique name for this particular instantiation of the patch.
    , instrument :: !ScoreT.Instrument
    -- | Display render progress on this track.
    --
    -- Previously, I inferred the track from the instrument, but that runs into
    -- trouble when there isn't a 1:1 mapping from track to instrument.
    , trackId :: !(Maybe Id.TrackId)
    -- | Address this note to a particular element within the patch.  What it
    -- is depends on the instrument.  For instance, it might the a particular
    -- string on a pipa.  The difference from 'attributes' is that each element
    -- is mutually exclusive.
    , element :: !Element
    , start :: !RealTime
    , duration :: !RealTime
    -- | E.g. envelope, pitch, lpf.
    , controls :: !(Map Control.Control Signal.Signal)
    , attributes :: !Attrs.Attributes
    -- | The stack of the score event that generated this Note.  For errors.
    , stack :: Stack.Stack
    } deriving (Eq, Show)

type Element = Text

-- | Unique identifier for a patch.
type PatchName = Text

end :: Note -> RealTime
end n = start n + duration n

instance Serialize.Serialize Note where
    put (Note a b c d e f g h i) =
        put a *> put b *> put c *> put d *> put e *> put f *> put g *> put h
        *> put i
    get = Note <$> get <*> get <*> get <*> get <*> get <*> get <*> get <*> get
        <*> get

instance Pretty Note where
    format (Note patch inst trackId element start dur controls attrs stack) =
        Pretty.record "Note"
            [ ("patch", Pretty.format patch)
            , ("instrument", Pretty.format inst)
            , ("trackId", Pretty.format trackId)
            , ("element", Pretty.format element)
            , ("start", Pretty.format start)
            , ("duration", Pretty.format dur)
            , ("controls", Pretty.format controls)
            , ("attributes", Pretty.format attrs)
            , ("stack", Pretty.format stack)
            ]

-- | Make a Note for testing.
note :: PatchName -> ScoreT.Instrument -> RealTime -> RealTime -> Note
note patch instrument start duration = Note
    { patch = patch
    , instrument = instrument
    , trackId = Nothing
    , element = ""
    , start = start
    , duration = duration
    , controls = mempty
    , attributes = mempty
    , stack = Stack.empty
    }

testNote :: RealTime -> RealTime -> Note
testNote = note "patch" "inst"

initialPitch :: Note -> Maybe Pitch.NoteNumber
initialPitch note = if nn == Just 0 then Nothing else nn
    where nn = Pitch.nn <$> initial Control.pitch note
    -- If the patch said it supports pitch, Control.pitch will always be
    -- present even if that means it's empty.  That will show up as 0 pitch,
    -- so convert that back into Nothing.

controlAt :: RealTime -> Control.Control -> Note -> Maybe Signal.Y
controlAt t control = fmap (Signal.at t) . Map.lookup control . controls

initial :: Control.Control -> Note -> Maybe Signal.Y
initial control note = controlAt (start note) control note

initial0 :: Control.Control -> Note -> Signal.Y
initial0 control =  fromMaybe 0 . initial control

withControl :: Control.Control -> Signal.Signal -> Note -> Note
withControl control signal note =
    note { controls = Map.insert control signal (controls note) }

withPitch :: Pitch.NoteNumber -> Note -> Note
withPitch = withControl Control.pitch . Signal.constant . Pitch.nn_to_double

-- * serialize

serialize :: FilePath -> [Note] -> IO Bool
serialize = Serialize.serialize_rotate 4 notesMagic
    -- Save more rotations, sometimes I need to debug im errors by replaying
    -- multiple changes.

unserialize :: FilePath -> IO (Either Serialize.UnserializeError [Note])
unserialize  = Serialize.unserialize notesMagic

notesMagic :: Serialize.Magic [Note]
notesMagic = Serialize.Magic 'n' 'o' 't' 'e'


-- * hash

-- | The Hash is the MD5 digest of the note.
--
-- I used to use CRC32, but got a collision right away:
-- > 2861715819 & 157939100 = 1544801946
-- > 1257719070 & 3909935593 = 1544801946
newtype Hash = Hash ByteString.ByteString
    deriving (Show, Eq, Ord, Serialize.Serialize)

instance Pretty Hash where pretty = txt . encodeHash

hash :: Note -> Hash
hash note = hashBytes . Serialize.encode $ note { stack = Stack.empty }

hashBytes :: ByteString.Char8.ByteString -> Hash
hashBytes = Hash . MD5.hash

-- | Encode to a short string which I can stick in a filename.
encodeHash :: Hash -> String
encodeHash (Hash hash) = ByteString.Char8.unpack $ fingerprint hash

fingerprint :: ByteString.ByteString -> ByteString.ByteString
fingerprint = ByteString.Char8.dropWhileEnd (=='=') . Base64.URL.encode

instance Semigroup Hash where
    Hash h1 <> Hash h2
        | h1 == "" = Hash h2
        | h2 == "" = Hash h1
        | otherwise = Hash $ MD5.hashlazy $ ByteString.Lazy.fromChunks [h1, h2]

instance Monoid Hash where
    mempty = Hash ""
    mappend = (<>)
    mconcat [] = mempty
    -- It's less confusing when mconcat [x] == x.
    mconcat [x] = x
    mconcat xs =
        Hash . MD5.hashlazy . ByteString.Lazy.fromChunks . map unhash $ xs
        where unhash (Hash h) = h

fingerprintBytes :: ByteString.ByteString -> String
fingerprintBytes = ByteString.Char8.unpack . fingerprint . MD5.hash
