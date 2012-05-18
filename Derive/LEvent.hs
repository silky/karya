module Derive.LEvent where
import Prelude hiding (length, either)
import qualified Control.DeepSeq as DeepSeq
import qualified Data.List as List

import Util.Control
import qualified Util.Log as Log
import qualified Util.Pretty as Pretty
import Util.Pretty ((<+>))
import qualified Util.Seq as Seq
import qualified Util.SrcPos as SrcPos

import qualified Derive.Stack as Stack


-- * LEvent

data LEvent derived = Event !derived | Log !Log.Msg
    deriving (Read, Show)

instance Functor LEvent where
    fmap f (Event a) = Event (f a)
    fmap _ (Log a) = Log a

instance (Pretty.Pretty d) => Pretty.Pretty (LEvent d) where
    format (Log msg) = format_msg msg
    format (Event event) = Pretty.format event

format_msg :: Log.Msg -> Pretty.Doc
format_msg msg = Pretty.fsep
    [Pretty.text stars <+> Pretty.text srcpos <+> Pretty.format stack,
        Pretty.nest 2 $ Pretty.text (Log.msg_string msg)]
    where
    stars = replicate (fromEnum (Log.msg_prio msg)) '*'
    srcpos = maybe "" ((++": ") . SrcPos.show_srcpos . Just)
        (Log.msg_caller msg)
    stack = case Log.msg_stack msg of
        Nothing -> Pretty.text "[]"
        Just stack -> Stack.format_ui (Stack.from_strings stack)

event :: LEvent derived -> Maybe derived
event (Event d) = Just d
event _ = Nothing

is_event :: LEvent d -> Bool
is_event (Event _) = True
is_event _ = False

either :: (d -> a) -> (Log.Msg -> a) -> LEvent d -> a
either f1 _ (Event event) = f1 event
either _ f2 (Log log) = f2 log

events_of :: [LEvent d] -> [d]
events_of [] = []
events_of (Event e : rest) = e : events_of rest
events_of (Log _ : rest) = events_of rest

logs_of :: [LEvent d] -> [Log.Msg]
logs_of [] = []
logs_of (Event _ : rest) = logs_of rest
logs_of (Log log : rest) = log : logs_of rest

partition :: Stream (LEvent d) -> ([d], [Log.Msg])
partition = Seq.partition_either . map to_either
    where
    to_either (Event d) = Left d
    to_either (Log msg) = Right msg

map_state :: state -> (state -> a -> (b, state)) -> [LEvent a] -> [LEvent b]
map_state _ _ [] = []
map_state state f (Log log : rest) = Log log : map_state state f rest
map_state state f (Event event : rest) = Event event2 : map_state state2 f rest
    where (event2, state2) = f state event

instance (DeepSeq.NFData derived) => DeepSeq.NFData (LEvent derived) where
    rnf (Event event) = DeepSeq.rnf event
    rnf (Log msg) = DeepSeq.rnf msg


-- * stream

type Stream a = [a]

empty_stream :: Stream a
empty_stream = []

length :: Stream a -> Int
length = List.length

type LEvents d = Stream (LEvent d)

one :: a -> Stream a
one x = x `seq` [x]
