-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Utilities for writing Convert modules, which take Score.Events to the
-- performer specific events.
module Perform.ConvertUtil where
import qualified Data.Set as Set

import qualified Util.Log as Log
import qualified Cmd.Cmd as Cmd
import qualified Derive.LEvent as LEvent
import qualified Derive.Score as Score
import qualified Instrument.Common as Common
import qualified Instrument.Inst as Inst
import qualified Instrument.InstTypes as InstTypes

import Global


-- | Wrapper that performs common operations for convert functions.
-- Warn if the input isn't sorted, look up the instrument, and run
-- 'Cmd.inst_postproc'.
convert :: (Score.Event -> Inst.Backend -> InstTypes.Name -> [LEvent.LEvent a])
    -> (Score.Instrument -> Maybe (Cmd.Inst, InstTypes.Qualified))
    -> [Score.Event] -> [LEvent.LEvent a]
convert process lookup_inst = go Nothing Set.empty
    where
    go _ _ [] = []
    go maybe_prev warned (event : events) = increases $ case lookup_inst inst of
        Nothing
            -- Only warn the first time an instrument isn't seen, to avoid
            -- spamming the log.
            | inst `Set.member` warned -> go (Just event) warned events
            | otherwise -> warn ("instrument not found: " <> pretty inst)
                : go (Just event) (Set.insert inst warned) events
        Just (Inst.Inst backend common, InstTypes.Qualified _ name) ->
            converted ++ go (Just event) warned events
            where
            converted = map (LEvent.map_log (add_stack event)) $ process
                (Cmd.inst_postproc (Common.common_code common) event)
                backend name
        where
        inst = Score.event_instrument event
        -- Sorted is a postcondition of the deriver, verify that.
        increases events
            | Just prev <- maybe_prev,
                    Score.event_start event < Score.event_start prev =
                warn ("start of " <> Score.log_event event
                    <> " less than previous " <> Score.log_event prev)
                : events
            | otherwise = events
        warn = LEvent.Log . Log.msg Log.Warn (Just (Score.event_stack event))

add_stack :: Score.Event -> Log.Msg -> Log.Msg
add_stack event msg = msg { Log.msg_stack = Just (Score.event_stack event) }
