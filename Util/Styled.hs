-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | A simple Styled Text implementation.  There are a few others on hackage
-- (terminal-text, rainbow, ...), but they're all too complicated for me.
module Util.Styled (
    Styled
    , print, printLn
    , toByteString, toByteStrings
    , Color, black, red, green, yellow, blue, magenta, cyan, white
    , plain
    , bright
    , fgs, bgs, bolds, underlines
    , fg, bg, bold, underline
) where
import Prelude hiding (print)
import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.List as List
import qualified Data.String as String
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.Encoding as Encoding

import qualified System.Console.ANSI as ANSI

import qualified Util.Then as Then


data Styled = Branch Styled Styled | Styled !Style !Text
    deriving (Eq, Show)

instance Semigroup Styled where
    Styled _ t1 <> s2 | Text.null t1 = s2
    s1 <> Styled _ t2 | Text.null t2 = s1
    s1 <> s2 = Branch s1 s2

instance Monoid Styled where
    mempty = Styled mempty ""
    mappend = (<>)

instance String.IsString Styled where
    fromString = Styled mempty . String.fromString

class ToStyled a where toStyled :: a -> Styled
instance ToStyled Text where toStyled = Styled mempty
instance ToStyled Styled where toStyled = id

mapStyle :: (Style -> Style) -> Styled -> Styled
mapStyle f (Branch t1 t2) = Branch (mapStyle f t1) (mapStyle f t2)
mapStyle f (Styled style t) = Styled (f style) t

print :: Styled -> IO ()
print = mapM_ ByteString.putStr . toByteStrings

printLn :: Styled -> IO ()
printLn s = print (s <> "\n")

toByteString :: Styled -> ByteString
toByteString = mconcat . toByteStrings

toByteStrings :: Styled -> [ByteString]
toByteStrings = filter (/="") . concatMap render . toSGRs
    where
    render (sgrs, text) =
        [ if null sgrs then "" else ByteString.pack (ANSI.setSGRCode sgrs)
        , Encoding.encodeUtf8 text
        ]

-- | Render in order, but only emit escape codes if the Style changed.
toSGRs :: Styled -> [([ANSI.SGR], Text)]
toSGRs = Then.map render1 [([ANSI.Reset], "")] . zipPrev (mempty, "") . toList
    where
    render1 ((prevStyle, _), (style, text)) =
        (if prevStyle == style then [] else styleSGR style, text)
    zipPrev fst xs = zip (fst : xs) xs

toList :: Styled -> [(Style, Text)]
toList xs = go xs []
    where
    go (Branch as bs) xs = go as (go bs xs)
    go (Styled style text) xs = (style, text) : xs

styleSGR :: Style -> [ANSI.SGR]
styleSGR (Style fg bg bold underline) = ANSI.Reset : concat
    [ case fg of
        Nothing -> []
        Just (Color intensity color) ->
            [ANSI.SetColor ANSI.Foreground intensity color]
    , case bg of
        Nothing -> []
        Just (Color intensity color) ->
            [ANSI.SetColor ANSI.Background intensity color]
    , [ANSI.SetConsoleIntensity ANSI.BoldIntensity | bold]
    , [ANSI.SetUnderlining ANSI.SingleUnderline | underline]
    ]

data Style = Style {
    _foreground :: !(Maybe Color)
    , _background :: !(Maybe Color)
    , _bold :: !Bool
    , _underline :: !Bool
    } deriving (Eq, Show)

instance Semigroup Style where
    Style fg1 bg1 bold1 underline1 <> Style fg2 bg2 bold2 underline2 =
        Style (fg2 <|> fg1) (bg2 <|> bg1) -- reversed so right side overrides
            (bold1 || bold2) (underline1 || underline2)

instance Monoid Style where
    mempty = noStyle
    mappend = (<>)

noStyle :: Style
noStyle = Style
    { _foreground = Nothing
    , _background = Nothing
    , _bold = False
    , _underline = False
    }

data Color = Color !ANSI.ColorIntensity !ANSI.Color
    deriving (Eq, Show)

black, red, green, yellow, blue, magenta, cyan, white :: Color
(black, red, green, yellow, blue, magenta, cyan, white) =
    ( c ANSI.Black, c ANSI.Red, c ANSI.Green, c ANSI.Yellow, c ANSI.Blue
    , c ANSI.Magenta, c ANSI.Cyan, c ANSI.White
    )
    where c = Color ANSI.Dull

plain :: Text -> Styled
plain = Styled mempty

bright :: Color -> Color
bright (Color _ color) = Color ANSI.Vivid color

fgs, bgs :: Color -> Styled -> Styled
fgs color = mapStyle (\style -> style { _foreground = Just color })
bgs color = mapStyle (\style -> style { _background = Just color })

fg, bg :: ToStyled a => Color -> a -> Styled
fg color = fgs color . toStyled
bg color = bgs color . toStyled

bolds, underlines :: Styled -> Styled
bolds = mapStyle (\style -> style { _bold = True })
underlines = mapStyle (\style -> style { _underline = True })

bold, underline :: ToStyled a => a -> Styled
bold = bolds . toStyled
underline = underlines . toStyled

-- * Text-like functions

intercalate :: Styled -> [Styled] -> Styled
intercalate sep = mconcat . List.intersperse sep

-- t0 = printLn $ fgs (bright red) "hi" <> fgs red "there"
-- t1 = printLn $ bgs (bright red) "hi" <> bgs red "there"
-- t2 = printLn $ underlines "hi" <> " " <> bolds "there"
-- t3 = printLn $ underlines $ fgs (bright red) "hi" <> fgs red "there"
--
-- t_newline1 = printLn $ bgs cyan "hello\nthere"
-- t_newline2 = printLn $ bgs cyan "hello" <> "\n" <> bgs cyan "there"