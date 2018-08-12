#!/usr/local/bin/runghc
{-# LANGUAGE OverloadedStrings #-}

-- Run cabal freeze, then use this to take out the base deps, so it has a
-- chance of working with another ghc version.
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.IO as Text.IO

import qualified System.Directory as Directory
import qualified System.Posix.Temp as Temp
import qualified System.Process as Process


main :: IO ()
main = do
    global <- getGlobalPackags
    freeze global "karya.cabal" "cabal.config"
    freeze global "data/all-deps.cabal" "data/all-deps.cabal.config"

-- Cabal is really awkward to script.
freeze :: [Text] -> FilePath -> FilePath -> IO ()
freeze global cabalFile freezeFile = do
    cabal <- Text.IO.readFile cabalFile
    tmp <- Temp.mkdtemp "/tmp/freeze_deps"
    constraints <- Directory.withCurrentDirectory tmp $ do
        Text.IO.writeFile "fake-project.cabal" cabal
        Process.callProcess "cabal" ["freeze"]
        parseConstraints . Text.lines <$> Text.IO.readFile "cabal.config"
    Text.IO.writeFile freezeFile $ Text.unlines $
        ("constraints:":) $
        mapInit (<>",") $ map (\(a, b) -> "    " <> Text.unwords [a, b]) $
        filter ((`notElem` global) . fst) constraints

getGlobalPackags :: IO [Text]
getGlobalPackags =
    map (Text.dropWhileEnd (=='-') . Text.dropWhileEnd (/='-') . Text.strip)
        . drop 1 . Text.lines . Text.pack
        <$> Process.readProcess "ghc-pkg" ["list", "--global"] ""

parseConstraints :: [Text] -> [(Text, Text)]
parseConstraints [] = []
parseConstraints (line:lines) =
    map (split . strip) (Text.dropWhile (/=' ') line : lines)
    where
    strip = Text.dropWhileEnd (==',') . Text.strip
    split s = case Text.words s of
        [a, b] -> (a, b)
        ws -> error $ "can't parse line: " ++ show ws

mapInit :: (a -> a) -> [a] -> [a]
mapInit _ [] = []
mapInit _ [x] = [x]
mapInit f (x:xs) = f x : mapInit f xs
