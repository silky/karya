-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
-- | Tracklang parsers.  Many of the parsers in here should be inverses of
-- the 'ShowVal.ShowVal' class.
module Derive.Parse (
    parse_expr
    , parse_val, parse_attrs, parse_num, parse_call
    , lex1, lex, split_pipeline, join_pipeline
    , unparsed_call

    -- * parsers
    , lexeme, p_pipe, p_expr, p_pcontrol_ref, p_identifier, p_symbol
    -- * expand macros
    , expand_macros
    -- * for Parse.Ky
    , p_val
    , p_unparsed_expr, p_null_call, p_single_quote_string
    , p_equal_generic
    , empty_line, spaces
#ifdef TESTING
    , module Derive.Parse
#endif
) where
import           Prelude hiding (lex)
import qualified Control.Applicative as A (many)
import qualified Control.Applicative as Applicative
import qualified Data.Attoparsec.Text as A
import           Data.Attoparsec.Text ((<?>))
import qualified Data.HashMap.Strict as HashMap
import qualified Data.IORef as IORef
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text

import qualified System.IO.Unsafe as Unsafe

import qualified Util.Lists as Lists
import qualified Util.ParseText as ParseText

import qualified Derive.Attrs as Attrs
import qualified Derive.DeriveT as DeriveT
import qualified Derive.Expr as Expr
import qualified Derive.ScoreT as ScoreT
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Symbols as Symbols

import qualified Perform.Signal as Signal
import qualified Ui.Id as Id

import           Global


{- | Hacky memo table for 'parse_expr'.  There are many small exprs, and
    most of them are the the same, so we can save a lot of parsing time,
    and probably memory too since they will be interned.

    It would be more elegant and probably faster to put the memo directly in
    the Ui.Event, but this would introduce a giant dependency loop from
    low level Ui.Event up to DeriveT.Val.  At the least, it would go
    Ui.Event -> Events.Events -> Ui.State -> Ui.M -> Cmd.M, which means either
    a type parameter would have to propagate that far, or a SOURCE import would
    include that much.
-}
{-# NOINLINE memo_table #-}
memo_table :: IORef.IORef (HashMap Text (Either Text DeriveT.Expr))
memo_table = Unsafe.unsafePerformIO (IORef.newIORef mempty)

parse_expr :: Text -> Either Text DeriveT.Expr
parse_expr str
    -- micro-optimize, but probably irrelevant
    | Text.null str = Right $ Expr.call0 "" :| []
    | otherwise = case HashMap.lookup str table of
        Just expr -> expr
        Nothing -> write (HashMap.insert str expr) `seq` expr
            where expr = parse_expr_raw str
    where
    -- With concurrent access this can duplicate work, but since it's a cache
    -- that should be fine.  Also I don't do a strict modify, it probably makes
    -- no difference but the theory is to spend minimal time adding the entry,
    -- and the next call will force the thunk.
    table = Unsafe.unsafePerformIO $ IORef.readIORef memo_table
    write = Unsafe.unsafePerformIO . IORef.modifyIORef memo_table

{-# SCC parse_expr_raw #-}
parse_expr_raw :: Text -> Either Text DeriveT.Expr
parse_expr_raw = parse (p_expr True)

-- | Parse a single Val.
{-# SCC parse_val #-}
parse_val :: Text -> Either Text DeriveT.Val
parse_val = ParseText.parse1 (lexeme p_val)

-- | Parse attributes in the form +a+b.
parse_attrs :: String -> Either Text Attrs.Attributes
parse_attrs = parse p_attributes . Text.pack

-- | Parse a number or hex code, without a type suffix.
parse_num :: Text -> Either Text Signal.Y
parse_num = ParseText.parse1 (lexeme (p_hex <|> p_untyped_num))

-- | Extract only the call part of the text.
parse_call :: Text -> Maybe Text
parse_call text = case parse_expr_raw text of
    Right expr -> case NonEmpty.last expr of
        Expr.Call (Expr.Symbol call) _ -> Just call
    _ -> Nothing

parse :: A.Parser a -> Text -> Either Text a
parse p = ParseText.parse1 (spaces >> p)

-- * lex

-- | Lex out a single expression.  This isn't really a traditional lex, because
-- it will extract a whole parenthesized expression instead of a token.  Also,
-- this leaves on trailing whitespace, so you can concatenate the lexed out
-- words and get the original input back.
lex1 :: Text -> (Text, Text)
lex1 text = case parse ((,) <$> p_lex1 <*> A.takeWhile (const True)) text of
    Right ((), rest) ->
        (Text.take (Text.length text - Text.length rest) text, rest)
    Left _ -> (text, "")

-- | Like 'lex1', but get all of them.
lex :: Text -> [Text]
lex text
    | Text.null pre = []
    | Text.null post = [pre]
    | otherwise = pre : lex post
    where
    (pre, post) = lex1 text

-- | Take an expression and lex it into words, where each sublist corresponds
-- to one expression in the pipeline.  Like 'lex1', this corresponds to call
-- name and arguments, not tokens.  The final word could be a comment.
--
-- This preserves trailing spaces on the words, because track editors use that
-- to infer edits in progress.
split_pipeline :: Text -> [[Text]]
split_pipeline =
    Lists.mapTail (drop 1) . Lists.splitBefore ((=="|") . Text.strip) . lex

join_pipeline :: [[Text]] -> Text
join_pipeline =
    mconcat . List.intercalate [" | "] . map (Lists.mapLast Text.stripEnd)

-- | This returns () on success and the caller will see how many chars were
-- consumed.  Attoparsec doesn't keep track of byte position, and always
-- backtracks.  I think this means I can't reuse 'p_term'.
p_lex1 :: A.Parser ()
p_lex1 =
    (str <|> parens <|> (p_equal_operator *> pure ()) <|> unparsed <|> comment
            <|> word)
        *> (A.skipWhile is_whitespace)
    where
    str = p_single_quote_string >> return ()
    parens = do
        A.char '('
        A.many $ parens <|> str <|> (A.takeWhile1 content_char >> return ())
        A.char ')'
        return ()
    word = A.skipWhile (\c -> c /= '(' && is_word_char c)
    content_char c = c /= '(' && c /= ')' && c /= '\''
    unparsed = A.string (Expr.unsym unparsed_call)
        *> A.skipWhile (\c -> c /= '|' && c /= ')')
    comment = A.string "--" *> A.skipWhile (const True)

-- * expand macros

-- | Map the identifiers after a \"\@\" through the given function.  Used
-- to implement ID macros for the REPL.
--
-- A macro looks like \@valid-id-chars.
expand_macros :: (Text -> Text) -> Text -> Either Text Text
expand_macros replacement text
    | not $ "@" `Text.isInfixOf` text = Right text
    | otherwise = ParseText.parse1 (p_macros replacement) text

p_macros :: (Text -> Text) -> A.Parser Text
p_macros replace = do
    chunks <- A.many1 $ p_macro replace <|> p_chunk
        <|> (("\""<>) . (<>"\"") <$> p_hs_string)
    return $ mconcat chunks
    where
    p_chunk = A.takeWhile1 (\c -> c /= '"' && c /= '@')

p_macro :: (Text -> Text) -> A.Parser Text
p_macro replacement = do
    A.char '@'
    replacement <$> (unbackslash <$> bare_string)
    where
    -- Strip escaped quotes, because 'show' will turn it back into haskell
    -- and re-add them.  This will mess up all the other zillion backslash
    -- features in haskell strings, but I probably won't use those.  'p_str'
    -- would be simpler, but since it's for the REPL, I feel like haskell-ish
    -- strings will be less error-prone.
    unbackslash = txt . strip . untxt
        where
        strip ('\\':c:cs) = c : strip cs
        strip (c:cs) = c : strip cs
        strip [] = []
    bare_string = A.takeWhile1 (\c -> Id.is_id_char c || c == '/')

p_hs_string :: A.Parser Text
p_hs_string =
    ParseText.between (A.char '"') (A.char '"') $ mconcat <$> A.many chunk
    where
    chunk = (A.char '\\' >> Text.cons '\\' <$> A.take 1)
        <|> A.takeWhile1 (\c -> c /= '"' && c /= '\\')

-- * toplevel parsers

p_expr :: Bool -> A.Parser DeriveT.Expr
p_expr toplevel = do
    -- It definitely matches at least one, because p_null_call always matches.
    c : cs <- A.sepBy1 (p_toplevel_call toplevel) p_pipe
    return $ c :| cs

-- | A toplevel call has a few special syntactic forms, other than the plain
-- @call arg arg ...@ form parsed by 'p_call'.
p_toplevel_call :: Bool -> A.Parser DeriveT.Call
p_toplevel_call toplevel =
    p_unparsed_expr <|> p_equal <|> p_call toplevel <|> p_null_call

-- | Parse a 'unparsed_call'.
p_unparsed_expr :: A.Parser DeriveT.Call
p_unparsed_expr = do
    A.string $ Expr.unsym unparsed_call
    text <- A.takeWhile $ \c -> c /= '|' && c /= ')'
    let arg = Expr.Str $ Text.strip $ strip_comment text
    return $ Expr.Call unparsed_call [Expr.Literal $ DeriveT.VStr arg]
    where
    -- Normally comments are considered whitespace by 'spaces_to_eol'.  Normal
    -- tokenization is suppressed for 'unparsed_call' so that doesn't happen,
    -- but I still want to allow comments, for consistency.
    strip_comment = fst . Text.breakOn "--"

-- | This is a magic call name that suppresses normal parsing.  Instead, the
-- rest of the event expression is passed as a string.  The only characters
-- that can't be used are ) and |, so an unparsed call can still be included in
-- a sub expression.
unparsed_call :: Expr.Symbol
unparsed_call = "!"

p_pipe :: A.Parser ()
p_pipe = void $ lexeme (A.char '|')

p_equal :: A.Parser (Expr.Call DeriveT.Val)
p_equal = do
    (lhs, sym, rhs) <- p_equal_generic (lexeme p_term)
    return $ Expr.Call Symbols.equal $
        literal lhs : rhs ++ maybe [] (:[]) (literal <$> sym)
    where literal = Expr.Literal . DeriveT.VStr

p_equal_generic :: A.Parser a -> A.Parser (Expr.Str, Maybe Expr.Str, [a])
p_equal_generic rhs_term = do
    lhs <- (Expr.unstr <$> p_str) <|> (Expr.unsym <$> p_symbol True)
    spaces
    mb_sym <- p_equal_operator
    spaces
    rhs <- A.many1 rhs_term
    return (Expr.Str lhs, Expr.Str . Text.singleton <$> mb_sym, rhs)

p_equal_operator :: A.Parser (Maybe Char)
p_equal_operator = A.char '=' *> optional (A.satisfy (A.inClass merge_symbols))

-- | Valid symbols after =.  This should correspond to the keys in
-- Equal.symbol_to_merge.  It could have more symbols, but then that syntax
-- becomes unavailable.  E.g. previously % was in the list, but then
-- @x=%control@ has to be written @x = %control@.
merge_symbols :: [Char]
merge_symbols = "-+*@"

p_call :: Bool -> A.Parser (Expr.Call DeriveT.Val)
p_call toplevel = Expr.Call
    <$> lexeme (p_symbol toplevel)
    <*> lexeme (A.sepBy p_term spaces1)

p_null_call :: A.Parser (Expr.Call a)
p_null_call = return (Expr.Call "" []) <?> "null call"

-- | Any word in call position is considered a Str.  This means that
-- you can have calls like @4@ and @>@, which are useful names for notes or
-- ornaments.
p_symbol :: Bool -- ^ A call at the top level can allow a ).
    -> A.Parser Expr.Symbol
p_symbol toplevel = Expr.Symbol <$> p_word toplevel

p_term :: A.Parser (Expr.Term DeriveT.Val)
p_term = Expr.Literal <$> p_val <|> Expr.ValCall <$> p_sub_call
    <?> "term"

p_sub_call :: A.Parser (Expr.Call DeriveT.Val)
p_sub_call = ParseText.between (A.char '(') (A.char ')') (p_call False)

p_val :: A.Parser DeriveT.Val
p_val =
    DeriveT.VAttributes <$> p_attributes
    <|> DeriveT.num <$> p_hex
    <|> DeriveT.VSignal . fmap Signal.constant <$> p_num
    <|> DeriveT.VStr <$> p_str
    <|> DeriveT.VControlRef <$> p_control_ref
    <|> DeriveT.VPControlRef <$> p_pcontrol_ref
    <|> DeriveT.VQuoted <$> p_quoted
    <|> (A.char '_' >> return DeriveT.VNotGiven)
    <|> (A.char ';' >> return DeriveT.VSeparator)
    <|> DeriveT.VStr <$> p_unquoted_str

p_num :: A.Parser (ScoreT.Typed Signal.Y)
p_num = do
    num <- p_untyped_num
    let suffix (typ, suf) = A.string suf >> return typ
    typ <- A.choice $ map suffix codes
    return $ ScoreT.Typed typ num
    where
    codes = zip ScoreT.all_types $ map ScoreT.type_to_code ScoreT.all_types

p_untyped_num :: A.Parser Signal.Y
p_untyped_num = p_ratio <|> ParseText.p_float
    -- It may seem as if this should include p_hex, but I don't want it
    -- for p_num, because none of the type codes make sense for a 0-1
    -- normalized value.

p_ratio :: A.Parser Signal.Y
p_ratio = do
    sign <- A.option '+' (A.satisfy (\c -> c == '+' || c == '-'))
    num <- ParseText.p_nat
    A.char '/'
    denom <- ParseText.p_nat
    return $ (if sign == '-' then -1 else 1)
        * fromIntegral num / fromIntegral denom

-- | Parse numbers of the form @`0x`00@ or @0x00@, with an optional @-@ prefix
-- for negation.
p_hex :: A.Parser Signal.Y
p_hex = do
    sign <- A.option 1 (A.char '-' >> return (-1))
    A.string ShowVal.hex_prefix <|> A.string "0x"
    let higit c = '0' <= c && c <= '9' || 'a' <= c && c <= 'f'
    c1 <- A.satisfy higit
    c2 <- A.satisfy higit
    return $ fromIntegral (parse_hex c1 c2) / 0xff * sign

parse_hex :: Char -> Char -> Int
parse_hex c1 c2 = higit c1 * 16 + higit c2
    where
    higit c
        | '0' <= c && c <= '9' = fromEnum c - fromEnum '0'
        | otherwise = fromEnum c - fromEnum 'a' + 10

-- | A string is anything between single quotes.  A single quote itself is
-- represented by two single quotes in a row.
p_str :: A.Parser Expr.Str
p_str = Expr.Str <$> p_single_quote_string

p_single_quote_string :: A.Parser Text
p_single_quote_string = do
    chunks <- A.many1 $
        ParseText.between (A.char '\'') (A.char '\'') (A.takeTill (=='\''))
    return $ Text.intercalate "'" chunks

-- There's no particular reason to restrict attrs to idents, but this will
-- force some standardization on the names.
p_attributes :: A.Parser Attrs.Attributes
p_attributes = A.char '+'
    *> (Attrs.attrs <$> A.sepBy (p_identifier False "+") (A.char '+'))

p_control_ref :: A.Parser DeriveT.ControlRef
p_control_ref = do
    A.char '%'
    control <- ScoreT.unchecked_control <$> A.option "" (p_identifier False ",")
    deflt <- ParseText.optional (A.char ',' >> p_num)
    return $ DeriveT.Ref control (fmap Signal.constant <$> deflt)
    <?> "control"

-- | Unlike 'p_control_ref', this doesn't parse a comma and a default value,
-- because pitches don't have literals.  Instead, use the @#@ val call.
p_pcontrol_ref :: A.Parser DeriveT.PControlRef
p_pcontrol_ref = DeriveT.Ref <$> p_pcontrol <*> pure Nothing
    where
    p_pcontrol = do
        A.char '#'
        ScoreT.unchecked_pcontrol <$> p_identifier True ""
        <?> "pitch control"

p_quoted :: A.Parser DeriveT.Quoted
p_quoted = ParseText.between "\"(" ")" (DeriveT.Quoted <$> p_expr False)

-- | Symbols can have anything in them but they have to start with a letter.
-- This means special literals can start with wacky characters and not be
-- ambiguous.
--
-- This should be a superset of what 'p_identifier' will accept, so if IDs use
-- 'p_identifier' and 'Id.valid_symbol', they will also be parseable without
-- quotes.
p_unquoted_str :: A.Parser Expr.Str
p_unquoted_str = do
    sym <- Text.cons
        <$> A.satisfy ShowVal.is_unquoted_head
        <*> A.takeWhile is_word_char
    -- If I have an unbalanced quote, it may parse as an unquoted string with
    -- a quote in it, which is confusing.  So let's outlaw that.
    when ("'" `Text.isInfixOf` sym) $
        fail $ "quote in unquoted string: " <> show sym
    return $ Expr.Str sym

-- | Identifiers are somewhat more strict than usual.  They must be lowercase,
-- and the only non-letter allowed is hyphen.  This means words must be
-- separated with hyphens, and leaves me free to give special meanings to
-- underscores or caps if I want.
--
-- @until@ gives additional chars that stop parsing, for idents that are
-- embedded in another lexeme.
p_identifier :: Bool -> String -> A.Parser Text
p_identifier null_ok until = do
    -- TODO attoparsec docs say it's faster to do the check manually, profile
    -- and see if it makes a difference.
    ident <- (if null_ok then A.takeWhile else A.takeWhile1)
        -- (A.notInClass (until ++ " \n\t|=)")) -- buggy?
        (\c -> not $ c `elem` until || c == ' ' || c == '\n' || c == '\t'
            || c == '|' || c == '=' || c == ')')
        -- Newlines and tabs are forbidden from track and block titles and
        -- events, but can occur in ky files.
    -- This forces identifiers to be separated with spaces, except with | and
    -- =.  Otherwise @sym>inst@ is parsed as a call @sym >inst@, which I don't
    -- want to support.
    unless ((null_ok && Text.null ident) || Id.valid_symbol ident) $
        fail $ "invalid chars in identifier, expected "
            <> untxt Id.symbol_description <> ": " <> show ident
    return ident

p_word :: Bool -> A.Parser Text
p_word toplevel =
    A.takeWhile1 (if toplevel then is_toplevel_word_char else is_word_char)

-- | A word is as permissive as possible, and is terminated by whitespace.
-- That's because this determines how calls are allowed to be named, and for
-- expressiveness it's nice to use symbols.  For example, the slur call is just
-- @(@.
--
-- At the toplevel, any character is allowed except @=@, which lets me write
-- 'p_equal' expressions without spaces.  In sub calls, @)@ is not allowed,
-- because then I couldn't tell where the sub call expression ends, e.g. @())@.
-- However, @(()@ is fine, even though it looks weird.
--
-- I could get rid of the toplevel distinction by not allowing ) in calls
-- even at the toplevel, but I have @ly-(@ and @ly-)@ calls and I kind of like
-- how those look.  I guess it's a crummy justification, but no need to change
-- it unless toplevel gives more more trouble.
is_toplevel_word_char :: Char -> Bool
is_toplevel_word_char c = ShowVal.is_unquoted_body c
    && c /= ';' -- This is so the ; separator can appear anywhere.
    -- TODO remove it when I remove VSeparator

-- | Anything except whitespace, "=);"
is_word_char :: Char -> Bool
is_word_char c = is_toplevel_word_char c && c /= ')'

lexeme :: A.Parser a -> A.Parser a
lexeme = (<* spaces)

-- | Skip spaces, including a newline as long as the next line, skipping empty
-- lines, is indented.
spaces :: A.Parser ()
spaces = do
    spaces_to_eol
    A.option () $ do
        A.skip (=='\n')
        A.skipMany empty_line
        -- The next non-empty line has to be indented.
        A.skip is_whitespace
        A.skipWhile is_whitespace

-- | Like 'spaces', but require a space at the beginning.
spaces1 :: A.Parser ()
spaces1 = A.char ' ' *> spaces

empty_line :: A.Parser ()
empty_line = spaces_to_eol >> A.skip (=='\n')

spaces_to_eol :: A.Parser ()
spaces_to_eol = do
    A.skipWhile is_whitespace
    comment <- A.option "" (A.string "--")
    unless (Text.null comment) $
        A.skipWhile (\c -> c /= '\n')

is_whitespace :: Char -> Bool
is_whitespace c = c == ' ' || c == '\t'

optional :: Applicative.Alternative f => f a -> f (Maybe a)
optional = A.option Nothing . fmap Just
