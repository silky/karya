-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RecordWildCards #-}
{- | Calls for gangsa techniques.  Gangsa come in polos and sangsih pairs,
    and play either kotekan patterns or play unison or parallel parts.

    Kotekan patterns have a number of features in common.  They are all
    transpositions from a base pitch.  Rhythmically, they consist of notes with
    a constant duration, that line up at the end of an event's range, and the
    last duration is negative (i.e. implicit, depending on the next note).
    They use polos and sangsih and may switch patterns when the a kotekan speed
    threshold is passed.  Notes are also possibly muted.

    There are a number of ways this can be extended:

    - Use any attribute instead of just mute.
    - More instruments than just polos and sangsih.
    - Multiple kotekan thresholds.

    The first two are supported at the 'KotekanNote' level of abstraction.  For
    the others, I have to either directly use 'Note's or create a new
    abstraction:

    - Variable durations.
-}
module Derive.C.Bali.Gangsa where
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified Data.Text as Text

import qualified Util.CallStack as CallStack
import qualified Util.Doc as Doc
import qualified Util.Lists as Lists
import qualified Util.Log as Log
import qualified Util.Num as Num
import qualified Util.Pretty as Pretty

import qualified Derive.Args as Args
import qualified Derive.Attrs as Attrs
import qualified Derive.C.Bali.Gender as Gender
import qualified Derive.C.Post.Postproc as Postproc
import qualified Derive.Call as Call
import qualified Derive.Call.Make as Make
import qualified Derive.Call.Module as Module
import qualified Derive.Call.Post as Post
import qualified Derive.Call.StaticMacro as StaticMacro
import qualified Derive.Call.Sub as Sub
import qualified Derive.Call.Tags as Tags
import qualified Derive.Controls as Controls
import qualified Derive.Derive as Derive
import qualified Derive.DeriveT as DeriveT
import qualified Derive.Env as Env
import qualified Derive.EnvKey as EnvKey
import qualified Derive.Flags as Flags
import qualified Derive.Library as Library
import qualified Derive.PSignal as PSignal
import qualified Derive.Pitches as Pitches
import qualified Derive.Scale as Scale
import qualified Derive.Score as Score
import qualified Derive.ScoreT as ScoreT
import qualified Derive.ShowVal as ShowVal
import qualified Derive.Sig as Sig
import qualified Derive.Stream as Stream
import qualified Derive.Typecheck as Typecheck

import qualified Perform.Pitch as Pitch
import qualified Perform.RealTime as RealTime
import qualified Perform.Signal as Signal

import qualified Ui.Event as Event
import qualified Ui.Types as Types

import           Global
import           Types


library :: Library.Library
library = mconcat
    [ Library.generators
        [ ("norot", c_norot False Nothing)
        -- Alias for norot.  It's separate so I can rebind this locally.
        , ("nt", c_norot False Nothing)
        , ("nt-", c_norot False (Just False))
        , ("nt<", c_norot True Nothing)
        , ("nt<-", c_norot True (Just False))
        , ("gnorot", c_gender_norot)
        , ("k_\\", c_kotekan_irregular Pat $ irregular_pattern $
            IrregularPattern
            { ir_polos              = "-11-1321"
            , ir_sangsih4           = "-44-43-4"
            , ir_polos_ngotek       = "-11-1-21"
            , ir_sangsih_ngotek3    = "3-32-32-"
            , ir_sangsih_ngotek4    = "-44-43-4"
            })
        , ("k-\\", c_kotekan_irregular Pat $ irregular_pattern $
            IrregularPattern
            { ir_polos              = "211-1321"
            , ir_sangsih4           = "-44-43-4"
            , ir_polos_ngotek       = "211-1-21"
            , ir_sangsih_ngotek3    = "3-32-32-"
            , ir_sangsih_ngotek4    = "-44-43-4"
            })
        , ("k//\\\\", c_kotekan_irregular Pat $ irregular_pattern $
            IrregularPattern
            { ir_polos              = "-123123213213123"
            , ir_sangsih4           = "-423423243243423"
            , ir_polos_ngotek       = "-12-12-21-21-12-"
            , ir_sangsih_ngotek3    = "3-23-232-32-3-23"
            , ir_sangsih_ngotek4    = "-4-34-3-43-434-3"
            })
        -- There are two ways to play k\\, either 21321321 or 31321321.  The
        -- first one is irregular since sangsih starts on 2 but there's no
        -- unison polos.
        , ("k\\\\", c_kotekan_irregular Telu $ irregular_pattern $
            IrregularPattern
            { ir_polos              = "21321321"
            , ir_sangsih4           = "24324324"
            , ir_polos_ngotek       = "-1-21-21"
            , ir_sangsih_ngotek3    = "2-32-32-"
            , ir_sangsih_ngotek4    = "-43-43-4"
            })
        , ("k//", c_kotekan_irregular Telu $ irregular_pattern $
            IrregularPattern
            { ir_polos              = "23123123"
            , ir_sangsih4           = "20120120"
            , ir_polos_ngotek       = "-3-23-23"
            , ir_sangsih_ngotek3    = "2-12-12-"
            , ir_sangsih_ngotek4    = "-01-01-0"
            })
        , ("k\\\\2", c_kotekan_regular False (Just "-1-21-21") Telu)
        , ("k//2",   c_kotekan_regular False (Just "-2-12-12") Telu)
        -- This is k// but with sangsih above.
        -- TODO maybe a more natural way to express this would be to make k//
        -- understand sangsih=u?  But then I also need sangsih=d for k\\,
        -- irregular_pattern support for sangsih direction, and they both become
        -- irregular.
        , ("k//^",   c_kotekan_regular False (Just "2-12-12-") Telu)

        , ("kotekan", c_kotekan_kernel)
        , ("k", c_kotekan_regular False Nothing Telu)
        , ("k^", c_kotekan_regular True Nothing Telu)
        , ("ke", c_kotekan_explicit)
        ]
    , Library.generators $ Gender.ngoret_variations c_ngoret
    , Library.transformers
        [ ("i+", Make.environ_val module_ "i+" "initial" True
            "Kotekan calls will emit a note on the initial beat.")
        , ("i-", Make.environ_val module_ "i-" "initial" False
            "Kotekan calls won't emit a note on the initial beat.")
        , ("f-", Make.environ_val module_ "f-" "final" False
            "Kotekan calls won't emit a final note at the end time.")
        , ("unison", c_unison)
        , ("noltol", c_noltol)
        , ("realize-gangsa", c_realize_gangsa)
        , ("realize-noltol", c_realize_noltol)
        , ("realize-ngoret", Derive.set_module module_ Gender.c_realize_ngoret)
        , ("cancel-pasang", c_cancel_pasang)
        ]
    , Library.both
        [ ("nyog", c_nyogcag)
        , ("kempyung", c_kempyung)
        , ("k+", c_kempyung) -- short version for single notes
        , ("p+", c_derive_with "p+" True False)
        , ("s+", c_derive_with "s+" False True)
        , ("ps+", c_derive_with "ps+" True True)
        ]
    ]

module_ :: Module.Module
module_ = "bali" <> "gangsa"

c_derive_with :: Derive.CallName -> Bool -> Bool -> Library.Calls Derive.Note
c_derive_with name with_polos with_sangsih =
    Make.transform_notes module_ name Tags.inst
    "Derive the note with polos, sangsih, or both." pasang_env $
    \pasang deriver -> mconcat $ concat
        [ [Derive.with_instrument (polos pasang) deriver | with_polos]
        , [Derive.with_instrument (sangsih pasang) deriver | with_sangsih]
        ]

-- * instrument postproc

-- | Variable mute for gangsa.  Intended for the 'Cmd.Cmd.inst_postproc' field.
-- This interprets 'Controls.mute' and turns it into either a @%mod@ control or
-- @mute_attr@.
mute_postproc :: Attrs.Attributes -> Score.Event -> (Score.Event, [Log.Msg])
mute_postproc mute_attr event = (,[]) $
    case Score.control_at (Score.event_start event) Controls.mute event of
        Nothing -> set_mod 0 event
        Just tval
            | mute >= threshold -> Score.add_attributes mute_attr event
            | mute <= 0 -> set_mod 0 event
            -- The mod control goes from 1 (least muted) to 0 (most muted).
            -- Bias mod towards the higher values, since the most audible
            -- partial mutes are from .75--1.
            | otherwise -> set_mod (1 - mute**2) $ Score.set_duration 0 event
            where
            mute = ScoreT.typed_val tval
    where
    set_mod = Score.set_control Controls.mod . ScoreT.untyped . Signal.constant
    -- Use the mute_attr above this threshold.
    threshold = 0.85

-- * ngoret

c_ngoret :: Sig.Parser (Maybe Pitch.Transpose) -> Derive.Generator Derive.Note
c_ngoret = Gender.ngoret module_ False $
    Sig.defaulted "damp" (0.15 :: RealTime)
    "Time that the grace note overlaps with this one. So the total\
    \ duration is time+damp, though it will be clipped to the\
    \ end of the current note."

-- * patterns

-- | There are 4 ways to realize a kotekan:
--
-- 1. Undivided.  Since it's undivided it could be unison or kempyung.
-- 2. Slow but divided.  Play all the notes, but sangsih and polos are kempyung
-- on the outer notes.
-- 3, 4. Ngotek, in telu and pat versions.
data KotekanPattern = KotekanPattern {
    kotekan_telu :: ![Maybe Pitch.Step]
    , kotekan_pat :: ![Maybe Pitch.Step]
    , kotekan_interlock_telu :: !(Pasang [Maybe Pitch.Step])
    , kotekan_interlock_pat :: !(Pasang [Maybe Pitch.Step])
    } deriving (Eq, Show)

instance Pretty KotekanPattern where
    format (KotekanPattern telu pat itelu ipat) = Pretty.record "KotekanPattern"
        [ ("telu", Pretty.format telu)
        , ("pat", Pretty.format pat)
        , ("interlock_telu", Pretty.format itelu)
        , ("interlock_pat", Pretty.format ipat)
        ]

data Pasang a = Pasang {
    polos :: a
    , sangsih :: a
    } deriving (Eq, Show)

instance Pretty a => Pretty (Pasang a) where
    format (Pasang polos sangsih) = Pretty.record "Pasang"
        [ ("polos", Pretty.format polos)
        , ("sangsih", Pretty.format sangsih)
        ]

data Realization a = Realization {
    interlocking :: a
    , non_interlocking :: a
    } deriving (Eq, Show)

instance Pretty a => Pretty (Realization a) where
    format (Realization inter non_inter) = Pretty.record "Realization"
        [ ("interlocking", Pretty.format inter)
        , ("non_interlocking", Pretty.format non_inter)
        ]

data IrregularPattern = IrregularPattern
    { ir_polos :: [Char]
    , ir_sangsih4 :: [Char]
    , ir_polos_ngotek :: [Char]
    , ir_sangsih_ngotek3 :: [Char]
    , ir_sangsih_ngotek4 :: [Char]
    } deriving (Show)

irregular_pattern :: CallStack.Stack => IrregularPattern -> KotekanPattern
irregular_pattern (IrregularPattern {..}) = KotekanPattern
    { kotekan_telu = parse1 ir_polos
    , kotekan_pat = parse1 ir_sangsih4
    , kotekan_interlock_telu = Pasang
        { polos = parse1 ir_polos_ngotek, sangsih = parse1 ir_sangsih_ngotek3 }
    , kotekan_interlock_pat = Pasang
        { polos = parse1 ir_polos_ngotek, sangsih = parse1 ir_sangsih_ngotek4 }
    }
    where
    -- TODO the CallStack.Stack doesn't actually work because all these
    -- functions would have to have it too.
    parse1 = parse_pattern destination . check
    check ns
        | length ns == length ir_polos = ns
        | otherwise = errorStack $ "not same length as polos: " <> showt ns
    destination = fromMaybe (errorStack "no final pitch") $
        Lists.last $ Maybe.catMaybes $ parse_pattern 0 ir_polos

parse_pattern :: CallStack.Stack => Pitch.Step -> [Char] -> [Maybe Pitch.Step]
parse_pattern destination = map (fmap (subtract destination) . parse1)
    where
    parse1 '-' = Nothing
    parse1 c = Just $ fromMaybe (errorStack $ "not a digit: " <> showt c) $
        Num.readDigit c

kotekan_pattern :: KotekanPattern -> KotekanStyle -> Pasang ScoreT.Instrument
    -> Cycle
kotekan_pattern pattern style pasang = Realization
    { interlocking = realize (interlocking realization)
    , non_interlocking = realize (non_interlocking realization)
    }
    where
    realization = pattern_steps style pasang pattern
    realize = map (map (uncurry kotekan_note))

pattern_steps :: KotekanStyle -> Pasang ScoreT.Instrument -> KotekanPattern
    -> Realization [[(Maybe ScoreT.Instrument, Pitch.Step)]]
pattern_steps style pasang (KotekanPattern telu pat itelu ipat) = Realization
    { interlocking = case style of
        Telu -> interlocking itelu
        Pat -> interlocking ipat
    , non_interlocking = case style of
        Telu -> map (realize Nothing) telu
        Pat -> interlocking (Pasang { polos = telu, sangsih = pat })
    }
    where
    realize inst n = maybe [] ((:[]) . (inst,)) n
    interlocking part =
        [ realize (Just (polos pasang)) p ++ realize (Just (sangsih pasang)) s
        | (p, s) <- zip (polos part) (sangsih part)
        ]

-- ** norot

-- | Initially I implemented this as a postproc, but it now seems to me that
-- it would be more convenient as a generator.  In any case, as a postproc it
-- gets really complicated.
c_norot :: Bool -> Maybe Bool -> Derive.Generator Derive.Note
c_norot start_prepare prepare =
    Derive.generator module_ "norot" Tags.inst
    "Emit the basic norot pattern. Normally it will prepare for the next\
    \ pitch if it touches the next note, the `nt-` variant will suppress that.\
    \ The `nt<` variant will also emit a preparation at the note's start."
    $ Sig.call ((,,,,,)
    <$> Sig.defaulted "style" Default "Norot style."
    <*> dur_env <*> kotekan_env <*> instrument_top_env <*> pasang_env
    <*> infer_initial_final_env
    ) $ \(style, note_dur, kotekan, inst_top, pasang, (initial, final))
    -> Sub.inverting $ \args -> do
        next_pitch <- infer_prepare args prepare
        cur_pitch <- Derive.pitch_at =<< Args.real_start args
        scale <- Call.get_scale
        under_threshold <- under_threshold_function kotekan note_dur
        let get_steps = norot_steps scale inst_top style
        let sustain_cycle = gangsa_norot style pasang . get_steps
            prepare_cycle = gangsa_norot_prepare style pasang . get_steps
        let initial_final =
                ( fromMaybe (Args.orientation args == Types.Positive) initial
                , final
                )
        norot start_prepare sustain_cycle prepare_cycle under_threshold
            cur_pitch next_pitch note_dur initial_final (Args.range args)

norot :: Bool -> (PSignal.Transposed -> Cycle) -> (PSignal.Transposed -> Cycle)
    -> (ScoreTime -> Bool) -> Maybe PSignal.Pitch -> Maybe PSignal.Pitch
    -> ScoreTime -> (Bool, Bool) -> (ScoreTime, ScoreTime)
    -> Derive.NoteDeriver
norot start_prepare sustain_cycle prepare_cycle under_threshold
        cur_pitch next_pitch
        note_dur initial_final (start, end) = do
    real_start <- Derive.real start
    cycles <- norot_sequence start_prepare sustain_cycle prepare_cycle
        cur_pitch next_pitch real_start
    let notes = apply_initial_final start end initial_final $
            realize_norot under_threshold note_dur start end cycles
    realize_notes id (concat notes)

apply_initial_final :: ScoreTime -> ScoreTime -> (Bool, Bool) -> [[Note a]]
    -> [[Note a]]
apply_initial_final start end (initial, final) =
    Lists.mapLast modify_final
    . (if initial then id else dropWhile (any ((<=start) . note_start)))
    where
    modify_final notes
        | final && any ((>=end) . note_start) notes =
            map (add_flag (Flags.infer_duration <> final_flag)) notes
        | otherwise = []

-- | Realize the output of 'norot_sequence'.
realize_norot :: (ScoreTime -> Bool) -> ScoreTime -> ScoreTime -> ScoreTime
    -> (Maybe PitchedCycle, Maybe PitchedCycle, Maybe PitchedCycle)
    -> [[Note Derive.NoteDeriver]]
realize_norot under_threshold note_dur initial_start exact_end
        (prepare_this, sustain, prepare_next) =
    map realize . trim $ concat
        -- This is the initial note, which may be dropped.
        [ on_just sustain $ \(PitchedCycle pitch cycle) ->
            -- There should never be an empty cycle, but might as well be safe.
            on_just (Lists.last (get_cycle cycle initial_start)) $ \notes ->
                [(pitch, (initial_t, notes))]
        , on_just prepare_this $ \(PitchedCycle pitch cycle) ->
            one_cycle pitch cycle this_t
        , on_just sustain $ \(PitchedCycle pitch cycle) ->
            map (pitch,) $ cycles (get_cycle cycle) $
                Lists.range' sustain_t next_t note_dur
        , on_just prepare_next $ \(PitchedCycle pitch cycle) ->
            one_cycle pitch cycle next_t
        ]
        -- TODO should I throw an error if I wanted a pitch but couldn't get
        -- it?  I could make a NoteDeriver that throws when evaluated.
    {- i = initial, t = prepare_this, s = sustain, n = prepare_next
        0 1 2 3 4
        1 3 3 4 3
        i n-----n                s = (1, 1), n = (1, 5)

        0 1 2 3 4
        1 2 1 2 1                s = (1, 5)
        i s-----s

        0 1 2 3 4 5 6 7 8
        1 1 1 2 1 3 3 4 3
        i t-----t n-----n        t = (1, 5), s = (5, 5), n = (5, 9)

        0 1 2 3 4 5 6 7 8 9 a
        1 1 1 2 1 2 1 3 3 4 3
        i t-----t s-s n-----n    t = (1, 5), s = (5, 7), n = (7, 11)

        0 1 2 3 4 5 6 7 8 9 a b c d e f 10
        1 1 1 2 1 3 3 4 3 3 3 4 3 4 3 4 3
        |-nt< ----------->|-nt< -------->
        i t-----t n-----n t-----t s-----s
    -}
    where
    on_just val f = maybe [] f val
    -- This is just sequencing the 4 sections, where sustain is stretchy, but
    -- it's complicated because they align to the end.  I'd lay them out
    -- forwards and then shift back, but the times need to be accurate for
    -- get_cycle.
    initial_t = min initial_start (this_t - note_dur)
    this_t = min start next_t
    sustain_t = start + if Maybe.isJust prepare_this then prep_dur else 0
    next_t = end - if Maybe.isJust prepare_next then prep_dur else 0
    -- Negative orientation means the logical start and end are shifted forward
    -- by one step.
    start = initial_start + note_dur
    end = exact_end + note_dur

    trim = takeWhile ((<=exact_end) . fst . snd)
        . dropWhile ((<initial_start) . fst . snd)
    one_cycle pitch cycle start = map (pitch,) $
        zip (Lists.range_ start note_dur) (get_cycle cycle start)
    get_cycle cycle t
        | under_threshold t = interlocking cycle
        | otherwise = non_interlocking cycle
    prep_dur = note_dur * 4

    realize :: (PSignal.Pitch, (ScoreTime, [KotekanNote]))
        -> [Note Derive.NoteDeriver]
    realize (pitch, (t, chord)) = map (make_note t pitch) chord
    make_note t pitch note = Note
        { note_start = t
        , note_duration = note_dur
        , note_flags = mempty
        , note_data = realize_note pitch note
        }
    realize_note pitch (KotekanNote inst steps muted) =
        maybe id Derive.with_instrument inst $
        -- TODO the kind of muting should be configurable.  Or, rather I should
        -- dispatch to a zero dur note call, which will pick up whatever form
        -- of mute is configured.
        -- TODO I'm using 'm' for that now, right?
        (if muted then Call.add_attributes Attrs.mute else id) $
        Call.pitched_note (Pitches.transpose_d steps pitch)

-- | Figure out the appropriate cycles for each norot phase.  There are
-- 3 phases: an optional preparation for the current pitch, a variable length
-- sustain, and an optional preparation for the next pitch.
norot_sequence :: Bool
    -> (PSignal.Transposed -> Cycle) -> (PSignal.Transposed -> Cycle)
    -> Maybe PSignal.Pitch -> Maybe PSignal.Pitch -> RealTime
    -> Derive.Deriver (Maybe PitchedCycle, Maybe PitchedCycle,
        Maybe PitchedCycle)
norot_sequence start_prepare sustain_cycle prepare_cycle cur_pitch next_pitch
        start = do
    -- It's ok for there to be no current pitch, because the sustain might
    -- not be played at all.  But if there's no pitch at all it's probably
    -- better to throw an error than silently emit no notes.
    when (all Maybe.isNothing [cur_pitch, next_pitch]) $
        Derive.throw "no current pitch and no next pitch"
    prepare_this <- case (start_prepare, cur_pitch) of
        (True, Just pitch) -> do
            pitch_t <- Derive.resolve_pitch start pitch
            return $ Just $ PitchedCycle pitch (prepare_cycle pitch_t)
        _ -> return Nothing
    sustain <- case cur_pitch of
        Nothing -> return Nothing
        Just pitch -> do
            pitch_t <- Derive.resolve_pitch start pitch
            return $ Just $ PitchedCycle pitch (sustain_cycle pitch_t)
    prepare_next <- case next_pitch of
        Nothing -> return Nothing
        Just next -> do
            next_t <- Derive.resolve_pitch start next
            return $ Just $ PitchedCycle next (prepare_cycle next_t)
    return (prepare_this, sustain, prepare_next)

data PitchedCycle = PitchedCycle !PSignal.Pitch !Cycle

-- | Figure out parameters for the sustain and prepare phases.
-- Why is this SO COMPLICATED.
--
-- TODO this is still used by Reyong.  If I can simplify reyong norot too
-- then I can get rid of it.
prepare_sustain :: Bool -> ScoreTime -> (Maybe Bool, Bool)
    -> Types.Orientation -> (ScoreTime, ScoreTime)
    -> (Maybe ((Bool, Bool), (ScoreTime, ScoreTime)),
        Maybe ((Bool, Bool), (ScoreTime, ScoreTime)))
prepare_sustain has_prepare note_dur (maybe_initial, final) orient
        (start, end) =
    (sustain, prepare)
    where
    sustain
        | has_sustain =
            Just ((initial, if has_prepare then False else final),
                (start, sustain_end))
        | otherwise = Nothing
        where
        initial = fromMaybe (orient == Types.Positive) maybe_initial
        sustain_end = end - if has_prepare then prepare_dur else 0
    prepare
        | has_prepare =
            Just ((True, final), (end - prepare_dur, end))
        | otherwise = Nothing
    dur = end - start
    -- False if all the time is taken up by the prepare.
    -- Default to no initial if this is immediately going into a prepare.  This
    -- is so I can use a 'nt>' for just prepare but line it up on the beat.
    -- I don't actually need this if I expect a plain 'nt>' to be negative.
    has_sustain = not has_prepare
        || (dur > prepare_dur1
            || dur > prepare_dur && maybe_initial == Just True)
    prepare_dur = note_dur * 3
    prepare_dur1 = note_dur * 4

infer_prepare :: Derive.PassedArgs a -> Maybe Bool
    -- ^ True to prepare, False to not, Nothing to prepare if this note touches
    -- the next one.
    -> Derive.Deriver (Maybe PSignal.Pitch)
infer_prepare _ (Just False) = return Nothing
infer_prepare args (Just True) = Args.lookup_next_pitch args
infer_prepare args Nothing
    | Args.next_start args /= Just (Event.max (Args.event args)) =
        return Nothing
    | otherwise = Args.lookup_next_pitch args

gangsa_norot :: NorotStyle -> Pasang ScoreT.Instrument
    -> Pasang (Pitch.Step, Pitch.Step) -> Cycle
gangsa_norot style pasang steps = Realization
    { interlocking = map (:[]) [s (fst pstep), p (snd pstep)]
    , non_interlocking = case style of
        Default -> map ((:[]) . both) [fst pstep, snd pstep]
        Diamond ->
            [ [p (fst pstep), s (fst sstep)]
            , [p (snd pstep), s (snd sstep)]
            ]
    }
    where
    both = kotekan_note Nothing
    p = kotekan_note (Just (polos pasang))
    s = kotekan_note (Just (sangsih pasang))
    pstep = polos steps
    sstep = sangsih steps

gangsa_norot_prepare :: NorotStyle -> Pasang ScoreT.Instrument
    -> Pasang (Pitch.Step, Pitch.Step) -> Cycle
gangsa_norot_prepare style pasang steps = Realization
    { interlocking =
        [ [p p2, s p2]
        , [p p2, s p2]
        , [s p1]
        , [p p2]
        ]
    , non_interlocking = case style of
        Default -> map (:[]) [muted_note (both p2), both p2, both p1, both p2]
        Diamond ->
            [ map muted_note [p p2, s s2]
            , [p p2, s s2]
            , [p p1, s s1]
            , [p p2, s s2]
            ]
    }
    where
    both = kotekan_note Nothing
    p = kotekan_note (Just (polos pasang))
    s = kotekan_note (Just (sangsih pasang))
    (p1, p2) = polos steps
    (s1, s2) = sangsih steps

norot_steps :: Scale.Scale -> Maybe Pitch.Pitch -> NorotStyle
    -> PSignal.Transposed
    -- ^ this is to figure out if the sangsih part will be in range
    -> Pasang (Pitch.Step, Pitch.Step)
norot_steps scale inst_top style pitch
    | out_of_range 1 = Pasang { polos = (-1, 0), sangsih = (-1, 0) }
    | otherwise = case style of
        Diamond -> Pasang { polos = (1, 0), sangsih = (-1, 0) }
        -- Sangsih is only used if non-interlocking and using Diamond style.
        -- So the snd pair should be ignored.
        Default -> Pasang { polos = (1, 0), sangsih = (1, 0) }
    where
    out_of_range steps = note_too_high scale inst_top $
        Pitches.transpose_d steps pitch

c_gender_norot :: Derive.Generator Derive.Note
c_gender_norot = Derive.generator module_ "gender-norot" Tags.inst
    "Gender-style norot."
    $ Sig.call ((,,,)
    <$> dur_env <*> kotekan_env <*> pasang_env <*> infer_initial_final_env)
    $ \(dur, kotekan, pasang, initial_final) -> Sub.inverting $ \args -> do
        pitch <- get_pitch args
        under_threshold <- under_threshold_function kotekan dur
        realize_kotekan_pattern_args args initial_final
            dur pitch under_threshold Repeat (gender_norot pasang)

gender_norot :: Pasang ScoreT.Instrument -> Cycle
gender_norot pasang = Realization
    { interlocking = [[s 1], [p 0], [s 1], [p 0]]
    , non_interlocking =
        [ [p (-1), s 1]
        , [p (-2), s 0]
        , [p (-1), s 1]
        , if include_unison then [p 0, s 0] else [s 0]
        ]
    }
    where
    include_unison = True -- TODO chance based on signal
    p = kotekan_note (Just (polos pasang))
    s = kotekan_note (Just (sangsih pasang))

-- * kotekan

kotekan_doc :: Doc.Doc
kotekan_doc =
    "Kotekan calls perform a pattern with `inst-polos` and `inst-sangsih`.\
    \ They line up at the end of the event but may also emit a note at the\
    \ start of the event, so use `cancel-pasang` to cancel the extra notes.\
    \ Ngubeng kotekan is naturally suited to positive duration, while majalan\
    \ is suited to negative duration."

c_kotekan_irregular :: KotekanStyle -> KotekanPattern
    -> Derive.Generator Derive.Note
c_kotekan_irregular default_style pattern =
    Derive.generator module_ "kotekan" Tags.inst
    ("Render a kotekan pattern where both polos and sangsih are explicitly\
    \ specified. This is for irregular patterns.\n" <> kotekan_doc)
    $ Sig.call ((,,,,)
    <$> style_arg default_style
    <*> dur_env <*> kotekan_env <*> pasang_env <*> infer_initial_final_env
    ) $ \(style, dur, kotekan, pasang, initial_final) ->
    Sub.inverting $ \args -> do
        pitch <- get_pitch args
        under_threshold <- under_threshold_function kotekan dur
        realize_kotekan_pattern_args args initial_final
            dur pitch under_threshold Repeat
            (kotekan_pattern pattern style pasang)

-- ** regular

c_kotekan_kernel :: Derive.Generator Derive.Note
c_kotekan_kernel =
    Derive.generator module_ "kotekan" Tags.inst
    ("Render a kotekan pattern from a kernel. The sangsih part is inferred.\n"
        <> kotekan_doc)
    $ Sig.call ((,,,,,,,,)
    <$> Sig.defaulted "rotation" (0 :: Double)
        "Rotate kernel to make a different pattern."
    <*> style_arg Telu
    <*> Sig.defaulted_env "sangsih" Sig.Both Call.Up
        "Whether sangsih is above or below polos."
    <*> Sig.environ "invert" Sig.Prefixed False "Flip the pattern upside down."
    <*> Sig.required_environ "kernel" Sig.Both kernel_doc
    <*> dur_env <*> kotekan_env <*> pasang_env <*> infer_initial_final_env
    ) $ \(rotation, style, sangsih_above, inverted, kernel_s, dur, kotekan,
        pasang, initial_final) ->
    Sub.inverting $ \args -> do
        kernel <- Derive.require_right id $ make_kernel (untxt kernel_s)
        pitch <- get_pitch args
        under_threshold <- under_threshold_function kotekan dur
        let cycle = realize_kernel sangsih_above style pasang
                ((if inverted then invert else id) (rotate rotation kernel))
        realize_kotekan_pattern_args args initial_final dur pitch
            under_threshold Repeat cycle

-- | For regular kotekan, the sangsih can be automatically derived from the
-- polos.
c_kotekan_regular :: Bool -> Maybe Text -> KotekanStyle
    -> Derive.Generator Derive.Note
c_kotekan_regular inverted maybe_kernel default_style =
    Derive.generator module_ "kotekan" Tags.inst
    ("Render a kotekan pattern from a kernel representing the polos.\
    \ The sangsih is inferred.\n" <> kotekan_doc)
    $ Sig.call ((,,,,,,)
    <$> maybe
        (Sig.defaulted_env "kernel" Sig.Both ("k-12-1-21" :: Text) kernel_doc)
        pure maybe_kernel
    <*> style_arg default_style
    <*> Sig.defaulted_env "sangsih" Sig.Both (Nothing :: Maybe Sig.Dummy)
        "Whether sangsih is above or below polos. If not given, sangsih will\
        \ be above if the polos ends on a low note or rest, below otherwise."
    <*> dur_env <*> kotekan_env <*> pasang_env <*> infer_initial_final_env
    ) $ \(kernel_s, style, sangsih_dir, dur, kotekan, pasang, initial_final) ->
    Sub.inverting $ \args -> do
        kernel <- Derive.require_right id $ make_kernel (untxt kernel_s)
        let sangsih_above = fromMaybe (infer_sangsih inverted kernel)
                sangsih_dir
        pitch <- get_pitch args
        under_threshold <- under_threshold_function kotekan dur
        let cycle = realize_kernel sangsih_above style pasang
                (if inverted then invert kernel else kernel)
        realize_kotekan_pattern_args args initial_final
            dur pitch under_threshold Repeat cycle
    where
    infer_sangsih inverted kernel = (if inverted then Call.invert else id) $
        case Lists.last kernel of
            Just High -> Call.Down
            _ -> Call.Up

c_kotekan_explicit :: Derive.Generator Derive.Note
c_kotekan_explicit =
    Derive.generator module_ "kotekan" Tags.inst
    "Render a kotekan pattern from explicit polos and sangsih parts."
    $ Sig.call ((,,,)
    <$> Sig.required "polos" "Polos part."
    <*> Sig.required "sangsih" "Sangsih part."
    <*> dur_env <*> pasang_env
    ) $ \(polos_s, sangsih_s, dur, pasang) -> Sub.inverting $ \args -> do
        let (expected, frac) = properFraction (Args.duration args / dur)
        when (frac /= 0) $ Derive.throw $ "event " <> showt (Args.duration args)
            <> " not evenly divisble by kotekan dur " <> showt dur
        polos_steps <- parse "polos" expected polos_s
        sangsih_steps <- parse "sangsih" expected sangsih_s
        pitch <- get_pitch args
        let realize = realize_explicit (Args.range args) dur pitch
        realize polos_steps (polos pasang)
            <> realize sangsih_steps (sangsih pasang)
    where
    parse name expected part_
        | Text.length part /= expected =
            Derive.throw $ name <> ": expected length of " <> showt expected
                <> " but was " <> showt (Text.length part)
        | otherwise = Derive.require_right ((part <> ":")<>) $
            mapM parse1 (untxt part)
        where part = Text.dropWhile (=='k') part_
    parse1 '-' = Right Nothing
    parse1 c = maybe (Left $ "expected digit or '-': " <> showt c)
        (Right . Just) (Num.readDigit c)

realize_explicit :: (ScoreTime, ScoreTime) -> ScoreTime -> PSignal.Pitch
    -> [Maybe Pitch.Step] -> ScoreT.Instrument -> Derive.NoteDeriver
realize_explicit (start, end) dur pitch notes inst = mconcat
    [ Derive.place t dur (note t transpose)
    | (t, Just transpose) <- zip (tail (Lists.range_ start dur)) notes
    ]
    where
    note t transpose =
        (if t >= end then Call.add_flags (Flags.infer_duration <> final_flag)
            else id) $
        Derive.with_instrument inst $
        Call.pitched_note (Pitches.transpose_d transpose pitch)

kernel_doc :: Doc.Doc
kernel_doc = "Polos part in transposition steps.\
    \ This will be normalized to end on the destination pitch.\
    \ It should consist of `-`, `1`, and `2`. You can start with `k` to\
    \ avoid needing quotes. Starting with `k` will also require the length to\
    \ be a multiple of 4."

realize_kernel :: Call.UpDown -> KotekanStyle
    -> Pasang ScoreT.Instrument -> Kernel -> Cycle
realize_kernel sangsih_above style pasang kernel =
    end_on_zero $ kernel_to_pattern kernel sangsih_above style pasang

-- *** implementation

realize_kotekan_pattern_args :: Derive.PassedArgs a -> (Maybe Bool, Bool)
    -> ScoreTime -> PSignal.Pitch -> (ScoreTime -> Bool) -> Repeat -> Cycle
    -> Derive.NoteDeriver
realize_kotekan_pattern_args args initial_final =
    realize_kotekan_pattern (infer_initial args initial_final)
        (Args.range args) (Args.orientation args)

-- | Take a Cycle, which is an abstract description of a pattern via
-- 'KotekanNote's, to real notes in a NoteDeriver.
realize_kotekan_pattern :: (Bool, Bool) -- ^ include (initial, final)
    -> (ScoreTime, ScoreTime) -> Types.Orientation -> ScoreTime -> PSignal.Pitch
    -> (ScoreTime -> Bool) -> Repeat -> Cycle -> Derive.NoteDeriver
realize_kotekan_pattern initial_final (start, end) orientation dur pitch
        under_threshold repeat cycle =
    realize_notes realize $
        realize_pattern repeat orientation initial_final start end dur get_cycle
    where
    get_cycle t
        | under_threshold t = interlocking cycle
        | otherwise = non_interlocking cycle
    realize (KotekanNote inst steps muted) =
        maybe id Derive.with_instrument inst $
        -- TODO the kind of muting should be configurable.  Or, rather I should
        -- dispatch to a zero dur note call, which will pick up whatever form
        -- of mute is configured.
        -- TODO I'm using 'm' for that now, right?
        (if muted then Call.add_attributes Attrs.mute else id) $
        Call.pitched_note (Pitches.transpose_d steps pitch)
    -- TODO It should no longer be necessary to strip flags from
    -- 'Call.pitched_note', because "" only puts flags on if the event is
    -- at the end of the track, and that shouldn't happen for these.  Still,
    -- Call.pitched_note should use a lower level note call that doesn't do
    -- things like that.

type Kernel = [Atom]
data Atom = Gap -- ^ a gap in the kotekan pattern
    | Rest -- ^ a rest will be filled in by the other part
    | Low | High
    deriving (Eq, Ord, Show)

instance Pretty Atom where
    format = Pretty.char . to_char
    formatList cs =
        "make_kernel \"" <> Pretty.text (txt (map to_char cs)) <> "\""

make_kernel :: [Char] -> Either Text Kernel
make_kernel ('k':cs)
    | length cs `mod` 4 /= 0 =
        Left $ "kernel's length " <> showt (length cs)
            <> " is not a multiple of 4: " <> showt cs
    | otherwise = mapM from_char cs
make_kernel cs = mapM from_char cs

from_char :: Char -> Either Text Atom
from_char c = case c of
    '_' -> Right Gap
    '-' -> Right Rest
    '1' -> Right Low
    '2' -> Right High
    _ -> Left $ "kernel must be one of `_-12`, but got " <> showt c

to_char :: Atom -> Char
to_char c = case c of
    Gap -> '_'
    Rest -> '-'
    Low -> '1'
    High -> '2'

-- | Make both parts end on zero by subtracting the pitch of the final
-- non-interlocking note.
end_on_zero :: Cycle -> Cycle
end_on_zero realization = Realization
    { interlocking = add (-steps) (interlocking realization)
    , non_interlocking = add (-steps) (non_interlocking realization)
    }
    where
    add steps = map $ map $ \note ->
        note { note_steps = steps + note_steps note }
    steps = fromMaybe 0 $ do
        final : _ <- Lists.last (non_interlocking realization)
        return $ note_steps final

kernel_to_pattern :: Kernel -> Call.UpDown -> KotekanStyle
    -> Pasang ScoreT.Instrument -> Cycle
kernel_to_pattern kernel sangsih_above kotekan_style pasang = Realization
    { interlocking = map interlock kernel
    , non_interlocking = map non_interlock kernel
    }
    where
    interlock atom = case (sangsih_above, kotekan_style) of
        (Call.Up, Telu) -> case atom of
            Gap -> []
            Rest -> [s 2]
            Low -> [p 0]
            High -> [p 1, s 1]
        (Call.Up, Pat) -> case atom of
            Gap -> []
            Rest -> [s 2]
            Low -> [p 0, s 3]
            High -> [p 1]
        (Call.Down, Telu) -> case atom of
            Gap -> []
            Rest -> [s (-1)]
            Low -> [p 0, s 0]
            High -> [p 1]
        (Call.Down, Pat) -> case atom of
            Gap -> []
            Rest -> [s (-1)]
            Low -> [p 0]
            High -> [p 1, s (-2)]
    non_interlock atom = case (sangsih_above, kotekan_style) of
        (Call.Up, Telu) -> case atom of
            Gap -> []
            Rest -> [both 2]
            Low -> [both 0]
            High -> [both 1]
        (Call.Up, Pat) -> case atom of
            Gap -> []
            Rest -> [p 2, s 2]
            Low -> [p 0, s 3]
            High -> [p 1, s 1]
        (Call.Down, Telu) -> case atom of
            Gap -> []
            Rest -> [both (-1)]
            Low -> [both 0]
            High -> [both 1]
        (Call.Down, Pat) -> case atom of
            Gap -> []
            Rest -> [p (-1), s (-1)]
            Low -> [p 0, s 0]
            High -> [p 1, s (-2)]
    p = kotekan_note (Just (polos pasang))
    s = kotekan_note (Just (sangsih pasang))
    both = kotekan_note Nothing

rotate :: Int -> [a] -> [a]
rotate n xs = cycle (rotations xs) !! n

rotations :: [a] -> [[a]]
rotations xs = xs : go xs (reverse xs)
    where
    go [] _ = []
    go _ [_] = []
    go _ [] = []
    go xs (z:zs) = p : go p zs
        where p = take len (z : xs)
    len = length xs

invert :: Kernel -> Kernel
invert = map $ \case
    Gap -> Gap
    Rest -> Rest
    High -> Low
    Low -> High

-- *** all kernels

-- | Find a kernel as a rotation or inversion of one of the standard ones.
find_kernel :: Kernel -> Maybe (Kernel, Bool, Int)
find_kernel kernel = lookup kernel variants
    where
    variants =
        [ (variant, (kernel, inverted, rotation))
        | kernel <- all_kernels
        , (variant, (inverted, rotation)) <- variations kernel
        ]
    all_kernels = [kernel_12_1_21, kernel_1_21_21, kernel_2_21_21]
    Right kernel_12_1_21 = make_kernel "-12-1-21"
    Right kernel_1_21_21 = make_kernel "-1-21-21"
    Right kernel_2_21_21 = make_kernel "-2-21-21"

    variations :: Kernel -> [(Kernel, (Bool, Int))]
    variations kernel_ = Lists.uniqueOn fst
        [ (variant, (inverted, rotate))
        | (inverted, kernel) <- [(False, kernel_), (True, invert kernel_)]
        , (rotate, variant) <- zip [0..] (rotations kernel)
        ]

-- ** implementation

data Repeat = Repeat | Once deriving (Show)
instance Pretty Repeat where pretty = showt

-- | (interlocking pattern, non-interlocking pattern)
--
-- Each list represents coincident notes.  [] is a rest.
type Cycle = Realization [[KotekanNote]]

data Note a = Note {
    note_start :: !ScoreTime
    , note_duration :: !ScoreTime
    -- | Used for 'final_flag'.
    , note_flags :: !Flags.Flags
    , note_data :: !a
    } deriving (Functor, Show)

instance Pretty a => Pretty (Note a) where
    format (Note start dur flags d) = Pretty.format (start, dur, flags, d)

add_flag :: Flags.Flags -> Note a -> Note a
add_flag flag n = n { note_flags = flag <> note_flags n }

-- | High level description of a note.  This goes into Note before it becomes
-- a Derive.NoteDeriver.
data KotekanNote = KotekanNote {
    -- | If Nothing, retain the instrument in scope.  Presumably it will be
    -- later split into polos and sangsih by a @unison@ or @kempyung@ call.
    note_instrument :: !(Maybe ScoreT.Instrument)
    , note_steps :: !Pitch.Step
    , note_muted :: !Bool
    } deriving (Show)

instance Pretty KotekanNote where
    format (KotekanNote inst steps muted) =
        Pretty.format (inst, steps, if muted then "+mute" else "+open" :: Text)

kotekan_note :: Maybe ScoreT.Instrument -> Pitch.Step -> KotekanNote
kotekan_note inst steps = KotekanNote
    { note_instrument = inst
    , note_steps = steps
    , note_muted = False
    }

muted_note :: KotekanNote -> KotekanNote
muted_note note = note { note_muted = True }

under_threshold_function :: (RealTime -> RealTime) -> ScoreTime
    -> Derive.Deriver (ScoreTime -> Bool) -- ^ say if a note at this time
    -- with the given duration would be under the kotekan threshold
under_threshold_function kotekan dur = do
    to_real <- Derive.real_function
    return $ \t ->
        let real = to_real t
        in to_real (t+dur) - real < kotekan real

-- | Repeatedly call a cycle generating function to create notes.  The result
-- will presumably be passed to 'realize_notes' to convert the notes into
-- NoteDerivers.
realize_pattern :: Repeat -- ^ Once will just call get_cycle at the start
    -- time.  Repeat will start the cycle at t+1 because t is the initial, so
    -- it's the end of the cycle.
    -> Types.Orientation -- ^ align to start or end
    -> (Bool, Bool)
    -> ScoreTime -> ScoreTime -> ScoreTime
    -> (ScoreTime -> [[a]]) -- ^ Get one cycle of notes, starting at the time.
    -> [Note a]
realize_pattern repeat orientation (initial, final) start end dur get_cycle =
    case repeat of
        Once -> concatMap realize $
            (if orientation == Types.Positive then zip else zip_end)
                (Lists.range start end dur) (get_cycle start)
        Repeat -> concatMap realize pairs
    where
    pairs = case orientation of
        Types.Positive -> cycles wrapped ts
        Types.Negative -> cycles_end get_cycle ts
        where ts = Lists.range start end dur
    -- Since cycles are end-weighted, I have to get the end of a cycle if an
    -- initial note is wanted.
    wrapped t
        | t == start = maybe [] (:[]) (Lists.last ns)
        | otherwise = ns
        where ns = get_cycle t
    realize (t, chord)
        | t >= end = if final
            then map (add_flag (Flags.infer_duration <> final_flag)) ns
            else []
        | t == start = if initial then ns else []
        | otherwise = ns
        where ns = map (Note t dur mempty) chord

-- | Pair each @t@ with an @a@, asking the function for more @a@s as needed.
cycles :: (t -> [a]) -> [t] -> [(t, a)]
cycles get_cycle = go
    where
    go [] = []
    go (t:ts) = case rest of
        Left ts -> pairs ++ go ts
        Right _ -> pairs
        where (pairs, rest) = Lists.zipRemainder (t:ts) (get_cycle t)

-- | This is like 'cycles', but the last cycle is aligned to the end of the
-- @t@s, chopping off the front of the cycle if necessary.
cycles_end :: (t -> [a]) -> [t] -> [(t, a)]
cycles_end get_cycle = shift . go
    where
    shift (pairs, rest_ns) = zip ts (drop (length rest_ns) ns ++ rest_ns)
        where (ts, ns) = unzip pairs
    go [] = ([], [])
    go (t:ts) = case rest of
        Left ts -> first (pairs++) (go ts)
        Right ns -> (pairs, ns)
        where (pairs, rest) = Lists.zipRemainder (t:ts) (get_cycle t)

-- | Like 'zip', but two sequences are aligned at at their ends, instead of
-- their starts.
zip_end :: [a] -> [b] -> [(a, b)]
zip_end xs ys = reverse (zip (reverse xs) (reverse ys))

-- | Turn Notes into a NoteDeriver.
realize_notes :: (a -> Derive.NoteDeriver) -> [Note a] -> Derive.NoteDeriver
realize_notes realize = mconcatMap $ \(Note start dur flags note) ->
    Derive.place start dur $ Call.add_flags flags $ realize note

-- | Style for non-interlocking norot.  Interlocking norot is always the upper
-- neighbor (or lower on the top key).
data NorotStyle =
    -- | Norot is emitted as the current instrument, which should be converted
    -- into kempyung or unison by a postproc.
    Default
    -- | Norot in the diamond pattern, where sangsih goes down.
    | Diamond
    deriving (Bounded, Eq, Enum, Show)

instance ShowVal.ShowVal NorotStyle
instance Typecheck.Typecheck NorotStyle
instance Typecheck.ToVal NorotStyle

data KotekanStyle = Telu | Pat deriving (Bounded, Eq, Enum, Show)
instance ShowVal.ShowVal KotekanStyle
instance Typecheck.Typecheck KotekanStyle
instance Typecheck.ToVal KotekanStyle

-- * postproc

c_unison :: Derive.Transformer Derive.Note
c_unison = Derive.transformer module_ "unison" Tags.postproc
    "Split part into unison polos and sangsih. Emit only polos if\
    \ `only=polos` and only sangsih if `only=sangsih`."
    $ Sig.callt pasang_env $ \pasang _args deriver -> do
        inst <- Call.get_instrument
        pasang <- Pasang <$> Derive.get_instrument (polos pasang)
            <*> Derive.get_instrument (sangsih pasang)
        Post.emap_asc_ (unison inst pasang) <$> deriver
    where
    unison inst pasang event
        | Score.event_instrument event == inst = [set polos, set sangsih]
        | otherwise = [event]
        where
        msg = "unison from " <> pretty inst
        set role = Score.add_log msg $ Post.set_instrument (role pasang) event

-- | I could do this in two different ways:  Eval normally, then eval with
-- +kempyung, and make instrument note call understand it.  Or, postproc,
-- transpose, and check if the nn is above a limit.  The first one would let
-- the instrument choose how it wants to interpret +kempyung while letting this
-- call remain generic, but let's face it, it only really means one thing.  The
-- second seems a little simpler since it doesn't need a cooperating note call.
--
-- So postproc it is.
c_kempyung :: Library.Calls Derive.Note
c_kempyung = Make.transform_notes module_ "kempyung" Tags.postproc
    "Split part into kempyung, with `polos-inst` below and `sangsih-inst`\
    \ above. If the sangsih would go out of range, it's forced into unison."
    ((,)
    <$> instrument_top_env <*> pasang_env
    ) $ \(maybe_top, pasang) deriver -> do
        pasang_inst <- Call.get_instrument
        pasang <- Pasang <$> Derive.get_instrument (polos pasang)
            <*> Derive.get_instrument (sangsih pasang)
        scale <- Call.get_scale
        let too_high = pitch_too_high scale maybe_top
        Post.emap_asc_ (kempyung too_high pasang_inst pasang) <$> deriver
    where
    kempyung too_high pasang_inst pasang event
        | Score.event_instrument event == pasang_inst =
            [ set ("low kempyung from " <> pretty pasang_inst) polos
            , transpose too_high $
                set ("high kempyung from " <> pretty pasang_inst) sangsih
            ]
        | otherwise = [event]
        where
        set msg role =
            Score.add_log msg $ Post.set_instrument (role pasang) event
    transpose too_high event
        | too_high transposed = event
        | otherwise = transposed
        where
        transposed = event
            { Score.event_pitch =
                -- TODO it's not really linear, but these pitches should be
                -- constant anyway.
                PSignal.map_y_linear (Pitches.transpose (Pitch.Diatonic 3))
                    (Score.event_pitch event)
            }

c_nyogcag :: Library.Calls Derive.Note
c_nyogcag = Make.transform_notes module_ "nyog" Tags.postproc
    "Nyog cag style. Split a single part into polos and sangsih parts by\
    \ assigning polos and sangsih to alternating notes."
    pasang_env $ \pasang deriver -> do
        inst <- Call.get_instrument
        pasang <- Pasang <$> Derive.get_instrument (polos pasang)
            <*> Derive.get_instrument (sangsih pasang)
        snd . Post.emap_asc (nyogcag inst pasang) True <$> deriver

nyogcag :: ScoreT.Instrument -> Pasang (ScoreT.Instrument, Derive.Instrument)
    -> Bool -> Score.Event -> (Bool, [Score.Event])
nyogcag pasang_inst pasang is_polos event =
    ( next_is_polos
    , if event_inst == pasang_inst then [with_inst event] else [event]
    )
    where
    next_is_polos
        | event_inst == pasang_inst = not is_polos
        | event_inst == fst (polos pasang) = False
        | event_inst == fst (sangsih pasang) = True
        | otherwise = is_polos
    event_inst = Score.event_instrument event
    with_inst =
        Post.set_instrument (if is_polos then polos pasang else sangsih pasang)

-- * realize calls

c_realize_gangsa :: Derive.Transformer Derive.Note
c_realize_gangsa = StaticMacro.check "c_realize_gangsa" $
    StaticMacro.transformer module_ "realize-gangsa" Tags.postproc doc
        [ StaticMacro.Call c_realize_noltol []
        , StaticMacro.Call c_cancel_pasang [StaticMacro.Var]
        , StaticMacro.Call Gender.c_realize_ngoret []
        ]
    where doc = "Combine the gangsa realize calls in the right order."

-- | (noltol-time, kotekan-dur, damp-dyn)
type NoltolArg = (RealTime, RealTime, Signal.Y)

noltol_arg :: Text
noltol_arg = "noltol"

c_noltol :: Derive.Transformer Derive.Note
c_noltol = Derive.transformer module_ "noltol" Tags.delayed
    "Play the transformed notes in noltol style. If the space between\
    \ notes of the same (instrument, hand) is above a threshold,\
    \ end the note with a `+mute`d copy of itself. This only happens if\
    \ the duration of the note is at or below the `kotekan-dur`."
    $ Sig.callt ((,,)
    <$> Sig.defaulted "time" (0.1 :: Double)
        "Play noltol if the time available exceeds this threshold."
    <*> Sig.defaulted "damp-dyn" (0.65 :: Double)
        "Damped notes are multiplied by this dyn."
    <*> dur_env
    ) $ \(threshold, damp_dyn, max_dur) args deriver -> do
        max_dur <- Call.real_duration (Args.start args) max_dur
        events <- deriver
        let times = Post.real_time_control threshold events
        return $ Post.emap1_ (put damp_dyn max_dur) $ Stream.zip times events
        where
        put damp_dyn max_dur (threshold, event) =
            Score.put_arg noltol_arg
                ((threshold, max_dur, damp_dyn) :: NoltolArg) event

c_realize_noltol :: Derive.Transformer Score.Event
c_realize_noltol = Derive.transformer module_ "realize-noltol"
    Tags.realize_delayed "Perform the annotations added by `noltol`."
    $ Sig.call0t $ \_args deriver -> realize_noltol_call =<< deriver

realize_noltol_call :: Stream.Stream Score.Event -> Derive.NoteDeriver
realize_noltol_call =
    Post.emap_s_ fst realize . Post.next_by Score.event_instrument
    where
    realize (event, next) = do
        (event, maybe_arg) <- Derive.require_right id $
            Score.take_arg noltol_arg event
        case maybe_arg of
            Nothing -> return $ Stream.from_event event
            Just arg -> realize_noltol arg event next

-- | If the next note of the same instrument is below a threshold, the note's
-- off time is replaced with a +mute.
realize_noltol :: NoltolArg -> Score.Event -> Maybe Score.Event
    -> Derive.NoteDeriver
realize_noltol (threshold, max_dur, damp_dyn) event next =
    return (Stream.from_event event) <> muted
    where
    muted
        | should_noltol = do
            start <- Derive.score (Score.event_end event)
            pitch <- Derive.require "no pitch" $
                Score.pitch_at (Score.event_start event) event
            -- I used to copy the note and apply +mute, but this is low level
            -- and wouldn't take the instrument's zero-dur config.  Also it
            -- meant that integration would come out with +mute.
            Derive.with_instrument (Score.event_instrument event) $
                Call.with_pitch pitch $
                Call.multiply_dynamic damp_dyn $
                Derive.place start 0 Call.note
        | otherwise = mempty
    should_noltol =
        Score.event_duration event RealTime.<= max_dur
        && maybe True ((>= threshold) . space) next
    space next = Score.event_start next - Score.event_end event

-- ** cancel-pasang

c_cancel_pasang :: Derive.Transformer Derive.Note
c_cancel_pasang = Derive.transformer module_ "cancel-pasang" Tags.postproc
    "This is like the `cancel` call, except it also knows how to cancel out\
    \ pasang instruments such that adjacent kotekan calls can have initial and\
    \ final notes, but won't get doubled notes."
    $ Postproc.make_cancel cancel_strong_final pasang_key

-- | Kotekan ends with a final, which cancels normal, but loses to strong.
-- This is like 'Postproc.cancel_strong_weak', except it adds 'final_flag',
-- so I can have the end of a kotekan override, but still be overidden
-- with an explicit strong note.
cancel_strong_final :: [Score.Event] -> Either Text [Score.Event]
cancel_strong_final events
    | not (null strongs) = merge strongs (finals ++ rest)
    | not (null finals) = merge finals rest
    | not (null normals) = merge normals weaks
    | otherwise = Right weaks
    where
    (strongs, finals, rest) = Lists.partition2
        (Score.has_flags Flags.strong) (Score.has_flags final_flag) events
    (weaks, normals) = List.partition (Score.has_flags Flags.weak) events
    merge strongs weaks =
        Right [Postproc.infer_duration_merged strong weaks | strong <- strongs]

-- | Match any of polos, sangsih, and pasang to each other.  Since polos and
-- sangsih together are considered one voice, a sangsih start is note end for
-- a polos note.
pasang_key :: Postproc.Key
    (Either ScoreT.Instrument (ScoreT.Instrument, ScoreT.Instrument),
        Maybe Text)
pasang_key e = (inst, get EnvKey.hand)
    where
    inst = case (get inst_polos, get inst_sangsih) of
        (Just p, Just s) -> Right (p, s)
        _ -> Left (Score.event_instrument e)
    get k = Env.maybe_val k (Score.event_environ e)

-- * implementation

-- | Get pitch for a kotekan call.
get_pitch :: Derive.PassedArgs a -> Derive.Deriver PSignal.Pitch
get_pitch = Call.get_pitch_here

style_arg :: KotekanStyle -> Sig.Parser KotekanStyle
style_arg deflt = Sig.defaulted_env "style" Sig.Both deflt "Kotekan style."

dur_env :: Sig.Parser ScoreTime
dur_env = Sig.environ_quoted "kotekan-dur" Sig.Unprefixed
    (DeriveT.quoted "ts" [DeriveT.str "s"]) "Duration of derived notes."

kotekan_env :: Sig.Parser (RealTime -> RealTime)
kotekan_env = fmap (RealTime.seconds .) $
    Sig.environ "kotekan" Sig.Unprefixed (0.15 :: RealTime)
        "If note durations are below this, divide the parts between polos and\
        \ sangsih."

infer_initial_final_env :: Sig.Parser (Maybe Bool, Bool)
infer_initial_final_env = (,)
    <$> Sig.environ "initial" Sig.Unprefixed (Nothing :: Maybe Sig.Dummy)
        "If true, include an initial note, which is the same as the final note.\
        \ This is suitable for the start of a sequence of kotekan calls.\
        \ If not given, infer false for negative duration, true for positive."
    <*> Sig.environ "final" Sig.Unprefixed True
        "If true, include the final note, at the event end."

infer_initial :: Derive.PassedArgs a -> (Maybe Bool, Bool) -> (Bool, Bool)
infer_initial args =
    first $ fromMaybe (not $ Event.is_negative (Args.event args))

initial_final_env :: Sig.Parser (Bool, Bool)
initial_final_env = (,)
    <$> Sig.environ "initial" Sig.Unprefixed True
        "If true, include an initial note, which is the same as the final note.\
        \ This is suitable for the start of a sequence of kotekan calls.\
        \ If not given, infer false for negative duration, true for positive."
    <*> Sig.environ "final" Sig.Unprefixed True
        "If true, include the final note, at the event end."

instrument_top_env :: Sig.Parser (Maybe Pitch.Pitch)
instrument_top_env = Sig.environ_key EnvKey.instrument_top
    (Nothing :: Maybe Sig.Dummy)
    "Top pitch this instrument can play. Normally the instrument sets\
    \ it via the instrument environ."

note_too_high :: Scale.Scale -> Maybe Pitch.Pitch -> PSignal.Transposed -> Bool
note_too_high scale maybe_top pitchv = fromMaybe False $ do
    top <- maybe_top
    note <- either (const Nothing) Just $ PSignal.pitch_note pitchv
    pitch <- either (const Nothing) Just $ Scale.scale_read scale mempty note
    return $ pitch > top

pitch_too_high :: Scale.Scale -> Maybe Pitch.Pitch -> Score.Event -> Bool
pitch_too_high scale maybe_top =
    maybe False (note_too_high scale maybe_top) . Score.initial_pitch

pasang_env :: Sig.Parser (Pasang ScoreT.Instrument)
pasang_env = Pasang
    <$> Sig.required_environ (Derive.ArgName inst_polos)
        Sig.Unprefixed "Polos instrument."
    <*> Sig.required_environ (Derive.ArgName inst_sangsih)
        Sig.Unprefixed "Sangsih instrument."

inst_polos :: Env.Key
inst_polos = "inst-polos"

inst_sangsih :: Env.Key
inst_sangsih = "inst-sangsih"

final_flag :: Flags.Flags
final_flag = Flags.flag "final"
