-- Copyright 2017 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | Functions to deal with 'Korvai.Metadata'.  The type itself has to be
-- defined in "Solkattu.Korvai" to avoid a circular import.
module Solkattu.Metadata where
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Time.Calendar as Calendar

import qualified Util.CallStack as CallStack
import qualified Util.Lists as Lists
import qualified Util.Num as Num
import qualified Util.Parse as Parse
import qualified Util.Regex as Regex

import qualified Solkattu.Korvai as Korvai
import qualified Solkattu.Solkattu as Solkattu
import qualified Solkattu.Tags as Tags

import           Global


-- * query

scoreTag :: Text -> Korvai.Score -> [Text]
scoreTag tag = getTag tag . Korvai.scoreMetadata

-- | Get a korvai tag's values.
getTag :: Text -> Korvai.Metadata -> [Text]
getTag tag = Map.findWithDefault [] tag . Tags.untags . Korvai._tags

scoreLocation :: Korvai.Score -> Korvai.Location
scoreLocation = Korvai._location . Korvai.scoreMetadata

korvaiLocation :: Korvai.Korvai -> Korvai.Location
korvaiLocation = Korvai._location . Korvai.korvaiMetadata

showLocation :: Korvai.Location -> Text
showLocation (module_, line, name) =
    path <> ":" <> showt line <> " " <> name
    where path = Text.replace "." "/" module_ <> ".hs"

moduleVariable :: Korvai.Score -> Text
moduleVariable score = last (Text.splitOn "." module_) <> "." <> name
    where (module_, _, name) = scoreLocation score

-- * date

makeDate :: CallStack.Stack => Int -> Int -> Int -> Calendar.Day
makeDate y m d = either Solkattu.throw id $ checkDate y m d

checkDate :: Int -> Int -> Int -> Either Text Calendar.Day
checkDate y m d
    | Num.inRange 2012 2030 y && Num.inRange 1 13 m && Num.inRange 1 32 d =
        Right $ Calendar.fromGregorian (fromIntegral y) m d
    | otherwise = Left $ "invalid date: " <> showt (y, m, d)

-- * time

-- | (hour, minute, second)
type Time = (Int, Int, Int)

showRecording :: CallStack.Stack => Text -> Maybe (Time, Maybe Time) -> Text
showRecording url maybeRange = Text.unwords $ url : case maybeRange of
    Nothing -> []
    Just (start, end) -> showTime start : maybe [] ((:[]) . showTime) end
    -- TODO could recognize youtube urls and append the ?t=123


parseRecording :: Text -> Maybe (Text, Maybe (Time, Time))
parseRecording s = case Text.words s of
    url : range -> (url,) <$> parseRange range
    _ -> Nothing
    where
    parseRange [] = Just Nothing
    parseRange [start, end] = do
        start <- parseTime start
        end <- parseTime end
        return $ Just (start, end)
    parseRange _ = Nothing

parseTime :: Text -> Maybe Time
parseTime s = case Regex.groups time s of
    (_, groups) : _ -> Just (parse h, parse m, parse s)
        where h : m : s : _ = groups ++ repeat ""
    _ -> Nothing
    where
    Right time = Regex.compile "(\\d+h)?(\\d+m)?(\\d+s)?"
    parse :: Text -> Int
    parse = fromMaybe 0 . Parse.parse_maybe Parse.p_nat . Text.dropEnd 1

showTime :: CallStack.Stack => Time -> Text
showTime (h, m, s)
    | any (<0) [h, m, s] || any (>=60) [m, s] =
        Solkattu.throw $ "invalid time: " <> showt (h, m, s)
    | all (==0) [h, m, s] = "0s"
    | otherwise = mconcat $ concat
        [ [showt h <> "h" | h > 0]
        , [showt m <> "m" | m > 0]
        , [showt s <> "s" | s > 0]
        ]

-- * sections

-- | Get a section tag's values, concatenated and uniqued.
sectionTag :: Text -> Korvai.Score -> [Text]
sectionTag tag = Lists.unique
    . concatMap (Map.findWithDefault [] tag . Tags.untags) . sectionTags

sectionTags :: Korvai.Score -> [Tags.Tags]
sectionTags = map Korvai.sectionTags . Korvai.scoreSections
