-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
-- | Convert realized 'S.Flat' output to text for the terminal.
module Solkattu.Format.Terminal (
    renderAll, printInstrument, printKonnakol, printBol
    , Config(..), defaultConfig
    , konnakolConfig, bolConfig
    , formatInstrument
#ifdef TESTING
    , module Solkattu.Format.Terminal
#endif
) where
import qualified Data.Either as Either
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text.IO

import qualified Util.Lists as Lists
import qualified Util.Num as Num
import qualified Util.Styled as Styled

import qualified Solkattu.Format.Format as Format
import qualified Solkattu.Korvai as Korvai
import qualified Solkattu.Realize as Realize
import qualified Solkattu.S as S
import qualified Solkattu.Solkattu as Solkattu
import qualified Solkattu.Tags as Tags
import qualified Solkattu.Tala as Tala
import qualified Solkattu.Talas as Talas

import           Global


type Error = Text

data Config = Config {
    -- | Show the ruler on multiples of this line as a reminder.  The ruler is
    -- always shown if it changes.  It should be a multiple of 2 to avoid
    -- getting the second half of a talam in case it's split in half.
    _rulerEach :: !Int
    , _terminalWidth :: !Int
    -- | Normally 'format' tries to figure out a with for each stroke according
    -- to what will fit on the screen.  But it assumes notation is always at
    -- most one character per time unit.  This hardcodes the width for e.g.
    -- konnakol, where a sollu like `thom` can be 4 characters wide.
    , _overrideStrokeWidth :: !(Maybe Int)
    , _abstraction :: !Format.Abstraction
    } deriving (Eq, Show)

defaultConfig :: Config
defaultConfig = Config
    { _rulerEach = 4
    , _terminalWidth = 78
    , _overrideStrokeWidth = Nothing
    , _abstraction = Format.defaultAbstraction
    }

konnakolConfig :: Config
konnakolConfig = defaultConfig
    { _terminalWidth = 100
    , _overrideStrokeWidth = Just 3
    }

bolConfig :: Config
bolConfig = defaultConfig
    { _terminalWidth = 100
    -- 3 means dha and taa will fit, but it leads to excessively wide display.
    -- In practice dha often has a rest afterwards anyway.
    , _overrideStrokeWidth = Just 2
    }

-- * write

-- | Render all instrument realizations.
renderAll :: Format.Abstraction -> Korvai.Score -> [Text]
renderAll abstraction score = concatMap write1 $ Format.scoreInstruments score
    where
    write1 (Korvai.GInstrument inst) =
        Korvai.instrumentName inst <> ":"
        : fst (formatScore (config { _abstraction = abstraction }) inst Just
            score)
        where
        config = case inst of
            Korvai.IKonnakol -> konnakolConfig
            Korvai.IBol -> bolConfig
            _ -> defaultConfig

-- * format

printInstrument :: (Solkattu.Notation stroke, Ord stroke)
    => Korvai.Instrument stroke -> Format.Abstraction -> Korvai.Korvai
    -> IO ()
printInstrument instrument abstraction =
    mapM_ Text.IO.putStrLn . fst
    . formatInstrument (defaultConfig { _abstraction = abstraction })
        instrument Just

printKonnakol :: Config -> Korvai.Korvai -> IO ()
printKonnakol config =
    mapM_ Text.IO.putStrLn . fst
        . formatInstrument config Korvai.IKonnakol Just

printBol :: Config -> Korvai.Korvai -> IO ()
printBol config =
    mapM_ Text.IO.putStrLn . fst . formatInstrument config Korvai.IBol Just

formatScore
    :: (Solkattu.Notation stroke1, Solkattu.Notation stroke2, Ord stroke1)
    => Config
    -> Korvai.Instrument stroke1
    -> (Realize.Stroke stroke1 -> Maybe (Realize.Stroke stroke2))
    -> Korvai.Score -> ([Text], Bool)
    -- ^ (lines, hadError)
formatScore config instrument postproc = \case
    Korvai.Single korvai -> formatK korvai
    Korvai.Tani _ parts -> (concat lines, or errors)
        where (lines, errors) = unzip $ map format parts
    where
    format (Korvai.Comment cmt) = ([cmt], False)
    format (Korvai.K korvai) = formatK korvai
    formatK = formatInstrument config instrument postproc

formatInstrument
    :: (Solkattu.Notation stroke1, Solkattu.Notation stroke2, Ord stroke1)
    => Config
    -> Korvai.Instrument stroke1
    -> (Realize.Stroke stroke1 -> Maybe (Realize.Stroke stroke2))
    -- ^ postproc used to split wadon/lanang
    -> Korvai.Korvai
    -> ([Text], Bool) -- ^ (lines, hadError)
formatInstrument config instrument postproc korvai =
    formatResults config (Korvai.korvaiTala korvai) $ zip (korvaiTags korvai) $
        map (fmap (first (Korvai.mapStrokeRest postproc))) $
        Format.convertGroups $
        Korvai.realize instrument korvai

korvaiTags :: Korvai.Korvai -> [Tags.Tags]
korvaiTags = map Korvai.sectionTags . Korvai.genericSections

formatResults :: Solkattu.Notation stroke => Config -> Talas.Tala
    -> [ ( Tags.Tags
         , Either Error ([Format.Flat stroke], [Realize.Warning])
         )
       ]
    -> ([Text], Bool)
formatResults config tala results =
    ( concat . snd . List.mapAccumL show1 (Nothing, 0) . zip [0..] $ results
    , any (Either.isLeft . snd) results
    )
    where
    show1 _ (_section, (_, Left err)) =
        ((Nothing, 0), [Text.replicate leader " " <> "ERROR:\n" <> err])
    show1 prevRuler (section, (tags, Right (notes, warnings))) =
        ( nextRuler
        -- Use an empty section with commentS to describe what to play.
        , if null notes
            then (:[]) $ sectionNumber False section
                <> maybe "empty" Text.unwords
                    (Map.lookup Tags.comment (Tags.untags tags))
            else sectionFmt section tags lines
                ++ map (showWarning strokeWidth) warnings
        )
        where
        (strokeWidth, (nextRuler, lines)) = format config prevRuler tala notes
    showWarning _ (Realize.Warning Nothing msg) = msg
    showWarning strokeWidth (Realize.Warning (Just i) msg) =
        Text.replicate (leader + strokeWidth * i) " " <> "^ " <> msg
        -- TODO the ^ only lines up if there is only one line.  Otherwise
        -- I have to divMod i by strokes per line, and use that to insert
        -- in the formatted output
    -- If I want to normalize speed across all sections, then this is the place
    -- to get it.  I originally tried this, but from looking at the results I
    -- think I like when the notation can get more compact.
    -- toSpeed = maximum $ 0 : map S.maxSpeed (mapMaybe notesOf results)
    -- notesOf (_, Right (notes, _)) = Just notes
    -- notesOf _ = Nothing
    sectionFmt section tags =
        (if Text.null tagsText then id
            else Lists.mapLast (<> "   " <> tagsText))
        . snd . List.mapAccumL (addHeader tags section) False
        . map (second (Text.strip . Styled.toText))
        where
        tagsText = Format.showTags tags
    addHeader tags section showedNumber (AvartanamStart, line) =
        ( True
        , (if not showedNumber then sectionNumber (isEnding tags) section
            else Text.justifyRight leader ' ' "> ") <> line
        )
    addHeader _ _ showedNumber (_, line) =
        (showedNumber, Text.replicate leader " " <> line)
    sectionNumber isEnding section = Styled.toText $
        Styled.bg (Styled.bright color) $
        Text.justifyLeft leader ' ' (showt section <> ":")
        where
        -- Highlight endings specially, seems to be a useful landmark.
        color = if isEnding then Styled.cyan else Styled.yellow
    leader = 4
    isEnding = (== Just [Tags.ending]) . Map.lookup Tags.type_ . Tags.untags


-- * implementation

-- | Keep state about the last ruler across calls to 'format', so I can
-- suppress unneeded ones.  (prevRuler, lineNumber)
type PrevRuler = (Maybe Format.Ruler, Int)

type Line = [(S.State, Symbol)]

data LineType = Ruler | AvartanamStart | AvartanamContinue
    deriving (Eq, Show)

-- | Format the notes according to the tala.
--
-- The line breaking for rulers is a bit weird in that if the line is broken,
-- I only emit the first part of the ruler.  Otherwise I'd have to have
-- a multiple line ruler too, which might be too much clutter.  I'll have to
-- see how it works out in practice.
format :: Solkattu.Notation stroke => Config -> PrevRuler -> Talas.Tala
    -> [Format.Flat stroke] -> (Int, (PrevRuler, [(LineType, Styled.Styled)]))
format config prevRuler tala notes =
    (strokeWidth,) $
    second (concatMap formatAvartanam) $
    Format.pairWithRuler (_rulerEach config) prevRuler tala strokeWidth
        avartanamLines
    where
    formatAvartanam = concatMap formatRulerLine
    formatRulerLine (mbRuler, line) = concat
        [ case mbRuler of
            Nothing -> []
            Just ruler -> [(Ruler, formatRuler strokeWidth ruler)]
        , [(if isFirst then AvartanamStart else AvartanamContinue,
            formatLine (map snd line))]
        ]
        where
        isFirst = maybe True ((==0) . S.stateMatraPosition . fst)
            (Lists.head line)

    avartanamLines :: [[Line]] -- [avartanam] [[line]] [[[sym]]]
    (avartanamLines, strokeWidth) = case _overrideStrokeWidth config of
        Just n -> (fmt n width tala notes, n)
        Nothing -> case fmt 1 width tala notes of
            [line] : _ | lineWidth line <= width `div` 2 ->
                (fmt 2 width tala notes, 2)
            result -> (result, 1)
        where fmt = formatLines (_abstraction config)
    formatLine :: [Symbol] -> Styled.Styled
    formatLine = mconcat . map formatSymbol
    width = _terminalWidth config

lineWidth :: Line -> Int
lineWidth = Num.sum . map (symLength . snd)

formatRuler :: Int -> Format.Ruler -> Styled.Styled
formatRuler strokeWidth =
    Styled.bg (Styled.bright Styled.white)
        . mconcat . snd . List.mapAccumL render 0
    where
    render debt (mark, spaces) =
        ( max 0 (-append) -- debt is how many spaces I'm behind
        , mark <> Text.replicate append " "
        )
        where
        append = spaces * strokeWidth - Text.length mark - debt

-- | Replace two rests starting on an even note, with a Realize.doubleRest.
-- This is an elementary form of rhythmic spelling.
--
-- But if strokeWidth=1, then replace replace odd _ with ' ', to avoid clutter.
spellRests :: Int -> [Symbol] -> [Symbol]
spellRests strokeWidth
    | strokeWidth == 1 = map thin . zip [0..]
    | otherwise = map set . zip [0..] . Lists.zipNeighbors
    where
    thin (col, sym)
        | isRest sym && odd col = sym { _text = " " }
        | otherwise = sym
    set (col, (prev, sym, next))
        | not (isRest sym) = sym
        | even col && maybe False isRest next = sym
            { _text = Realize.justifyLeft (symLength sym) ' ' double }
        | odd col && maybe False isRest prev = sym
            { _text = Text.replicate (symLength sym) " " }
        | otherwise = sym
    double = Text.singleton Realize.doubleRest

-- This should be (== Space Rest), but I have to 'makeSymbols' first to break
-- lines.
isRest :: Symbol -> Bool
isRest = (=="_") . Text.strip . _text

-- | Break into [avartanam], where avartanam = [line].
formatLines :: Solkattu.Notation stroke => Format.Abstraction -> Int
    -> Int -> Talas.Tala -> [Format.Flat stroke] -> [[[(S.State, Symbol)]]]
formatLines abstraction strokeWidth width tala notes =
    map (map (Format.mapSnd (spellRests strokeWidth)))
        . Format.formatFinalAvartanam isRest _isOverlappingSymbol
        . map (breakLine width)
        . Format.breakAvartanams
        . overlapSymbols strokeWidth
        . concatMap (makeSymbols strokeWidth tala angas)
        . Format.makeGroupsAbstract abstraction
        . Format.normalizeSpeed toSpeed (Talas.aksharas tala)
        $ notes
    where
    angas = Talas.angaSet tala
    toSpeed = S.maxSpeed notes

-- | Long names will overlap following _isSustain ones.
overlapSymbols :: Int -> [(a, Symbol)] -> [(a, Symbol)]
overlapSymbols strokeWidth = snd . mapAccumLSnd combine ("", Nothing)
    where
    combine (overlap, overlapSym) sym
        | _isSustain sym = if Text.null overlap
            then (("", Nothing), sym)
            else let (pre, post) = textSplitAt strokeWidth overlap
                in ((post, overlapSym), replace pre overlapSym sym)
        | otherwise =
            let (pre, post) = textSplitAt strokeWidth (_text sym)
            in ((post, Just sym), sym { _text = pre })
    replace prefix mbOverlapSym sym = case mbOverlapSym of
        Nothing -> sym { _text = newText }
        Just overlapSym -> sym
            { _text = newText
            , _highlight = _highlight overlapSym
            , _emphasize = _emphasize overlapSym
            , _isOverlappingSymbol = True
            }
        where
        newText = prefix
            <> snd (textSplitAt (Realize.textLength prefix) (_text sym))

makeSymbols :: Solkattu.Notation stroke => Int -> Talas.Tala -> Set Tala.Akshara
    -> Format.NormalizedFlat stroke -> [(S.State, Symbol)]
makeSymbols strokeWidth tala angas = go
    where
    go (S.FNote _ (state, note)) =
        (:[]) $ (state,) $ makeSymbol state $ case note of
            S.Attack a ->
                ( False
                , style
                , Realize.justifyLeft strokeWidth (Solkattu.extension a)
                    notation
                )
                where (style, notation) = Solkattu.notation a
            S.Sustain a ->
                ( True
                , mempty
                , Text.replicate strokeWidth
                    (Text.singleton (Solkattu.extension a))
                )
            S.Rest -> (True, mempty, Realize.justifyLeft strokeWidth ' ' "_")
    go (S.FGroup _ group children) = modify (concatMap go children)
        where
        modify = case Solkattu._type group of
            Solkattu.GGroup -> groupc
            Solkattu.GReductionT -> groupc
            Solkattu.GFiller -> setHighlights2 (gray 0.85)
            Solkattu.GPattern -> patternc
            Solkattu.GExplicitPattern -> patternc
            Solkattu.GSarva -> setHighlights2 (Styled.rgb 0.5 0.65 0.5)
            -- This shouldn't be here, so make it red.
            Solkattu.GCheckDuration {} -> setHighlights2 (Styled.rgb 0.75 0 0)
    groupc = setHighlights (Styled.rgb 0.5 0.75 0.5) (gray 0.75)
    patternc = setHighlights
        (Styled.rgb 0.55 0.55 0.7) (Styled.rgb 0.65 0.65 0.8)
    gray n = Styled.rgb n n n
    setHighlights2 color = setHighlights color color
    setHighlights startColor color =
        Lists.mapLast (second (set Format.EndHighlight color))
        . Lists.mapHeadTail
            (second (set Format.StartHighlight startColor))
            (second (set Format.Highlight color))
        where
        set h color sym = case _highlight sym of
            Nothing -> sym { _highlight = Just (h, color) }
            -- Don't set highlight if it's already set.  This means the
            -- innermost group's highlight will show, which seems to be most
            -- useful in practice.
            Just _ -> sym
    makeSymbol state (isSustain, style, text) = Symbol
        { _text = text
        , _style = style
        , _isSustain = isSustain
        , _emphasize = shouldEmphasize tala angas state
        , _highlight = Nothing
        , _isOverlappingSymbol = False
        }

-- | Chapu talams are generally fast, so only emphasize the angas.  Other talas
-- are slower, and without such a strong beat, so emphasize every akshara.
shouldEmphasize :: Talas.Tala -> Set Tala.Akshara -> S.State -> Bool
shouldEmphasize tala angas state
    | isChapu = Format.onAnga angas state
    | otherwise = Format.onAkshara state
    where
    isChapu = case tala of
        Talas.Carnatic tala -> case Tala._angas tala of
            Tala.Wave _ : _ -> True
            Tala.Clap _ : _ -> True
            _ -> False
        Talas.Hindustani _ -> False -- TODO there are fast tals also

-- | If the text goes over the width, break at the middle akshara, or the
-- last one before the width if there isn't a middle.
breakLine :: Int -> [(S.State, Symbol)] -> [[(S.State, Symbol)]]
breakLine maxWidth notes
    | width <= maxWidth = [notes]
    | even aksharas = breakAt (aksharas `div` 2) notes
    | otherwise = breakBefore maxWidth notes
    where
    width = Num.sum $ map (symLength . snd) notes
    aksharas = Lists.count (Format.onAkshara . fst) notes
    breakAt akshara = pairToList . break ((==akshara) . S.stateAkshara . fst)
    pairToList (a, b) = [a, b]

-- | Yet another word-breaking algorithm.  I must have 3 or 4 of these by now.
breakBefore :: Int -> [(S.State, Symbol)] -> [[(S.State, Symbol)]]
breakBefore maxWidth =
    go . dropWhile null . Lists.splitBefore (Format.onAkshara . fst)
    where
    go aksharas =
        case breakFst (>maxWidth) (zip (runningWidth aksharas) aksharas) of
            ([], []) -> []
            (pre, []) -> [concat pre]
            ([], post:posts) -> post : go posts
            (pre, post) -> concat pre : go post
    -- drop 1 so it's the width at the end of each section.
    runningWidth = drop 1 . scanl (+) 0 . map (Num.sum . map (symLength . snd))

-- ** formatting

data Symbol = Symbol {
    _text :: !Text
    , _style :: !Styled.Style
    -- | If this was from a S.Sustain, which comes from S.hasSustain.  This
    -- differentiates a stroke followed by rests from a sequence that continues
    -- over a time range.
    , _isSustain :: !Bool
    , _emphasize :: !Bool
    , _highlight :: !(Maybe (Format.Highlight, Styled.Color))
    -- | True if this is the non-first part of a Symbol split via
    -- overlapSymbols.  This is so that Format.formatFinalAvartanam can
    -- consider it a single symbol.
    , _isOverlappingSymbol :: !Bool
    } deriving (Eq, Show)

instance Pretty Symbol where
    pretty (Symbol text _style _isSustain emphasize highlight _) =
        text <> (if emphasize then "(b)" else "")
        <> case highlight of
            Nothing -> ""
            Just (Format.StartHighlight, _) -> "+"
            Just (Format.Highlight, _) -> "-"
            Just (Format.EndHighlight, _) -> "|"

formatSymbol :: Symbol -> Styled.Styled
formatSymbol (Symbol text style _isSustain emph highlight _) =
    (case highlight of
        Nothing -> id
        Just (Format.StartHighlight, color) -> Styled.bg color
        Just (_, color) -> Styled.bg color
    ) $
    Styled.styled style $ (if emph then emphasize else Styled.plain) text
    where
    emphasize word
        -- A bold _ looks similar to a non-bold one, so put a bar to make it
        -- more obvious.
        | "_ " `Text.isPrefixOf` word = emphasize "_|"
        | "‗ " `Text.isPrefixOf` word = emphasize "‗|"
        | otherwise = emphasisStyle word

emphasisStyle :: Text -> Styled.Styled
emphasisStyle = Styled.fg red . Styled.bold
    where red = Styled.rgb (0xa1 / 0xff) (0x13 / 0xff) 0
    -- I'm used to this dark red since it's what iterm used for bold.

symLength :: Symbol -> Int
symLength = Realize.textLength . _text

textSplitAt :: Int -> Text -> (Text, Text)
textSplitAt at text =
    find $ map (flip Text.splitAt text) [0 .. Realize.textLength text]
    where
    find (cur : next@((pre, _) : _))
        | Realize.textLength pre > at = cur
        | otherwise = find next
    find _ = (text, "")

-- * util

breakFst :: (key -> Bool) -> [(key, a)] -> ([a], [a])
breakFst f = bimap (map snd) (map snd) . break (f . fst)

-- | I think lenses are the way to lift mapAccumL into second.
mapAccumLSnd :: (state -> a -> (state, b)) -> state -> [(x, a)]
    -> (state, [(x, b)])
mapAccumLSnd f state = List.mapAccumL f2 state
    where
    f2 state (x, a) = (state2, (x, b))
        where (state2, b) = f state a
