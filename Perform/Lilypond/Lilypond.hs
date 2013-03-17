{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables, TupleSections #-}
-- | Convert from Score events to a lilypond score.
module Perform.Lilypond.Lilypond (
    module Perform.Lilypond.Lilypond
    , module Perform.Lilypond.Types
) where
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.State.Strict as State

import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text

import Util.Control
import qualified Util.Pretty as Pretty
import qualified Util.Seq as Seq

import qualified Derive.Attrs as Attrs
import qualified Derive.Scale.Theory as Theory
import qualified Derive.Scale.Twelve as Twelve
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack
import qualified Derive.TrackLang as TrackLang

import qualified Perform.Lilypond.Meter as Meter
import Perform.Lilypond.Meter (Meter)
import Perform.Lilypond.Types
import qualified Perform.Pitch as Pitch


-- * constants

-- | String: @\'right\'@ or @\'left\'@.
v_hand :: TrackLang.ValName
v_hand = TrackLang.Symbol "hand"

-- | String: whatever @\\clef@ accepts, defaults to @\'treble\'@.
v_clef :: TrackLang.ValName
v_clef = TrackLang.Symbol "clef"

-- | String: should be parseable by 'Meter.parse_meter',
-- e.g. @\'3/4\'@.
v_meter :: TrackLang.ValName
v_meter = TrackLang.Symbol "meter"

-- | String: prepend this lilypond code to the note.  If the note has
-- 0 duration, it's a freestanding expression and should go before notes
-- starting at the same time.
v_ly_prepend :: TrackLang.ValName
v_ly_prepend = TrackLang.Symbol "ly-prepend"

-- | String: like 'v_ly_prepend' but append the code to all the notes in a tied
-- sequence.  This is the only append variant accepted for zero-dur notes.
v_ly_append_all :: TrackLang.ValName
v_ly_append_all = TrackLang.Symbol "ly-append-all"

-- | String: append code to the first note in a tied sequence.
v_ly_append_first :: TrackLang.ValName
v_ly_append_first = TrackLang.Symbol "ly-append-first"

-- | String: append code to the last note in a tied sequence.
v_ly_append_last :: TrackLang.ValName
v_ly_append_last = TrackLang.Symbol "ly-append-last"

-- | Automatically add lilypond code for certain attributes.
simple_articulations :: [(Score.Attributes, Code)]
simple_articulations =
    [ (Attrs.harm, "-\\flageolet")
    , (Attrs.mute, "-+")
    , (Attrs.marcato, "-^")
    , (Attrs.staccato, "-.")
    , (Attrs.trill, "\\trill")
    , (Attrs.portato, "-_")
    , (Attrs.tenuto, "--")
    , (Attrs.accent, "->")
    , (Attrs.trem, ":32")
    ]

-- | Certain attributes are modal, in that they emit one thing when they
-- start, and another when they stop.
modal_articulations :: [(Score.Attributes, Code, Code)]
modal_articulations =
    [ (Attrs.pizz, "^\"pizz.\"", "^\"arco\"")
    , (Attrs.nv, "^\"nv\"", "^\"vib\"")
    ]

-- ** Event

data Event = Event {
    event_start :: !Time
    , event_duration :: !Time
    , event_pitch :: !String
    , event_instrument :: !Score.Instrument
    , event_environ :: !TrackLang.Environ
    , event_stack :: !Stack.Stack
    -- | True if this event is the tied continuation of a previous note.  In
    -- other words, if it was generated by the tie-splitting code.  This is
    -- a hack to differentiate between v_ly_append_first and v_ly_append_last.
    , event_clipped :: !Bool
    } deriving (Show)

event_end :: Event -> Time
event_end event = event_start event + event_duration event

event_attributes :: Event -> Score.Attributes
event_attributes = Score.environ_attributes . event_environ

instance Pretty.Pretty Event where
    format (Event start dur pitch inst attrs _stack _clipped) =
        Pretty.constructor "Event" [Pretty.format start, Pretty.format dur,
            Pretty.text pitch, Pretty.format inst, Pretty.format attrs]

-- ** Note

data Note = Note {
    -- _* functions are partial.
    -- | @[]@ means this is a rest, and greater than one pitch indicates
    -- a chord.
    _note_pitch :: ![String]
    -- | True if this covers an entire measure.  Used only for rests.
    , _note_full_measure :: !Bool
    , _note_duration :: !NoteDuration
    , _note_tie :: !Bool
    -- | Additional code to prepend to the note.
    , _note_prepend :: !Code
    -- | Additional code to append to the note.
    , _note_append :: !Code
    , _note_stack :: !(Maybe Stack.UiFrame)
    }
    | ClefChange String
    | KeyChange Key
    | MeterChange Meter
    | Code !Code
    deriving (Show)

-- | Arbitrary bit of lilypond code.  This type isn't used for non-arbitrary
-- chunks, like '_note_pitch'.
type Code = String

make_rest :: Bool -> NoteDuration -> Note
make_rest full_measure dur = Note
    { _note_pitch = []
    , _note_full_measure = full_measure
    , _note_duration = dur
    , _note_tie = False
    , _note_prepend = ""
    , _note_append = ""
    , _note_stack = Nothing
    }

is_rest :: Note -> Bool
is_rest note@(Note {}) = null (_note_pitch note)
is_rest _ = False

is_note :: Note -> Bool
is_note (Note {}) = True
is_note _ = False

instance ToLily Note where
    to_lily (Note pitches full_measure dur tie prepend append _stack) =
        (prepend++) . (++ (ly_dur ++ append)) $ case pitches of
            [] -> if full_measure then "R" else "r"
            [pitch] -> pitch
            _ -> '<' : unwords pitches ++ ">"
        where ly_dur = to_lily dur ++ if tie then "~" else ""
    to_lily (ClefChange clef) = "\\clef " ++ clef
    to_lily (KeyChange (tonic, mode)) = "\\key " ++ tonic ++ " \\" ++ mode
    to_lily (MeterChange meter) = "\\time " ++ to_lily meter
    to_lily (Code code) = code

note_time :: Note -> Time
note_time note@(Note {}) = note_dur_to_time (_note_duration note)
note_time _ = 0

note_stack :: Note -> Maybe Stack.UiFrame
note_stack note@(Note {}) = _note_stack note
note_stack _ = Nothing

-- * meter

-- | Get a meter map for the events.  There is one Meter for each measure.
extract_meters :: [Event] -> Either String [Meter]
extract_meters events = go 0 Meter.default_meter events
    where
    go _ _ [] = Right []
    go at prev_meter events = do
        meter <- maybe (return prev_meter) lookup_meter $ Seq.head events
        let end = at + Meter.measure_time meter
        rest <- go end meter (dropWhile ((<=end) . event_end) events)
        return $ meter : rest

    lookup_meter = do
        lookup_val v_meter Meter.parse_meter Meter.default_meter
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
    , state_meters :: [Meter]
    , state_measure_start :: Time
    , state_measure_end :: Time

    -- change on each note
    -- | End of the previous note.
    , state_note_end :: Time
        -- | Used in conjunction with 'modal_articulations'.
    , state_prev_attrs :: Score.Attributes
    , state_clef :: Maybe Clef
    , state_key :: Maybe Key
    } deriving (Show)

-- | Turn Events, which are in absolute Time, into Notes, which are divided up
-- into tied Durations depending on the meter.  The Notes are divided up by
-- measure.
convert_measures :: Config -> [Meter] -> [Event] -> Either String [[Note]]
convert_measures config meters events =
    run_convert initial $ add_time_changes <$> go events
    where
    initial = State
        { state_config = config
        , state_meters = meters
        , state_measure_start = 0
        , state_measure_end = 0
        , state_note_end = 0
        , state_prev_attrs = mempty
        , state_clef = Nothing
        , state_key = Nothing
        }
    go [] = return []
    go events = do
        (measure, events) <- convert_measure events
        measures <- go events
        return (measure : measures)

    -- Add TimeChanges when the meter changes, and pad with empty measures
    -- until I run out of meter.
    add_time_changes = map add_time . Seq.zip_padded2 (Seq.zip_prev meters)
    add_time ((prev_meter, meter), maybe_measure) = meter_change
        ++ fromMaybe (make_rests config meter 0 (Meter.measure_time meter))
            maybe_measure
        where
        meter_change = [MeterChange meter | maybe True (/=meter) prev_meter]

-- | This is a simplified version of 'convert_measures', designed for
-- converting little chunks of lilypond that occur in other expressions.
-- So it doesn't handle clef changes, meter changes, or even barlines.
-- It will apply simple articulations from 'simple_articulations', but not
-- modal ones from 'modal_articulations'.
simple_convert :: Config -> Meter -> Time -> [Event] -> [Note]
simple_convert config meter = go
    where
    go _ [] = []
    go start (event : events) = leading_rests ++ notes ++ go end rest_events
        where
        leading_rests = make_rests config meter start (event_start event)
        (notes, end, _, rest_events) = convert_notes mempty meter event events

-- TODO The meters are still not correct.  Since meter is only on notes,
-- I can't represent a meter change during silence.  I would need to generate
-- something other than notes, or create a silent note for each meter change.
convert_measure :: [Event] -> ConvertM ([Note], [Event])
convert_measure events = case events of
    [] -> return ([], []) -- Out of events at the beginning of a measure.
    first_event : _ -> do
        meter <- State.gets state_meters >>= \x -> case x of
            [] -> Error.throwError $
                "out of meters but not out of events: "
                ++ show first_event
            meter : meters -> do
                State.modify $ \state -> state { state_meters = meters }
                return meter
        event_meter <- lookup_meter first_event
        when (event_meter /= meter) $
            Error.throwError $
                "inconsistent meters, analysis says it should be "
                ++ show meter ++ " but the event has " ++ show event_meter
        State.modify $ \state -> state
            { state_measure_start = state_measure_end state
            , state_measure_end =
                state_measure_end state + Meter.measure_time meter
            }
        measure1 meter events
    where
    measure1 meter [] = (, []) <$> trailing_rests meter
    measure1 meter (event : events) = do
        state <- State.get
        -- This assumes that events that happen at the same time all have the
        -- same clef and key.
        measure_end <- State.gets state_measure_end
        if event_start event >= measure_end
            then (, event:events) <$> trailing_rests meter
            else note_column state meter event events
    note_column state meter event events = do
        clef <- lookup_clef event
        let clef_change = [ClefChange clef | Just clef /= state_clef state]
        key <- lookup_key event
        let key_change = [KeyChange key | Just key /= state_key state]
        let (chord_notes, end, last_attrs, rest_events) = convert_notes
                (state_prev_attrs state) meter event events
            leading_rests = make_rests (state_config state) meter
                (state_note_end state) (event_start event)
            notes = leading_rests ++ clef_change ++ key_change ++ chord_notes
        State.modify $ \state -> state
            { state_clef = Just clef
            , state_key = Just key
            , state_prev_attrs = last_attrs
            , state_note_end = end
            }
        (rest_notes, rest_events) <- measure1 meter rest_events
        return (notes ++ rest_notes, rest_events)
    trailing_rests meter = do
        state <- State.get
        let end = state_measure_start state + Meter.measure_time meter
        let rests = make_rests (state_config state) meter
                (state_note_end state) end
        State.modify $ \state -> state { state_note_end = end }
        return rests

-- | Convert a chunk of events all starting at the same time.  Events
-- with 0 duration or null pitch are expected to have either 'v_ly_prepend_*'
-- or 'v_ly_append_*', and turn into 'Code' Notes.
--
-- The rules are documented in 'Perform.Lilypond.Convert.convert_event'.
convert_notes :: Score.Attributes -> Meter -> Event -> [Event]
    -> ([Note], Time, Score.Attributes, [Event])
    -- ^ (note, note end time, last attrs, remaining events)
convert_notes prev_attrs meter event events =
    (notes, end, last_attrs, clipped ++ rest)
    where
    -- Circumfix any real notes with zero-dur code placeholders.
    notes = map (Code . get v_ly_prepend) prepend
        ++ chord_notes ++ map (Code . get v_ly_append_all) append
    (chord_notes, end, last_attrs, clipped) = case has_dur of
        [] -> ([], event_start event, prev_attrs, [])
        c : cs ->
            let next = event_start <$> Seq.head rest
                (n, end, clipped) = convert_chord prev_attrs meter c cs next
            in ([n], end, event_attributes (last (c:cs)), clipped)

    (here, rest) = break ((> event_start event) . event_start) (event : events)
    (dur0, has_dur) = List.partition ((==0) . event_duration) here
    (prepend, append) = List.partition (has v_ly_prepend) dur0
    has v = not . null . get v
    get :: TrackLang.ValName -> Event -> String
    get v = fromMaybe "" . TrackLang.maybe_val v . event_environ

convert_chord :: Score.Attributes -> Meter -> Event -> [Event]
    -> Maybe Time -> (Note, Time, [Event]) -- ^ (note, note end time, clipped)
convert_chord prev_attrs meter event events next =
    (if null pitches then code else note, end, clipped)
    where
    chord = event : events
    env = event_environ event
    -- If there are no pitches, then this is code with duration.
    pitches = filter (not . null) (map event_pitch chord)
    code = Code (prepend ++ append)
    note = Note
        { _note_pitch = pitches
        , _note_full_measure = False
        , _note_duration = allowed_dur
        , _note_tie = is_tied
        , _note_prepend = prepend
        , _note_append = append
            ++ attrs_to_code prev_attrs (event_attributes event)
        , _note_stack = Seq.last (Stack.to_ui (event_stack event))
        }
    prepend = if is_first then get v_ly_prepend else ""
    append = (if is_first then get v_ly_append_first else "")
        ++ (if not is_tied then get v_ly_append_last else "")
        ++ get v_ly_append_all
    get val = fromMaybe "" (TrackLang.maybe_val val env)

    is_tied = any (>end) (map event_end chord)
    is_first = not (event_clipped event)

    allowed = min (max_end - start) (allowed_time_greedy True meter start)
    allowed_dur = time_to_note_dur allowed
    allowed_time = note_dur_to_time allowed_dur
    -- Maximum end, the actual end may be shorter since it has to conform to
    -- a Duration.
    max_end = fromMaybe (event_end event) $
        Seq.minimum (Maybe.maybeToList next ++ map event_end chord)
    clipped = mapMaybe (clip_event end) chord
    start = event_start event
    end = start + allowed_time

make_rests :: Config -> Meter -> Time -> Time -> [Note]
make_rests config meter start end
    | start < end = map (make_rest full_measure) $ convert_duration meter
        (config_dotted_rests config) True start (end - start)
    | otherwise = []
    where
    full_measure = start `mod` measure == 0 && end - start >= measure
    measure = Meter.measure_time meter


-- ** util

run_convert :: State -> ConvertM a -> Either String a
run_convert state = fmap fst . Identity.runIdentity . Error.runErrorT
    . flip State.runStateT state

lookup_meter :: Event -> ConvertM Meter
lookup_meter = lookup_val v_meter Meter.parse_meter Meter.default_meter

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

attrs_to_code :: Score.Attributes -> Score.Attributes -> Code
attrs_to_code prev_attrs attrs = concat $
    [code | (attr, code) <- simple_articulations, has attr]
    ++ [start | (attr, start, _) <- modal_articulations,
        has attr, not (prev_has attr)]
    ++ [end | (attr, _, end) <- modal_articulations,
        not (has attr), prev_has attr]
    where
    has = Score.attrs_contain attrs
    prev_has = Score.attrs_contain prev_attrs

-- | Clip off the part of the event before the given time, or Nothing if it
-- was entirely clipped off.
clip_event :: Time -> Event -> Maybe Event
clip_event end e
    | left <= 0 = Nothing
    | otherwise = Just $
        e { event_start = end, event_duration = left, event_clipped = True }
    where left = event_end e - end

-- | Given a starting point and a duration, emit the list of Durations
-- needed to express that duration.
convert_duration :: Meter -> Bool -> Bool -> Time -> Time -> [NoteDuration]
convert_duration meter use_dot_ is_rest = go
    where
    -- Dotted rests are always allowed for triple meters.
    use_dot = use_dot_ || (is_rest && not (Meter.is_duple meter))
    go pos time_dur
        | time_dur <= 0 = []
        | allowed >= time_dur = to_durs time_dur
        | otherwise = dur : go (pos + allowed) (time_dur - allowed)
        where
        dur = time_to_note_dur allowed
        allowed = (if is_rest then allowed_time_best else allowed_time_greedy)
            use_dot meter pos
        to_durs = if use_dot then time_to_note_durs
            else map (flip NoteDuration False) . time_to_durs

-- | Figure out how much time a note at the given position should be allowed
-- before it must tie.
allowed_time_greedy :: Bool -> Meter -> Time -> Time
allowed_time_greedy use_dot meter start_ =
    convert $ subtract start $ allowed_time meter start
    where
    start = start_ `mod` Meter.measure_time meter
    convert = if use_dot then note_dur_to_time . time_to_note_dur
        else dur_to_time . fst . time_to_dur

-- | The algorithm for note durations is greedy, in that it will seek to find
-- the longest note that doesn't span a beat whose rank is too low.  But that
-- results in rests being spelled @c4 r2 r4@ instead of @c4 r4 r2@.  Unlike
-- notes, all rests are the same.  So rests will pick the duration that ends on
-- the lowest rank.
allowed_time_best :: Bool -> Meter -> Time -> Time
allowed_time_best use_dot meter start_ =
    subtract start $ best_duration $ allowed_time meter start
    where
    -- Try notes up to the end, select the one that lands on the lowest rank.
    best_duration end = fromMaybe (start + 1) $
        Seq.minimum_on (Meter.rank_at meter) candidates
        where
        candidates = takeWhile (<=end) $ map ((+start) . note_dur_to_time) $
            if use_dot then dot_durs else durs
    durs = reverse $ map (flip NoteDuration False) [D1 .. D128]
    dot_durs = reverse
        [NoteDuration d dot | d <- [D1 .. D64], dot <- [True, False]]
    start = start_ `mod` Meter.measure_time meter

allowed_time :: Meter -> Time -> Time
allowed_time meter start =
    fromMaybe measure $ Meter.find_rank start
        (rank - if Meter.is_duple meter then 2 else 1) meter
    where
    rank = Meter.rank_at meter start
    measure = Meter.measure_time meter

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
    meters <- get_meters staff_groups
    forM staff_groups $ \(inst, staves) ->
        staff_group config meters inst staves

-- | Get the per-measure meters from the longest staff and verify it
-- against the meters from the other staves.
get_meters :: [(Score.Instrument, [[Event]])] -> Either String [Meter]
get_meters staff_groups = do
    let with_inst inst = error_context ("staff for " ++ Pretty.pretty inst)
    with_meters <- forM staff_groups $ \(inst, staves) -> with_inst inst $ do
        meters <- mapM extract_meters staves
        return (inst, zip meters staves)
    let flatten (_inst, measures) = map fst measures
        maybe_longest = Seq.maximum_on length (concatMap flatten with_meters)
    when_just maybe_longest $ \longest -> forM_ with_meters $ \(inst, staves) ->
        with_inst inst $ forM_ staves $ \(meters, _measures) ->
            unless (meters `List.isPrefixOf` longest) $
                Left $ "inconsistent meters: "
                    ++ Pretty.pretty meters ++ " is not a prefix of "
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
staff_group :: Config -> [Meter] -> Score.Instrument -> [[Event]]
    -> Either String StaffGroup
staff_group config meters inst staves = do
    staff_measures <- mapM (convert_measures config meters) staves
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
    is_annot (Code {}) = False
    is_annot _ = True
    is_time (MeterChange {}) = True
    is_time _ = False

-- * make_ly

-- | Same as 'Cmd.Cmd.StackMap', but I don't feel like importing Cmd here.
type StackMap = Map.Map Int Stack.UiFrame

make_ly :: Config -> Title -> [Event] -> Either String ([Text.Text], StackMap)
make_ly config title events =
    ly_file config title <$> convert_staff_groups config events

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

ly_file :: Config -> Title -> [StaffGroup] -> ([Text.Text], StackMap)
ly_file config title staff_groups = run_output $ do
    outputs
        [ "\\version" <+> str "2.14.2"
        , "\\language" <+> str "english"
        , "\\header { title =" <+> str title <+> "tagline = \"\" }"
        , "\\score { <<"
        ]
    mapM_ ly_staff_group (sort_staves (config_staves config) staff_groups)
    outputs [">> }"]
    where
    str = Text.pack . to_lily
    x <+> y = x <> " " <> y

    ly_staff_group (StaffGroup _ staves, long_inst, short_inst) =
        case staves of
            [staff] -> ly_staff (Just (long_inst, short_inst)) Nothing staff
            [up, down] -> ly_piano_staff long_inst short_inst $ do
                ly_staff Nothing (Just "up") up
                ly_staff Nothing (Just "down") down
            _ -> ly_piano_staff long_inst short_inst $
                mapM_ (ly_staff Nothing Nothing) staves
    ly_piano_staff long short contents = do
        outputs
            [ "\n\\new PianoStaff <<"
            , ly_set "PianoStaff.instrumentName" long
            , ly_set "PianoStaff.shortInstrumentName" short
            ]
        contents
        output ">>\n"
    ly_set name val = "\\set" <+> name <+> "=" <+> str val

    ly_staff inst_names maybe_name (Staff measures) = do
        output $ "\n\\new Staff" <> maybe "" (("= "<>) . str) maybe_name
            <+> "{\n"
        when_just inst_names $ \(long, short) -> outputs
            [ ly_set "Staff.instrumentName" long
            , ly_set "Staff.shortInstrumentName" short
            ]
        output "{\n"
        mapM_ show_measures (zip [0, 2 ..] (group 2 measures))
        output "} }\n"
    -- Show 2 measures per line and comment with the measure number.
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

sort_staves :: [(Score.Instrument, String, String)] -> [StaffGroup]
    -> [(StaffGroup, String, String)]
sort_staves staff_config = map lookup_name . Seq.sort_on inst_key
    where
    lookup_name staff =
        case List.find (\(i, _, _) -> i == inst) staff_config of
            Nothing -> (staff, inst_name inst, inst_name inst)
            Just (_, long, short) -> (staff, long, short)
        where inst = inst_of staff
    inst_key staff =
        maybe (1, 0) ((,) 0) $ List.elemIndex (inst_of staff) order
    order = [inst | (inst, _, _) <- staff_config]
    inst_of (StaffGroup inst _) = inst

type Output a = State.State OutputState a

run_output :: Output a -> ([Text.Text], StackMap)
run_output m = (reverse (output_chunks state), output_map state)
    where state = State.execState m (OutputState [] Map.empty 1)

data OutputState = OutputState {
    -- | Chunks of text to write, in reverse order.  I could use
    -- Text.Lazy.Builder, but this is simpler and performance is probably ok.
    output_chunks :: ![Text.Text]
    , output_map :: !StackMap
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
