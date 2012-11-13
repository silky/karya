{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Convert from Score events to a lilypond score.
module Perform.Lilypond.Lilypond where
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.State.Strict as State

import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text

import Util.Control
import qualified Util.ParseBs as ParseBs
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Cmd.Cmd as Cmd
import qualified Derive.Attrs as Attrs
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Pitch as Pitch


-- * constants

v_hand :: TrackLang.ValName
v_hand = TrackLang.Symbol "hand"

v_clef :: TrackLang.ValName
v_clef = TrackLang.Symbol "clef"

v_time_signature :: TrackLang.ValName
v_time_signature = TrackLang.Symbol "time-sig"

-- * types

-- | Configure how the lilypond score is generated.
data Config = Config {
    -- | Allow dotted rests?
    config_dotted_rests :: Bool
    -- | If non-null, generate dynamics from each event's dynamic control.
    -- This has cutoffs for each dynamic level, which should be \"p\", \"mf\",
    -- etc.
    , config_dynamics :: [(Double, String)]
    } deriving (Show)

default_config :: Config
default_config = Config
    { config_dotted_rests = False
    , config_dynamics =
        map (first (/0xff)) [(0x40, "p"), (0x80, "mf"), (0xff, "f")]
    }

-- | Convert a value to its lilypond representation.
class ToLily a where
    to_lily :: a -> String

-- | Time in score units.  The maximum resolution is a 128th note, so one unit
-- is 128th of a whole note.
newtype Time = Time Int deriving (Eq, Ord, Show, Num, Enum, Real, Integral)

instance Pretty.Pretty Time where
    pretty t = show (fromIntegral t / fromIntegral time_per_whole) ++ "t"

time_per_whole :: Time
time_per_whole = Time 128

-- | This time duration measured as the fraction of a whole note.
data Duration = D1 | D2 | D4 | D8 | D16 | D32 | D64 | D128
    deriving (Enum, Eq, Ord, Show)

data NoteDuration = NoteDuration Duration Bool
    deriving (Eq, Show)

read_duration :: String -> Maybe Duration
read_duration s = case s of
    -- GHC incorrectly reports overlapping patterns.  This bug is fixed in 7.4.
    "1" -> Just D1; "2" -> Just D2; "4" -> Just D4; "8" -> Just D8
    "16" -> Just D16; "32" -> Just D32; "64" -> Just D64; "128" -> Just D128
    _ -> Nothing

instance ToLily Duration where
    to_lily = drop 1 . show

instance ToLily NoteDuration where
    to_lily (NoteDuration dur dot) = to_lily dur ++ if dot then "." else ""

data TimeSignature = TimeSignature
    { time_num :: !Int, time_denom :: !Duration }
    deriving (Eq, Show)

instance Pretty.Pretty TimeSignature where pretty = to_lily
instance ToLily TimeSignature where
    to_lily (TimeSignature num denom) = show num ++ "/" ++ to_lily denom

data Event = Event {
    event_start :: !Time
    , event_duration :: !Time
    , event_pitch :: !String
    , event_instrument :: !Score.Instrument
    , event_dynamic :: !Double
    , event_environ :: !TrackLang.Environ
    , event_stack :: !Stack.Stack
    } deriving (Show)

event_end :: Event -> Time
event_end event = event_start event + event_duration event

event_attributes :: Event -> Score.Attributes
event_attributes = Score.environ_attributes . event_environ

instance Pretty.Pretty Event where
    format (Event start dur pitch inst dyn attrs _stack) =
        Pretty.constructor "Event" [Pretty.format start, Pretty.format dur,
            Pretty.text pitch, Pretty.format inst, Pretty.format dyn,
            Pretty.format attrs]

-- ** Note

data Note = Note {
    -- _* functions are partial.

    -- | @[]@ means this is a rest, and greater than one pitch indicates
    -- a chord.
    _note_pitch :: ![String]
    , _note_duration :: !NoteDuration
    , _note_tie :: !Bool
    -- | A slur goes across a consecutive series of legato notes.
    , _note_legato :: !Bool
    -- | Additional code to append to the note.
    , _note_code :: !String
    , _note_stack :: !(Maybe Stack.UiFrame)
    }
    | ClefChange String
    | KeyChange Key
    | TimeChange TimeSignature
    deriving (Show)

rest :: NoteDuration -> Note
rest dur = Note [] dur False False "" Nothing

is_rest :: Note -> Bool
is_rest note@(Note {}) = null (_note_pitch note)
is_rest _ = False

is_note :: Note -> Bool
is_note (Note {}) = True
is_note _ = False

instance ToLily Note where
    to_lily (Note pitches dur tie _legato code _stack) = case pitches of
            [] -> 'r' : ly_dur ++ code
            [pitch] -> pitch ++ ly_dur ++ code
            _ -> '<' : unwords pitches ++ ">" ++ ly_dur ++ code
        where ly_dur = to_lily dur ++ if tie then "~" else ""
    to_lily (ClefChange clef) = "\\clef " ++ clef
    to_lily (KeyChange (tonic, mode)) = "\\key " ++ tonic ++ " \\" ++ mode
    to_lily (TimeChange tsig) = "\\time " ++ to_lily tsig

note_time :: Note -> Time
note_time note@(Note {}) = note_dur_to_time (_note_duration note)
note_time _ = 0

note_stack :: Note -> Maybe Stack.UiFrame
note_stack note@(Note {}) = _note_stack note
note_stack _ = Nothing

-- * time signature

-- | Get a time signature map for the events.  There is one TimeSignature for
-- each measure.
extract_time_signatures :: [Event] -> Either String [TimeSignature]
extract_time_signatures events = go 0 default_time_signature events
    where
    go _ _ [] = Right []
    go at prev_tsig events = do
        tsig <- maybe (return prev_tsig) lookup_time_signature (Seq.head events)
        let end = at + measure_time tsig
        rest <- go end tsig (dropWhile ((<=end) . event_end) events)
        return $ tsig : rest

    lookup_time_signature = lookup_val v_time_signature parse_time_signature
        default_time_signature
    lookup_val :: TrackLang.ValName -> (String -> Either String a) -> a -> Event
        -> Either String a
    lookup_val key parse deflt event = prefix $ do
        maybe_val <- TrackLang.checked_val key (event_environ event)
        maybe (Right deflt) parse maybe_val
        where
        prefix = either (Error.throwError . ((Pretty.pretty key ++ ": ") ++))
            return

-- * convert

type ConvertM a = State.StateT State (Error.ErrorT String Identity.Identity) a

data State = State {
    -- constant
    state_config :: Config
    -- change on each measure
    , state_times :: [TimeSignature]
    , state_measure_start :: Time
    , state_measure_end :: Time

    -- change on each note
    -- | End of the previous note.
    , state_note_end :: Time
    , state_dynamic :: Maybe String
    , state_clef :: Maybe Clef
    , state_key :: Maybe Key
    } deriving (Show)

-- | Turn Events, which are in absolute Time, into Notes, which are divided up
-- into tied Durations depending on the time signature.  The Notes are divided
-- up by measure.
convert_measures :: Config -> [TimeSignature] -> [Event]
    -> Either String [[Note]]
convert_measures config time_sigs events =
    fmap convert_slurs $ run_convert initial $ add_time_changes <$> go events
    where
    initial = State config time_sigs 0 0 0 Nothing Nothing Nothing
    go [] = return []
    go events = do
        (measure, events) <- convert_measure events
        measures <- go events
        return (measure : measures)

    -- Add TimeChanges when the time signature changes, and pad with empty
    -- measures until I run out of time signatures.
    add_time_changes = map add_time . Seq.zip_padded2 (Seq.zip_prev time_sigs)
    add_time ((prev_tsig, tsig), maybe_measure) = time_change
        ++ fromMaybe (make_rests config tsig 0 (measure_time tsig))
            maybe_measure
        where time_change = [TimeChange tsig | maybe True (/=tsig) prev_tsig]

-- TODO The time signatures are still not correct.  Since time sig is only on
-- notes, I can't represent a time sig change during silence.  I would need to
-- generate something other than notes, or create a silent note for each time
-- sig change.
convert_measure :: [Event] -> ConvertM ([Note], [Event])
convert_measure events = case events of
    [] -> return ([], []) -- Out of events at the beginning of a measure.
    first_event : _ -> do
        tsig <- State.gets state_times >>= \x -> case x of
            [] -> Error.throwError $
                "out of time signatures but not out of events: "
                ++ show first_event
            tsig : tsigs -> do
                State.modify $ \state -> state { state_times = tsigs }
                return tsig
        event_tsig <- lookup_time_signature first_event
        when (event_tsig /= tsig) $
            Error.throwError $ "inconsistent time signatures, "
                ++ "analysis says it should be " ++ show tsig
                ++ " but the event has " ++ show event_tsig

        State.modify $ \state -> state
            { state_measure_start = state_measure_end state
            , state_measure_end = state_measure_end state + measure_time tsig
            }
        measure1 tsig events
    where
    measure1 tsig [] = trailing_rests tsig []
    measure1 tsig (event : events) = do
        state <- State.get
        -- This assumes that events that happen at the same time all have the
        -- same clef and key.
        measure_end <- State.gets state_measure_end
        if event_start event >= measure_end
            then trailing_rests tsig (event : events)
            else note_column state tsig event events
    note_column state tsig event events = do
        clef <- lookup_clef event
        let clef_change = [ClefChange clef | Just clef /= state_clef state]
        key <- lookup_key event
        let key_change = [KeyChange key | Just key /= state_key state]
        let (note, end, rest_events) = convert_note state tsig event events
            leading_rests = make_rests (state_config state) tsig
                (state_note_end state) (event_start event)
            notes = leading_rests ++ clef_change ++ key_change ++ [note]
        State.modify $ \state -> state
            { state_clef = Just clef
            , state_key = Just key
            , state_dynamic = Just $ get_dynamic (state_config state) event
            , state_note_end = end
            }
        (rest_notes, rest_events) <- measure1 tsig rest_events
        return (notes ++ rest_notes, rest_events)
    trailing_rests tsig events = do
        state <- State.get
        let end = state_measure_start state + measure_time tsig
        let rests = make_rests (state_config state) tsig
                (state_note_end state) end
        State.modify $ \state -> state { state_note_end = end }
        return (rests, events)

convert_note :: State -> TimeSignature -> Event -> [Event]
    -> (Note, Time, [Event])
convert_note state tsig event events = (note, end, clipped ++ rest)
    where
    note = Note
        { _note_pitch = map event_pitch here
        , _note_duration = allowed_dur
        , _note_tie = any (> end) (map event_end here)
        , _note_legato =
            Score.attrs_contain (event_attributes event) Attrs.legato
        , _note_code = attributes_to_code (event_attributes event)
            ++ dynamic_to_code (state_config state) (state_dynamic state) event
        , _note_stack = Seq.last (Stack.to_ui (event_stack event))
        }
    (here, rest) = break ((> start) . event_start) (event : events)
    allowed_dur = time_to_note_dur allowed
    allowed_time = note_dur_to_time allowed_dur
    allowed = min (max_end - start) (allowed_dotted_time tsig start)
    -- Maximum end, the actual end may be shorter since it has to conform to
    -- a Duration.
    max_end = fromMaybe (event_end event) $
        Seq.minimum (next ++ map event_end here)
    clipped = mapMaybe (clip_event end) here
    start = event_start event
    end = start + allowed_time
    next = maybe [] ((:[]) . event_start) (Seq.head rest)

make_rests :: Config -> TimeSignature -> Time -> Time -> [Note]
make_rests config tsig start end
    | start < end = map rest $ convert_duration tsig
        (config_dotted_rests config) start (end - start)
    | otherwise = []

-- ** slurs

-- | Convert consecutive @+legato@ attrs to a start and end slur mark.
convert_slurs :: [[Note]] -> [[Note]]
convert_slurs = snd . List.mapAccumL convert_slurs1 False

convert_slurs1 :: Bool -> [Note] -> (Bool, [Note])
convert_slurs1 in_slur = List.mapAccumL go in_slur . Seq.zip_next
    where
    go in_slur (note, maybe_next)
        | not (is_note note) = (in_slur, note)
        | Just next <- maybe_next, in_slur && not (_note_legato next) =
            (False, add_code ")" note)
        | not in_slur && _note_legato note = (True, add_code "(" note)
        | otherwise = (in_slur, note)
    add_code c note = note { _note_code = _note_code note ++ c }


-- ** util

run_convert :: State -> ConvertM a -> Either String a
run_convert state = fmap fst . Identity.runIdentity . Error.runErrorT
    . flip State.runStateT state

lookup_time_signature :: Event -> ConvertM TimeSignature
lookup_time_signature =
    lookup_val v_time_signature parse_time_signature default_time_signature

default_time_signature :: TimeSignature
default_time_signature = TimeSignature 4 D4

lookup_clef :: Event -> ConvertM Clef
lookup_clef = lookup_val v_clef Right default_clef

default_clef :: Clef
default_clef = "treble"

lookup_key :: Event -> ConvertM Key
lookup_key = lookup_val TrackLang.v_key parse_key default_key

default_key :: Key
default_key = ("c", "major")

lookup_val :: TrackLang.ValName -> (String -> Either String a) -> a -> Event
    -> ConvertM a
lookup_val key parse deflt event = prefix $ do
    maybe_val <- TrackLang.checked_val key (event_environ event)
    maybe (Right deflt) parse maybe_val
    where
    prefix = either (Error.throwError . ((Pretty.pretty key ++ ": ") ++))
        return

get_dynamic :: Config -> Event -> String
get_dynamic config event = get (config_dynamics config) (event_dynamic event)
    where
    get dynamics dyn = case dynamics of
        [] -> ""
        ((val, dyn_str) : dynamics)
            | null dynamics || val >= dyn -> dyn_str
            | otherwise -> get dynamics dyn

dynamic_to_code :: Config -> Maybe String -> Event -> String
dynamic_to_code config prev_dyn event
    | not (null dyn) && prev_dyn /= Just dyn = '\\' : dyn
    | otherwise = ""
    where dyn = get_dynamic config event

attributes_to_code :: Score.Attributes -> String
attributes_to_code =
    concat . mapMaybe (flip Map.lookup attributes . Score.attr)
        . Score.attrs_list
    where
    attributes = Map.fromList
        [ (Attrs.trill, "\\trill")
        , (Attrs.trem, ":32")
        -- There are (arpeggio <> up) and (arpeggio <> down), but supporting
        -- them is a bit annoying because I have to match multiple attrs, and
        -- have to prepend \arpeggioArrowUp \arpeggioArrowDown \arpeggioNormal
        , (Attrs.arpeggio, "\\arpeggio")
        ]

-- | Clip off the part of the event before the given time, or Nothing if it
-- was entirely clipped off.
clip_event :: Time -> Event -> Maybe Event
clip_event end e
    | left <= 0 = Nothing
    | otherwise = Just $ e { event_start = end, event_duration = left }
    where left = event_end e - end

-- | Given a starting point and a duration, emit the list of Durations
-- needed to express that duration.
convert_duration :: TimeSignature -> Bool -> Time -> Time -> [NoteDuration]
convert_duration sig use_dot pos time_dur
    | time_dur <= 0 = []
    | allowed >= time_dur = to_durs time_dur
    | otherwise = dur
        : convert_duration sig use_dot (pos + allowed) (time_dur - allowed)
    where
    dur = time_to_note_dur allowed
    allowed = (if use_dot then allowed_dotted_time else allowed_time) sig pos
    to_durs = if use_dot then time_to_note_durs
        else map (flip NoteDuration False) . time_to_durs

-- | Figure out how much time a note at the given position should be allowed
-- before it must tie.
-- TODO Only supports duple time signatures.
allowed_dotted_time :: TimeSignature -> Time -> Time
allowed_dotted_time sig measure_pos
    | pos == 0 = measure
    | otherwise = min measure next - pos
    where
    pos = measure_pos `mod` measure
    measure = measure_time sig
    level = log2 pos + 2
    -- TODO inefficient way to find the next power of 2 greater than pos.
    -- There must be a direct way.
    next = Maybe.fromJust (List.find (>pos) [0, 2^level ..])

-- | Like 'allowed_dotted_time', but only emit powers of two.
allowed_time :: TimeSignature -> Time -> Time
allowed_time sig pos = 2 ^ log2 (allowed_dotted_time sig pos)

-- * duration / time conversion

note_dur_to_time :: NoteDuration -> Time
note_dur_to_time (NoteDuration dur dotted) =
    dur_to_time dur + if dotted && dur /= D128 then dur_to_time (succ dur)
        else 0

dur_to_time :: Duration -> Time
dur_to_time dur = Time $ whole `div` case dur of
    D1 -> 1; D2 -> 2; D4 -> 4; D8 -> 8
    D16 -> 16; D32 -> 32; D64 -> 64; D128 -> 128
    where Time whole = time_per_whole

time_to_note_dur :: Time -> NoteDuration
time_to_note_dur t = case time_to_durs t of
    [d1, d2] | d2 == succ d1 -> NoteDuration d1 True
    d : _ -> NoteDuration d False
    -- I have no 0 duration, so I'm forced to pick something.
    [] -> NoteDuration D1 False

-- | This rounds up to the next Duration, so any Time over a half note will
-- wind up as a whole note.
time_to_dur :: Time -> Duration
time_to_dur (Time time) =
    toEnum $ min (fromEnum D128) (log2 (whole `div` time))
    where Time whole = time_per_whole

time_to_note_durs :: Time -> [NoteDuration]
time_to_note_durs t
    | t > 0 = dur : time_to_note_durs (t - note_dur_to_time dur)
    | otherwise = []
    where dur = time_to_note_dur t

time_to_durs :: Time -> [Duration]
time_to_durs (Time time) =
    map fst $ filter ((/=0) . snd) $ reverse $ zip durs (binary time)
    where
    durs = [D128, D64 ..]
    binary rest
        | rest > 0 = m : binary d
        | otherwise = []
        where (d, m) = rest `divMod` 2

-- | Integral log2.  So 63 is 0, because it divides by 2 zero times.
log2 :: (Integral a) => a -> Int
log2 = go 0
    where
    go n val
        | div > 0 && mod == 0 = go (n+1) div
        | otherwise = n
        where (div, mod) = val `divMod` 2

-- | Duration of a measure, in Time.
measure_time :: TimeSignature -> Time
measure_time sig = Time (time_num sig) * dur_to_time (time_denom sig)

measure_duration :: TimeSignature -> Duration
measure_duration (TimeSignature num denom) =
    time_to_dur $ Time num * dur_to_time denom

-- * types

type Title = String
type Mode = String
type Clef = String
-- | (tonic, Mode)
type Key = (String, Mode)

parse_key :: String -> Either String Key
parse_key key_name = do
    key <- maybe (Left $ "unknown key: " ++ key_name) Right $
        Map.lookup (Pitch.Key key_name) Twelve.all_keys
    tonic <- show_pitch_note (Theory.key_tonic key)
    mode <- maybe (Left $ "unknown mode: " ++ Theory.key_name key) Right $
        Map.lookup (Theory.key_name key) modes
    return (tonic, mode)
    where
    modes = Map.fromList
        [ ("min", "minor"), ("locrian", "locrian"), ("maj", "major")
        , ("dorian", "dorian"), ("phrygian", "phrygian"), ("lydian", "lydian")
        , ("mixo", "mixolydian")
        ]

parse_time_signature :: String -> Either String TimeSignature
parse_time_signature sig = do
    let (num, post) = break (=='/') sig
        unparseable = Left $ "signature must be ##/##: " ++ show sig
    denom <- case post of
        '/' : d -> return d
        _ -> unparseable
    TimeSignature <$> maybe unparseable return (ParseBs.int num)
        <*> maybe unparseable return (read_duration denom)

-- * split staves

-- | If the staff group has >1 staff, it is bracketed as a grand staff.
data StaffGroup = StaffGroup Score.Instrument [Staff]
    deriving (Show)

-- | List of measures, where each measure is a list of Notes.
data Staff = Staff [[Note]] deriving (Show)

-- | Group a stream of events into individual staves based on instrument, and
-- for keyboard instruments, left or right hand.  Then convert each staff of
-- Events to Notes, divided up into measures.
convert_staff_groups :: Config -> [Event] -> Either String [StaffGroup]
convert_staff_groups config events = do
    let staff_groups = split_events events
    time_sigs <- get_time_signatures staff_groups
    forM staff_groups $ \(inst, staves) ->
        staff_group config time_sigs inst staves

-- | Get the per-measure time signatures from the longest staff and verify it
-- against the time signatures from the other staves.
get_time_signatures :: [(Score.Instrument, [[Event]])]
    -> Either String [TimeSignature]
get_time_signatures staff_groups = do
    let with_inst inst = error_context ("staff for " ++ Pretty.pretty inst)
    with_tsigs <- forM staff_groups $ \(inst, staves) -> with_inst inst $ do
        time_sigs <- mapM extract_time_signatures staves
        return (inst, zip time_sigs staves)
    let flatten (_inst, measures) = map fst measures
        maybe_longest = Seq.maximum_on length (concatMap flatten with_tsigs)
    when_just maybe_longest $ \longest -> forM_ with_tsigs $ \(inst, staves) ->
        with_inst inst $ forM_ staves $ \(time_sigs, _measures) ->
            unless (time_sigs `List.isPrefixOf` longest) $
                Left $ "inconsistent time signatures: "
                    ++ Pretty.pretty time_sigs ++ " is not a prefix of "
                    ++ Pretty.pretty longest
    return $ fromMaybe [] maybe_longest

error_context :: String -> Either String a -> Either String a
error_context msg = either (Left . ((msg ++ ": ") ++)) Right

split_events :: [Event] -> [(Score.Instrument, [[Event]])]
split_events events =
    [(inst, Seq.group_on (lookup_hand . event_environ) events)
        | (inst, events) <- by_inst]
    where
    by_inst = Seq.keyed_group_on event_instrument events
    lookup_hand environ = case TrackLang.get_val v_hand environ of
        Right (val :: String)
            | val == "right" -> 0
            | val == "left" -> 1
            | otherwise -> 2
        _ -> 0

-- | Right hand goes at the top, left hand goes at the bottom.  Any other hands
-- goe below that.  Events that are don't have a hand are assumed to be in the
-- right hand.
staff_group :: Config -> [TimeSignature] -> Score.Instrument -> [[Event]]
    -> Either String StaffGroup
staff_group config time_sigs inst staves = do
    staff_measures <- mapM (convert_measures config time_sigs) staves
    return $ StaffGroup inst $ map (Staff . promote_annotations) staff_measures

-- | Normally clef or key changes go right before the note with the changed
-- status.  But if there are leading rests, the annotations should go at the
-- beginning of the score.  It's more complicated because I have to skip
-- leading measures of rests.
promote_annotations :: [[Note]] -> [[Note]]
promote_annotations measures = case empty ++ stripped of
        [] -> []
        measure : measures -> (annots ++ measure) : measures
    where
    -- Yack.  There must be a better way.
    (empty, rest_measures) = span (all not_note) measures
    (annots, stripped) = strip rest_measures
    strip [] = ([], [])
    strip (measure:measures) = (annots, (pre ++ rest) : measures)
        where
        (pre, post) = span not_note measure
        (annots, rest) = span is_annot post
    not_note n = is_time n || is_rest n
    is_annot (Note {}) = False
    is_annot _ = True
    is_time (TimeChange {}) = True
    is_time _ = False

-- * make_ly

make_ly :: Config -> Title -> [Event]
    -> Either String ([Text.Text], Cmd.StackMap)
make_ly config title events =
    ly_file title <$> convert_staff_groups config events

inst_name :: Score.Instrument -> String
inst_name = dropWhile (=='/') . dropWhile (/='/') . Score.inst_name

show_pitch :: Theory.Pitch -> Either String String
show_pitch pitch = (++ oct_mark) <$> show_pitch_note note
    where
    (octave, note) = Theory.pitch_c_octave pitch
    oct_mark = let oct = octave - 5
        in if oct >= 0 then replicate oct '\'' else replicate (abs oct) ','

show_pitch_note :: Theory.Note -> Either String String
show_pitch_note (Theory.Note pc accs) = do
    acc <- case accs of
        -2 -> Right "ff"
        -1 -> Right "f"
        0 -> Right ""
        1 -> Right "s"
        2 -> Right "ss"
        _ -> Left $ "too many accidentals: " ++ show accs
    return $ Theory.pc_char pc : acc


-- * output

ly_file :: Title -> [StaffGroup] -> ([Text.Text], Cmd.StackMap)
ly_file title staff_groups = run_output $ do
    outputs
        [ "\\version" <+> str "2.14.2"
        , "\\language" <+> str "english"
        , "\\header { title =" <+> str title <+> "tagline = \"\" }"
        , "\\score { <<"
        ]
    mapM_ ly_staff_group staff_groups
    outputs [">> }"]
    where
    str text = "\"" <> Text.pack text <> "\""
    x <+> y = x <> " " <> y

    ly_staff_group (StaffGroup inst staves) = case staves of
        [staff] -> do
            output "\n"
            ly_staff inst staff
        _ -> do
            outputs ["\n\\new PianoStaff <<"]
            mapM_ (ly_staff inst) staves
            output ">>\n"
    ly_staff inst (Staff measures) = do
        output "\\new Staff {"
        output $ "\\set Staff.instrumentName =" <+> str (inst_name inst)
            <> "\n\\set Staff.shortInstrumentName =" <+> str (inst_name inst)
            <> "\n{\n"
        mapM_ show_measures (zip [0, 4 ..] (group 4 measures))
        output "} }\n"
    -- Show 4 measures per line and comment with the measure number.
    show_measures (num, measures) = do
        output "  "
        mapM_ show_measure measures
        output $ "%" <+> Text.pack (show num) <> "\n"
    show_measure notes = do
        mapM_ show_note notes
        output "| "
    show_note note = do
        when_just (note_stack note) record_stack
        output $ Text.pack (to_lily note) <> " "
    group _ [] = []
    group n ms = let (pre, post) = splitAt n ms in pre : group n post

type Output a = State.State OutputState a

run_output :: Output a -> ([Text.Text], Cmd.StackMap)
run_output m = (reverse (output_chunks state), output_map state)
    where state = State.execState m (OutputState [] Map.empty 1)

data OutputState = OutputState {
    -- | Chunks of text to write, in reverse order.  I could use
    -- Text.Lazy.Builder, but this is simpler and performance is probably ok.
    output_chunks :: ![Text.Text]
    , output_map :: !Cmd.StackMap
    -- | Running sum of the length of the chunks.
    , output_char_num :: !Int
    } deriving (Show)

outputs :: [Text.Text] -> Output ()
outputs = output . Text.unlines

output :: Text.Text -> Output ()
output text = State.modify $ \(OutputState chunks omap num) ->
    OutputState (text:chunks) omap (num + Text.length text)

record_stack :: Stack.UiFrame -> Output ()
record_stack stack = State.modify $ \st -> st { output_map =
    Map.insert (output_char_num st) stack (output_map st) }
