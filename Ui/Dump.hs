{- | Support for testing the GUI.

    The GUI exports a 'dump' function which emits a sexpr-like set of
    key-value pairs representing its current state.  Tests can then check this
    dump for certain expected values.

    Example input: @key1 val1 key2 (subkey1 subval1)@

    Flattened output: @[("key1", "val1"), ("key2.subkey1", "subval1")]@
-}
module Ui.Dump where
import qualified Data.Attoparsec.Char8 as A
import qualified Data.ByteString.Char8 as B

import Util.Control
import qualified Util.ParseBs as ParseBs
import qualified Util.Seq as Seq


type Dump = [(String, String)]

newtype Tree = Tree [(String, Val)] deriving (Show)
data Val = Val String | Sub Tree deriving (Show)

parse :: String -> Either String Dump
parse = fmap flatten . ParseBs.parse_all p_tree . B.pack

flatten :: Tree -> Dump
flatten (Tree pairs) = concatMap (go []) pairs
    where
    go prefix (key, Val val) = [(flatten_key (key:prefix), val)]
    go prefix (key, Sub (Tree subs)) = concatMap (go (key:prefix)) subs
    flatten_key = Seq.join "." . reverse

p_tree :: A.Parser Tree
p_tree = Tree <$> A.many p_pair

p_pair :: A.Parser (String, Val)
p_pair = (,) <$> ParseBs.lexeme p_word <*> ParseBs.lexeme (p_sub <|> p_val)

p_sub :: A.Parser Val
p_sub = Sub <$> ParseBs.between (A.char '(') (A.char ')') p_tree

p_val :: A.Parser Val
p_val = Val <$> p_word

p_word :: A.Parser String
p_word = B.unpack <$> (p_str <|> A.takeWhile1 (`notElem` " ()"))

p_str :: A.Parser B.ByteString
p_str = A.char '"' >> A.takeWhile (/='"') <* A.char '"'
