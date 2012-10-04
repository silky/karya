{- | Implement the post-processor that fixes up negative durations.

    Arriving beats are implemented with negative duration.  An arriving beat is
    a beat which arrives at the end of a unit of time, instead of departing
    from the beginning.  This concept is usually associated with Indonesian
    music, but Western music includes arriving patterns such as cadences and
    grace notes, while Indonesian music includes departing patterns such as
    nruktuk.

    An arriving note is not a change in the sounding duration of the note, but
    is a higher level concept.  The harmonic scope of of a departing note
    extends after the note in the pitch context established by that note, while
    the scope of an arriving note precedes the sounding of the note, preparing
    for its arriving.  A note whose harmonic scope precedes the sounding of the
    note itself is naturally represented as an event with negative duration.

    However, since the physical sounding duration (which of course must always
    be positive) and harmonic scope of a note no longer coincide, the sounding
    duration of an arriving note is somewhat more implicit.  The rule is such:

    If the event lines up with the following event then the note will sound
    until the next note begins:

    @
        --|--|
          |++|++...
    @

    If the event doesn't line up, then the empty space is taken as a rest,
    and the note is played up until the arrival of the rest:

    @
        --|   --|
          |+++  |++...
    @

    An arriving note followed by a departing note will sound until the
    beginning of the departing note, and a departing note followed by an
    arriving note is unchanged.

    Note that final note, if it is an arriving note, has an ambiguous duration
    (represented as @...@ above).  The @negative-duration@ post processor takes
    an argument for that, but you can also specify the duration of the final
    note easily enough by making it a departing note.
-}
module Derive.Call.Post.NegativeDur where
import Util.Control
import qualified Derive.CallSig as CallSig
import qualified Derive.Derive as Derive
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score
import qualified Derive.Stack as Stack

import Types


note_calls :: Derive.NoteCallMap
note_calls = Derive.make_calls [("negative-duration", c_negative_duration)]

c_negative_duration :: Derive.NoteCall
c_negative_duration = Derive.transformer "negative-duration"
    ("Postprocess events to replace negative durations with postive ones."
    ) $ CallSig.call1t
    ( CallSig.optional "default-duration" 1 $
        "Notes with negative duration have an implicit sounding duration"
        <> " which depends on the following note. This means that the"
        <> " duration of the final note of the score is ambiguous."
    ) $ \dur _args deriver -> negative_duration dur <$> deriver

negative_duration :: RealTime -> Derive.Events -> Derive.Events
negative_duration default_dur events = go events
    where
    go [] = []
    go (LEvent.Log log : events) = LEvent.Log log : go events
    go (LEvent.Event event : events) =
        LEvent.Event (set_dur dur event) : go events
        where dur = positive_duration default_dur event events
    set_dur dur event
        | Score.event_duration event /= dur =
            event { Score.event_duration = dur }
        | otherwise = event

positive_duration :: RealTime -> Score.Event -> Derive.Events -> RealTime
positive_duration default_dur event events = case find_next event events of
    Nothing -> default_dur
    Just next -> calculate_duration
        (Score.event_start event) (Score.event_duration event)
        (Score.event_start next) (Score.event_duration next)

find_next :: Score.Event -> Derive.Events -> Maybe Score.Event
find_next event = LEvent.find $ next_in_track (stack event) . stack
    where stack = Stack.to_ui . Score.event_stack

-- | Is the second stack from an event that occurs later on the same track as
-- the first?  This is more complicated than it may seem at first because the
-- second event could come from a different deriver.  So it should look like
-- @same ; same ; bid same / tid same / range higher ; *@.
next_in_track :: [Stack.UiFrame] -> [Stack.UiFrame] -> Bool
next_in_track (s1@(bid1, tid1, r1) : stack1) (s2@(bid2, tid2, r2) : stack2)
    | s1 == s2 = next_in_track stack1 stack2
    | bid1 == bid2 && tid1 == tid2 && r1 `before` r2 = True
    | otherwise = False
    where
    before (Just (s1, _)) (Just (s2, _)) = s1 < s2
    before _ _ = False
next_in_track _ _ = True

calculate_duration :: RealTime -> RealTime -> RealTime -> RealTime -> RealTime
calculate_duration cur_pos cur_dur next_pos next_dur
        -- Departing notes are not changed.
    | cur_dur > 0 = cur_dur
        -- Arriving followed by arriving with a rest in between extends to
        -- the arrival of the rest.
    | next_dur <= 0 && rest > 0 = rest
        -- Arriving followed by arriving with no rest, or an arriving note
        -- followed by a departing note will sound until the next note.
    | otherwise = next_pos - cur_pos
    where
    rest = next_pos + next_dur - cur_pos
