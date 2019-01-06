-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE CPP #-}
-- | Post-process 'T.Token's.  Check barlines, resolve ties, etc.
module Derive.TScore.Check (
    Error(..), show_error, Config(..), default_config
    , parse_directive, parse_directives
    , preprocess, process
    , call_block_id
    , Meter(..)
#ifdef TESTING
    , module Derive.TScore.Check
#endif
) where
import qualified Control.Monad.Identity as Identity
import qualified Control.Monad.State.Strict as State
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import qualified Data.Void as Void

import qualified Text.Megaparsec as P
import qualified Text.Megaparsec.Char as P

import qualified Util.Num as Num
import qualified Util.Seq as Seq
import qualified Util.Then as Then

import qualified Cmd.Ruler.Meter as Meter
import qualified Cmd.Ruler.Meters as Meters
import qualified Cmd.Ruler.Tala as Tala

import qualified Derive.Scale.Theory as Theory
import qualified Derive.TScore.Parse as Parse
import qualified Derive.TScore.T as T

import qualified Perform.Pitch as Pitch
import qualified Ui.Id as Id

import           Global
import           Types


data Error = Error !T.Time !Text
    deriving (Eq, Show)

instance Pretty Error where
    pretty (Error t msg) = pretty t <> ": " <> msg

show_error :: Meter -> Error -> Text
show_error meter (Error t msg) =
    show_time (meter_duration meter) t <> ": " <> msg

data Config = Config {
    -- | If true, notes with no call get the pitch as their call.  This is
    -- a hack so that e.g. "na" is interpreted as a call with no pitch.
    -- Otherwise I'd have to let directives affect parsing.
    config_default_call :: !Bool
    , config_meter :: !Meter
    , config_scale :: !Scale
    , config_duration :: !DurationMode
    }

default_config :: Config
default_config = Config
    { config_default_call = False
    , config_meter = meter_44
    , config_scale = scale_sargam
    , config_duration = Multiplicative
    }

parse_directives :: Config -> [T.Directive] -> Either Text Config
parse_directives = foldM (flip parse_directive)

parse_directive :: T.Directive -> Config -> Either Text Config
parse_directive (T.Directive name maybe_val) config = case (name, maybe_val) of
    ("meter", Just val) ->
        set_config (\c a -> c { config_meter = a }) meter_map val
    ("scale", Just val) ->
        set_config (\c a -> c { config_scale = a }) scale_map val
    ("dur", Just val) ->
        set_config (\c a -> c { config_duration = a }) duration_map val
    ("default-call", maybe_val) ->
        set_config (\c a -> c { config_default_call = a }) bool_map
            (fromMaybe "t" maybe_val)
    _ -> Left $ "unknown directive name: " <> name
    where
    bool_map = Map.fromList [("f", False), ("t", True)]
    set_config setter m k = fmap (setter config) (lookup k m)
    lookup k m = maybe (Left $ "unknown directive val: " <> k) Right $
        Map.lookup k m

-- * process

type Stream a = [Either Error a]
type Token pitch dur = T.Token pitch dur dur

type GetCallDuration = Id.BlockId -> Either Text T.Time

-- | This goes before the recursion check, because it handles %default-call.
-- The recursion check depends on that because it looks for block calls.
preprocess :: Config -> [T.Token T.Pitch T.NDuration T.Duration]
    -> [T.Token T.Pitch T.NDuration T.Duration]
preprocess config
    | config_default_call config = pitch_to_call
    | otherwise = id

process :: GetCallDuration -> Config
    -> [T.Token T.Pitch T.NDuration T.Duration]
    -> Stream (T.Time, T.Note (Maybe Text) T.Time)
process get_dur (Config _default_call meter scale duration) =
    resolve_pitch scale
    . resolve_time
    . check_barlines meter
    . duration_mode duration
    . resolve_call_duration get_dur
    -- TODO resolve pitch before time, so the pitches are right, so ties work.
    -- But then I still have TBarline and the like.

-- * time

resolve_call_duration :: GetCallDuration
    -> [T.Token T.Pitch T.NDuration rdur]
    -> Stream (T.Token T.Pitch (Either T.Time T.Duration) rdur)
resolve_call_duration get_dur = map $ \case
    T.TBarline a -> Right $ T.TBarline a
    T.TRest a -> Right $ T.TRest a
    T.TNote note ->
        second set $ resolve (T.note_call note) (T.note_duration note)
        where set dur = T.TNote $ note { T.note_duration = dur }
    where
    resolve _ (T.NDuration dur) = Right $ Right dur
    resolve (T.Call call) T.CallDuration
        -- TODO embed SrcPos in T.Token for a proper location
        | Text.null call =
            Left $ Error 0 "can't get call duration of empty call"
        | otherwise = case get_dur (call_block_id call) of
                Left err -> Left $ Error 0 err
                Right time -> Right $ Left time

call_block_id :: Text -> Id.BlockId
call_block_id = Id.BlockId . Id.read_short Parse.default_namespace

-- ** meter

data Meter = Meter {
    -- | Rank pattern.
    --
    -- Adi: [2, 0, 0, 0, 1, 0, 0, 1, 0, 0]
    -- > || ssss ; rrrr ; gggg ; mmmm | pppp ; dddd | nnnn ; sssss ||
    -- 4/4: [1, 0, 0, 0]
    -- > | ssss ; rrrr ; gggg ; mmmm |
    meter_pattern :: [T.Rank]
    , meter_step :: !T.Time
    -- | If true, beats fall at the end of measures.
    , meter_negative :: !Bool
    , meter_labeled :: ![Meter.LabeledMark]
    } deriving (Eq, Show)

meter_duration :: Meter -> T.Time
meter_duration m = meter_step m * fromIntegral (length (meter_pattern m))

meter_map :: Map Text Meter
meter_map = Map.fromList
    [ ("adi", meter_adi)
    , ("44", meter_44)
    ]

-- If I do akshara as 1, then kanda is 1/5th notes.  I'd want to reduce the
-- pulse to 1/5, or write .1--.5?
meter_adi :: Meter
meter_adi = Meter
    { meter_pattern = [2, 0, 0, 0, 1, 0, 1, 0]
    , meter_step = 1
    , meter_negative = False
    , meter_labeled = Tala.simple_meter Tala.adi_tala nadai 1 1
    }
    where nadai = 4 -- TODO don't hardcode this

meter_44 :: Meter
meter_44 = Meter
    { meter_pattern = [1, 0, 0, 0]
    , meter_step = 1/4
    , meter_negative = False
    , meter_labeled = make_labeled (1/16) Meters.m44
    }

make_labeled :: TrackTime -> Meter.AbstractMeter -> [Meter.LabeledMark]
make_labeled dur =
    Meter.label_meter Meter.default_config . Meter.make_meter dur . (:[])

-- ** resolve_time

-- | Remove TBarline and TRest, add start times, and resolve ties.
resolve_time :: (Eq pitch, Parse.Element pitch)
    => Stream (Token pitch (T.Time, Bool))
    -> Stream (T.Time, T.Note pitch T.Time)
resolve_time tokens = go . zip starts $ tokens
    where
    starts = scanl (\n -> (n+) . either (const 0) duration_of) 0 tokens
    go ((start, Right t) : ts) = case t of
        T.TNote note
            | is_tied t -> case tied_notes start note (sndRights pre) of
                Left err -> Left err : go post
                Right end -> Right (start, set_dur (end-start) note) : go post
            | otherwise ->
                Right (start, set_dur (fst (T.note_duration note)) note)
                : go ts
        T.TBarline {} -> go ts
        T.TRest {}
            | is_tied t -> case tied_rests (sndRights pre) of
                Just err -> Left err : go post
                Nothing -> go post
            | otherwise -> go ts
        where
        (pre, post) = Then.span any_tied (splitAt 1) ts
        any_tied (_, Left {}) = True
        any_tied (_, Right n) = is_barline n || is_tied n
    go ((_, Left e) : ts) = Left e : go ts
    go [] = []
    set_dur dur note = note { T.note_duration = dur }
    is_barline (T.TBarline {}) = True
    is_barline _ = False
    sndRights abs = [(a, b) | (a, Right b) <- abs]

tied_notes :: (Eq pitch, Parse.Element pitch)
    => T.Time -> T.Note pitch (T.Time, Bool)
    -> [(T.Time, Token pitch (T.Time, Bool))]
    -> Either Error T.Time
tied_notes start note tied = case others of
    [] -> case Seq.last matches of
        Nothing -> Left $ Error start "final note has a tie"
        Just (s, n)
            | snd $ T.note_duration n ->
                Left $ Error start "final note has a tie"
            | otherwise -> Right $ s + dur_of n
    (t, bad) : _ -> Left $ Error t $ case bad of
        T.TNote n -> "note tied to different pitch: "
            <> Parse.unparse (T.note_pitch note) <> " ~ "
            <> Parse.unparse (T.note_pitch n)
        _ -> "note tied to " <> T.token_name bad
    where
    (matches, others) = first concat $ Seq.partition_on match tied
    dur_of = fst . T.note_duration
    match (s, T.TNote n) | T.note_pitch note == T.note_pitch n = Just [(s, n)]
    match (_, T.TBarline {}) = Just []
    match _ = Nothing

tied_rests :: [(T.Time, Token pitch (T.Time, Bool))] -> Maybe Error
tied_rests = fmap format . List.find (not . matches . snd)
    where
    format (start, token) =
        Error start $ "rest tied to " <> T.token_name token
    matches (T.TRest {}) = True
    matches (T.TBarline {}) = True
    matches _ = False

is_tied (T.TNote note) = snd $ T.note_duration note
is_tied (T.TRest (T.Rest (_, tied))) = tied
is_tied _ = False

-- ** check_barlines

check_barlines :: Meter
    -> Stream (Token pitch (T.Time, tie)) -> Stream (Token pitch (T.Time, tie))
check_barlines meter = snd . map_rights_e check_token 0 . zip_right [0..]
    where
    check_token now (i, token) = (now + dur, Right token : warning)
        where
        dur = duration_of token
        warning = case token of
            T.TBarline bar -> maybe [] ((:[]) . Left) (check now i bar)
            _ -> []
    check now i (T.Barline rank) = case Map.lookup beat expected_rank of
        Just r
            | r == rank -> Nothing
            | otherwise -> Just $ warn i now $
                "saw " <> Parse.unparse (T.Barline rank)
                <> ", expected " <> Parse.unparse (T.Barline r)
        Nothing -> Just $ warn i now $
            "saw " <> Parse.unparse (T.Barline rank) <> ", expected none"
        where
        beat = now `Num.fmod` cycle_dur
    cycle_dur = meter_duration meter
    expected_rank = Map.fromList $ zip (Seq.range_ 0 (meter_step meter))
        (meter_pattern meter)
    warn :: Int -> T.Time -> Text -> Error
    warn i now msg = Error now $
        "barline check: token " <> showt i <> ": " <> msg

show_time :: T.Time -> T.Time -> Text
show_time cycle_dur t = pretty (cycle :: Int) <> ":" <> pretty beat
    where (cycle, beat) = t `Num.fDivMod` cycle_dur

duration_of :: Token pitch (T.Time, tie) -> T.Time
duration_of = \case
    T.TBarline _ -> 0
    T.TNote note -> fst (T.note_duration note)
    T.TRest (T.Rest (dur, _)) -> dur

-- ** resolve duration

duration_map :: Map Text DurationMode
duration_map = Map.fromList
    [ ("mul", Multiplicative)
    , ("add", Additive)
    ]

data DurationMode = Multiplicative | Additive
    deriving (Eq, Show)

duration_mode :: DurationMode
    -> Stream (T.Token pitch (Either T.Time T.Duration) T.Duration)
    -> Stream (Token pitch (T.Time, Bool))
duration_mode = \case
    Multiplicative -> multiplicative
    Additive -> additive

-- | Each number is the inverse of the number of beats, so 2 is 1/2, 8 is 1/8
-- etc.
multiplicative :: Stream (T.Token pitch (Either T.Time T.Duration) T.Duration)
    -> Stream (Token pitch (T.Time, Bool))
multiplicative =
    flip State.evalState (Right 1) . map_right_em (carry_duration time_of)
    where
    time_of idur dots = dur + dot_dur
        where
        dur = T.Time (1 / fromIntegral idur)
        dot_dur = sum $ take dots $ drop 1 $ iterate (/2) dur

-- | Each number is just the number of Time beats.
additive :: Stream (T.Token pitch (Either T.Time T.Duration) T.Duration)
    -> Stream (Token pitch (T.Time, Bool))
additive =
    flip State.evalState (Right 1) . map_right_em (carry_duration time_of)
    where
    time_of idur dots = dur + dot_dur
        where
        dur = T.Time (fromIntegral idur)
        dot_dur = sum $ take dots $ drop 1 $ iterate (/2) dur

map_duration :: Monad m => (dur1 -> m (dur2, Bool))
    -> T.Token pitch (Either dur2 dur1) dur1
    -> m (T.Token pitch (dur2, Bool) (dur2, Bool))
map_duration f = \case
    T.TBarline a -> return $ T.TBarline a
    T.TNote note -> do
        time <- case T.note_duration note of
            Left time -> return (time, False)
            Right dur -> f dur
        return $ T.TNote $ note { T.note_duration = time }
    T.TRest (T.Rest dur) -> T.TRest . T.Rest <$> f dur

carry_duration :: State.MonadState (Either T.Time Int) m
    => (Int -> Int -> T.Time)
    -> T.Token pitch (Either T.Time T.Duration) T.Duration
    -> m (Either Error (T.Token pitch (T.Time, Bool) (T.Time, Bool)))
carry_duration time_of = \case
    T.TBarline a -> return $ Right $ T.TBarline a
    T.TNote note -> do
        result <- case T.note_duration note of
            Left time -> do
                State.put $ Left time
                return $ Right (time, False)
            Right (T.Duration maybe_idur dots tie) -> do
                time_dur <- maybe State.get (return . Right) maybe_idur
                State.put time_dur
                return $ case time_dur of
                    Left time
                        | dots /= 0 || tie -> Left
                            "can't carry CallDuration to dots or tie"
                        | T.note_call note == "" -> Left
                            "can't carry CallDuration to non-call"
                        | otherwise -> Right (time, False)
                    Right idur -> Right (time_of idur dots, tie)
        return $ case result of
            Left err -> Left $ Error 0 err
            Right (time, tie) -> Right $ T.TNote $
                note { T.note_duration = (time, tie) }
    T.TRest (T.Rest (T.Duration maybe_idur dots tie)) -> do
        time_dur <- maybe State.get (return . Right) maybe_idur
        return $ case time_dur of
            Left _ -> Left $ Error 0 "can't carry CallDuration to a rest"
            Right idur -> Right $ T.TRest $ T.Rest (time_of idur dots, tie)

-- * pitch

data Scale = Scale {
    scale_parse :: Text -> Maybe Pitch.Degree
    , scale_unparse :: Pitch.Degree -> Maybe Text
    , scale_layout :: !Theory.Layout
    , scale_initial_octave :: !Pitch.Octave
    }

resolve_pitch :: Scale
    -> Stream (T.Time, T.Note T.Pitch dur)
    -> Stream (T.Time, T.Note (Maybe Text) dur)
resolve_pitch scale =
    pitch_to_symbolic scale
    . infer_octaves per_octave (scale_initial_octave scale)
    . parse_pitches (scale_parse scale)
    where
    per_octave = Theory.layout_pc_per_octave (scale_layout scale)

parse_pitches :: (Text -> Maybe pitch)
    -> Stream (T.Time, T.Note T.Pitch dur)
    -> Stream (T.Time, T.Note (Maybe (T.Octave, pitch)) dur)
parse_pitches parse = fst . map_right_e token Nothing
    where
    token maybe_prev (start, note)
        | Text.null call = case maybe_prev of
            Nothing ->
                ( maybe_prev
                , with_pitch Nothing
                )
            Just p -> (Just p, with_pitch (Just p))
        | otherwise = case parse call of
            Nothing ->
                ( maybe_prev
                , Left $ Error start $ "can't parse pitch: " <> call
                )
            Just p -> (Just p, with_pitch (Just p))
        where
        T.Pitch oct call = T.note_pitch note
        with_pitch p = Right (start, note { T.note_pitch = (oct,) <$> p })

infer_octaves :: Pitch.PitchClass -> Pitch.Octave
    -> [Either e (time, T.Note (Maybe (T.Octave, Pitch.Degree)) dur)]
    -> [Either e (time, T.Note (Maybe Pitch.Pitch) dur)]
infer_octaves per_octave initial_oct =
    fst . map_right infer (initial_oct, Nothing)
    where
    infer (prev_oct, prev_degree) (start, note) = case T.note_pitch note of
        Nothing ->
            ((prev_oct, prev_degree), (start, note { T.note_pitch = Nothing }))
        Just (oct, degree) -> with_octave degree $ case oct of
            T.Relative n -> n + case prev_degree of
                Just prev -> min_on3 (distance prev degree)
                    (prev_oct-1) prev_oct (prev_oct+1)
                Nothing -> prev_oct
            T.Absolute oct -> oct
        where
        with_octave degree oct =
            ( (oct, Just degree)
            , (start, note { T.note_pitch = Just (Pitch.Pitch oct degree) })
            )
        distance prev degree oct = abs $
            Pitch.diff_pc per_octave (Pitch.Pitch prev_oct prev)
                (Pitch.Pitch oct degree)

-- | Convert 'Pitch'es back to symbolic form.
pitch_to_symbolic :: Scale
    -> Stream (T.Time, T.Note (Maybe Pitch.Pitch) dur)
    -> Stream (T.Time, T.Note (Maybe Text) dur)
pitch_to_symbolic scale = map to_sym
    where
    to_sym (Left e) = Left e
    to_sym (Right (t, note)) = do
        sym <- case T.note_pitch note of
            Nothing -> return Nothing
            Just pitch -> Just <$> tryJust
                (Error t ("bad pitch: " <> pretty (T.note_pitch note)))
                (unparse pitch)
        return (t, note { T.note_pitch = sym })
    unparse (Pitch.Pitch oct degree) =
        (showt oct <>) <$> scale_unparse scale degree

-- ** scale

scale_map :: Map Text Scale
scale_map = Map.fromList
    [ ("sargam", scale_sargam)
    , ("bali", scale_ioeua)
    , ("twelve", scale_twelve)
    ]

diatonic_scale :: [Text] -> Scale
diatonic_scale degrees_ = Scale
    { scale_parse = \s -> Pitch.Degree <$> Vector.elemIndex s degrees <*> pure 0
    , scale_unparse = unparse
    , scale_layout = Theory.diatonic_layout (Vector.length degrees)
    , scale_initial_octave = 4
    }
    where
    unparse (Pitch.Degree pc accs)
        | accs == 0 = degrees Vector.!? pc
        | otherwise = Nothing
    degrees = Vector.fromList degrees_

scale_sargam :: Scale
scale_sargam = diatonic_scale $ map Text.singleton "srgmpdn"

scale_ioeua :: Scale
scale_ioeua = diatonic_scale $ map Text.singleton "ioeua"

scale_twelve :: Scale
scale_twelve = Scale
    { scale_parse = P.parseMaybe p_degree
    , scale_unparse = unparse
    , scale_layout = Theory.piano_layout
    , scale_initial_octave = 4
    }
    where
    p_degree :: Parser Pitch.Degree
    p_degree = do
        pc <- P.choice [P.string c *> pure i | (i, c) <- zip [0..] degrees]
        accs <- P.choice $ map (\(n, c) -> P.string c *> pure n) accidentals
        return $ Pitch.Degree pc accs
    unparse (Pitch.Degree pc accs) = (<>)
        <$> Seq.at degrees pc <*> lookup accs accidentals
    accidentals =
        [ (0, ""), (0, "n")
        , (1, "#"), (2, "x")
        , (-1, "b"), (-2, "bb")
        ]
    degrees = map Text.singleton "cdefgab"


type Parser a = P.Parsec Void.Void Text a


-- * parsing

pitch_to_call :: [T.Token T.Pitch T.NDuration T.Duration]
    -> [T.Token T.Pitch T.NDuration T.Duration]
pitch_to_call = Identity.runIdentity . mapM (T.map_note (return . to_call))
    where
    to_call note
        | T.note_call note == T.Call "" = note
            { T.note_call = T.Call $ Parse.unparse (T.note_pitch note)
            , T.note_pitch = Parse.empty_pitch
            }
        | otherwise = note


-- * util

-- TODO this is much like LEvent, but with any error, not just logs.

-- | Like 'List.mapAccumL', but pass through lefts.
-- TODO try monadic style for map_right and map_right_e
map_right :: (state -> a -> (state, b)) -> state -> [Either e a]
    -> ([Either e b], state)
map_right f = map_right_e (\state -> second Right . f state)

-- | Like 'map_right_em', but adapted to use mapAccumL style state.
map_right_e :: (state -> a -> (state, Either e b)) -> state -> [Either e a]
    -> ([Either e b], state)
map_right_e f state = flip State.runState state . map_right_em run
    where
    run a = do
        state <- State.get
        let (state2, eb) = f state a
        State.put $! state2
        return eb

map_right_m :: Monad m => (a -> m b) -> [Either e a] -> m [Either e b]
map_right_m f = map_right_em (fmap Right . f)

-- TODO is this just traverse . traverse?
-- No, that's (a -> f b) -> t1 (t2 a) -> f (t1 (t2 b))
-- I want: (a -> m1 (m2 b)) -> [m2 a] -> m1 [m2 b]
-- I don't think it's doable, I can't run m2 inside m1.
map_right_em :: Monad m => (a -> m (Either e b))
    -> [Either e a] -> m [Either e b]
map_right_em f = go
    where
    go [] = return []
    go (ea : eas) = case ea of
        Left e -> (Left e :) <$> go eas
        Right a -> do
            eb <- f a
            (eb:) <$> go eas

-- | Like 'map_right_e', except the function can return a list of Eithers.
map_rights_e :: (state -> a -> (state, [Either e b])) -> state -> [Either e a]
    -> (state, [Either e b])
map_rights_e f = go
    where
    go !state [] = (state, [])
    go !state (ea : eas) = case ea of
        Left e -> second (Left e :) (go state eas)
        Right a -> second (ebs++) (go state2 eas)
            where (state2, ebs) = f state a

-- | This is the Either equivalent of 'Derive.LEvent.zip'.
zip_right :: [b] -> [Either a c] -> [Either a (b, c)]
zip_right (b:bs) (Right c : acs) = Right (b, c) : zip_right bs acs
zip_right bs (Left a : acs) = Left a : zip_right bs acs
zip_right [] _ = []
zip_right _ [] = []

min_on3 :: Ord k => (a -> k) -> a -> a -> a -> a
min_on3 key a b c = Seq.min_on key a (Seq.min_on key b c)
