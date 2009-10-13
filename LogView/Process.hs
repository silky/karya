{-# OPTIONS_GHC -fno-warn-unused-imports #-}
-- Control.Monad
module LogView.Process where
import qualified Control.Concurrent as Concurrent
import qualified Control.Concurrent.STM as STM
import Control.Monad
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.Writer as Writer
import qualified Data.Foldable as Foldable
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Sequence as Sequence
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified System.IO as IO

import qualified Util.Control
import qualified Util.Log as Log
import qualified Util.Regex as Regex
import qualified Util.Seq as Seq


-- * state

data State = State {
    state_filter :: Filter
    -- | Msgs matching this regex have their matching groups put put in the
    -- status line.
    , state_catch_patterns :: [CatchPattern]
    , state_status :: Status
    -- | A cache of the most recent msgs.  When the filter is changed they can
    -- be displayed.  This way memory use is bounded but you can display recent
    -- msgs you missed because of the filter.
    , state_cached_msgs :: Sequence.Seq Log.Msg
    -- | Last timing message.
    , state_last_timing :: Maybe Log.Msg
    } deriving (Show)
initial_state filt = State
    (compile_filter filt) [] Map.empty Sequence.empty Nothing

add_msg :: Int -> Log.Msg -> State -> State
add_msg history msg state = state { state_cached_msgs = seq }
    where seq = Sequence.take history (msg Sequence.<| state_cached_msgs state)

state_msgs :: State -> [Log.Msg]
state_msgs = Foldable.toList . state_cached_msgs

-- ** filter

-- | Filter language.
data Filter = Filter String (Log.Msg -> String -> Bool)
instance Show Filter where
    show (Filter src _) = "compile_filter " ++ show src

-- ** catch

-- | (title, regex)
type CatchPattern = (String, Regex.Regex)

-- ** status

type Status = Map.Map String String
render_status status =
    Seq.join " / " $ map (\(k, v) -> k ++ ": " ++ v) (Map.assocs status)

data StyledText = StyledText {
    style_text :: String
    , style_style :: String
    } deriving (Show)
extract_style (StyledText text style) = (text, style)

-- | Process an incoming log msg.  If the msg isn't filtered out, returned
-- a colorized version.  Also possibly modify the app state for things like
-- catch and timing.
process_msg :: State -> Log.Msg -> (State, Maybe StyledText)
process_msg state msg = (new_state { state_status = status }, msg_styled)
    where
    (new_state, new_msg) = timer_filter state msg
    msg_styled = case new_msg of
        Just msg -> let styled = format_msg msg
            in if eval_filter (state_filter new_state) msg (style_text styled)
                then Just styled
                else Nothing
        Nothing -> Nothing
    caught = catch_patterns (state_catch_patterns state) (Log.msg_string msg)
    status = Map.union caught (state_status state)

-- | Only display timing msgs that take longer than this.
timing_diff_threshold :: Time.NominalDiffTime
timing_diff_threshold = 0.05

-- | Filter out timer msgs that don't have a minimum time from the previous
-- timing, and prepend the interval and bump the priority to Warn if they do.
timer_filter :: State -> Log.Msg -> (State, Maybe Log.Msg)
timer_filter state msg
    | Log.is_timer_msg msg = case state_last_timing state of
        Nothing -> (new_state, Nothing)
        Just last_msg -> (new_state, timing_msg last_msg)
    | otherwise = (state, Just msg)
    where
    new_state = if Log.is_timer_msg msg
        then state { state_last_timing = Just msg } else state
    timing_msg last_msg
        | diff >= timing_diff_threshold = Just $ msg
            { Log.msg_text =
                Text.unwords [Text.pack (show diff), Log.msg_text msg]
            , Log.msg_prio = Log.Warn
            }
        | otherwise = Nothing
        where diff = Log.msg_date msg `Time.diffUTCTime` Log.msg_date last_msg

catch_patterns :: [CatchPattern] -> String -> Status
catch_patterns patterns text = Map.fromList $ concatMap match patterns
    where match (title, reg) = map ((,) title) (Regex.findall reg text)

-- ** filter

-- TODO implement a better language
compile_filter :: String -> Filter
compile_filter s = Filter s f
    where
    (not_has_, has) = List.partition ("-" `List.isPrefixOf`) (words s)
    not_has = map (drop 1) not_has_
    f _msg text = all (`List.isInfixOf` text) has
        && not (any (`List.isInfixOf` text) not_has)

eval_filter (Filter _ pred) msg text = pred msg text


-- * format_msg

format_msg :: Log.Msg -> StyledText
format_msg msg = run_formatter $ do
    with_plain $ replicate (fromEnum (Log.msg_prio msg) + 1) '*'
    with_plain "\t"
    let style = if Log.msg_prio msg < Log.Warn
            then style_plain else style_warn
    maybe (return ()) (emit_srcpos style) (Log.msg_caller msg)
    regex_style style msg_text_regexes (Log.msg_string msg)
    with_plain "\n"

type Formatter = Writer.Writer [(String, [Style])] ()

run_formatter :: Formatter -> StyledText
run_formatter = render_styles . Writer.execWriter

emit_msg_text :: Style -> String -> Formatter
emit_msg_text style text = with_style style text

emit_srcpos style (file, func_name, line) = do
    with_style style $ file ++ ":" ++ show line ++ " "
    maybe (return ())
        (\func -> with_style style_emphasis ("[" ++ func ++ "] ")) func_name

msg_text_regexes :: [(Regex.Regex, Style)]
msg_text_regexes = map (\(reg, style) -> (Regex.make reg, style))
    [ ("\\([bvt]id \".*?\"\\)", style_emphasis)
    ]

regex_style :: Style -> [(Regex.Regex, Style)] -> String -> Formatter
regex_style default_style regex_styles txt =
    literal_style (map go [0..length txt - 1]) txt
    where
    ranges = [(range, style) | (reg, style) <- regex_styles,
        range <- Regex.find_ranges reg txt]
    go i = maybe default_style snd $ List.find ((i `within`) . fst) ranges
    within i (lo, hi) = lo <= i && i < hi

with_plain = with_style style_plain
with_style style text = Writer.tell [(text, replicate (length text) style)]
literal_style style text = Writer.tell [(text, style)]

type Style = Char

render_styles :: [(String, [Style])] -> StyledText
render_styles styles =
    StyledText (concat (map fst styles)) (concat (map snd styles))

style_plain, style_warn, style_clickable, style_emphasis :: Style
style_plain = 'A'
style_warn = 'B'
style_clickable = 'C'
style_emphasis = 'D'


-- * tail file

tail_file :: STM.TChan Log.Msg -> FilePath -> Bool -> IO ()
tail_file log_chan filename seek = do
    -- ReadWriteMode makes it create the file if it doesn't exist, and not
    -- die here.
    hdl <- IO.openFile filename IO.ReadWriteMode
    IO.hSetBuffering hdl IO.LineBuffering -- See tail_getline.
    when seek $
        IO.hSeek hdl IO.SeekFromEnd 0
    forever $ do
        line <- tail_getline hdl
        msg <- deserialize_line line
        STM.atomically $ STM.writeTChan log_chan msg

deserialize_line :: String -> IO Log.Msg
deserialize_line line = do
    err_msg <- Log.deserialize_msg line
    return $ case err_msg of
        Left exc -> Log.msg Log.Error ("error parsing: " ++ show exc)
        Right msg -> msg

tail_getline :: IO.Handle -> IO String
tail_getline hdl = do
    Util.Control.while_ (IO.hIsEOF hdl) $
        Concurrent.threadDelay 500000
    -- Since hGetLine in its infinite wisdom chops the newline it's impossible
    -- to tell if this is a complete line or not.  I'll set LineBuffering and
    -- hope for the best.
    IO.hGetLine hdl
