-- Copyright 2013 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
-- | Run tests.  This is meant to be invoked via a main module generated by
-- "Util.Test.GenerateRunTests".
module Util.Test.RunTests where
import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.Chan as Chan
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Exception as Exception
import Control.Monad
import qualified Control.Monad.Fix as Fix

import qualified Data.List as List
import qualified Data.Maybe as Maybe
import Data.Monoid ((<>))
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.IO as Text.IO

import qualified Numeric
import qualified System.CPUTime as CPUTime
import qualified System.Console.GetOpt as GetOpt
import qualified System.Directory as Directory
import qualified System.Environment as Environment
import qualified System.Environment
import qualified System.Exit
import qualified System.IO as IO
import qualified System.Process as Process

import qualified Util.File as File
import qualified Util.Process
import qualified Util.Regex as Regex
import qualified Util.Seq as Seq
import qualified Util.Test.Testing as Testing


data Test = Test {
    -- | Name of the test function.
    testSymName :: Text
    -- | Run the test.
    , testRun :: IO ()
    -- | Test module filename.
    , testFilename :: FilePath
    -- | Line of the test function declaration.
    , testLine :: Int
    -- | Module-level metadata, declared as @meta@ in the test module toplevel.
    , testModuleMeta_ :: Maybe Testing.ModuleMeta
    }

testModuleMeta :: Test -> Testing.ModuleMeta
testModuleMeta = Maybe.fromMaybe Testing.moduleMeta . testModuleMeta_

testName :: Test -> Text
testName test = Text.intercalate "," tags <> "-" <> testSymName test
    where
    tags = if null tags_ then ["normal"] else tags_
    tags_ = Seq.unique_sort $ map (Text.toLower . showt) $
        Testing.tags (testModuleMeta test)

-- Prefix for lines with test metadata.
metaPrefix :: Text
metaPrefix = "===>"

data Flag = List | NonInteractive | Jobs ![String] | Subprocess
    deriving (Eq, Show)

options :: [GetOpt.OptDescr Flag]
options =
    [ GetOpt.Option [] ["list"] (GetOpt.NoArg List) "display but don't run"
    , GetOpt.Option [] ["jobs"]
        (GetOpt.ReqArg (Jobs . commas) "comma separated outputs")
        "output jobs, each one corresponds to a parallel job"
    , GetOpt.Option [] ["subprocess"] (GetOpt.NoArg Subprocess)
        "meant to be driven by --jobs: read test names on stdin"
    , GetOpt.Option [] ["noninteractive"] (GetOpt.NoArg NonInteractive)
        "run interactive tests noninteractively by assuming they all passed"
    ]
    where commas = Seq.split ","

-- | Called by the generated main function.
run :: String -> [Test] -> IO ()
run argv0 allTests = do
    IO.hSetBuffering IO.stdout IO.LineBuffering
    args <- System.Environment.getArgs
    (flags, args) <- case GetOpt.getOpt GetOpt.Permute options args of
        (opts, n, []) -> return (opts, n)
        (_, _, errs) -> do
            putStrLn "usage: $0 [ flags ] regex regex ..."
            putStr (GetOpt.usageInfo "Run tests that match any regex." options)
            putStrLn $ "\nerrors:\n" ++ concat errs
            System.Exit.exitFailure
    runTests argv0 allTests flags args

runTests :: String -> [Test] -> [Flag] -> [String] -> IO ()
runTests argv0 allTests flags args
    | List `elem` flags =
        mapM_ Text.IO.putStrLn $ List.sort $ map testName matches
    | otherwise = do
        when (NonInteractive `elem` flags) $
            Testing.modify_test_config $ \config ->
                config { Testing.config_skip_human = True }
        let isSubprocess = Subprocess `elem` flags
        let (serialized, nonserialized) = List.partition
                ((Testing.Interactive `elem`) . Testing.tags . testModuleMeta)
                (if isSubprocess then allTests else matches)
        let outputs = concat [outputs | Jobs outputs <- flags]
        if isSubprocess
            then subprocess nonserialized
            else do
                (if null outputs then mapM_ runTest
                    else runParallel argv0 outputs) nonserialized
                case serialized of
                    [test] -> runTest test
                    _ -> mapM_ (isolateSubprocess argv0) serialized
                        -- TODO write to head outputs instead of stdout
    where
    matches = matchingTests args allTests

isolateSubprocess :: String -> Test -> IO ()
isolateSubprocess argv0 test = do
    putStrLn $ "subprocess: " ++ show argv0 ++ " " ++ show [testName test]
    val <- Process.rawSystem argv0 [Text.unpack (testName test)]
    case val of
        System.Exit.ExitFailure code -> Testing.with_test_name (testName test) $
            void $ Testing.failure $
                "test returned " <> showt code <> ": " <> testName test
        _ -> return ()

-- * parallel jobs

-- | Run tests in parallel, redirecting stdout and stderr to each output.
runParallel :: FilePath -> [FilePath] -> [Test] -> IO ()
runParallel argv0 outputs tests = do
    let byModule = Seq.keyed_group_adjacent testFilename tests
    queue <- newQueue [(Text.pack name, tests) | (name, tests) <- byModule]
    Async.forConcurrently_ (map fst (zip outputs byModule)) $ \output ->
        jobThread argv0 output queue

-- | Pull tests off the queue and feed them to a single subprocess.
jobThread :: FilePath -> FilePath -> Queue (Text, [Test]) -> IO ()
jobThread argv0 output queue =
    Exception.bracket (IO.openFile output IO.AppendMode) IO.hClose $ \hdl -> do
        to <- Chan.newChan
        env <- Environment.getEnvironment
        -- Give each subprocess its own .tix, or they will stomp on each other
        -- and crash.
        from <- Util.Process.conversation argv0 ["--subprocess"]
            (Just (("HPCTIXFILE", output <> ".tix") : env)) to
        whileJust (takeQueue queue) $ \(name, tests) -> do
            put $ Text.unpack name
            Chan.writeChan to $ Util.Process.Text $
                Text.unwords (map testName tests) <> "\n"
            Fix.fix $ \loop -> Chan.readChan from >>= \case
                Util.Process.Stdout line -> Text.IO.hPutStrLn hdl line >> loop
                Util.Process.Stderr line
                    | line == testsCompleteLine -> return ()
                    | otherwise -> Text.IO.hPutStrLn hdl line >> loop
                Util.Process.Exit n -> put $ "completed early: " <> show n
        Chan.writeChan to Util.Process.EOF
        final <- Chan.readChan from
        case final of
            Util.Process.Exit n
                | n == 0 -> return ()
                | otherwise -> put $ "completed " <> show n
            _ -> put $ "expected Exit, but got " <> show final
    where
    put = putStr . ((output <> ": ")<>) . (<>"\n")

subprocess :: [Test] -> IO ()
subprocess allTests = void $ File.ignoreEOF $ forever $ do
    testNames <- Set.fromList . Text.words <$> Text.IO.getLine
    -- For some reason, I get an extra "" from getLine when the parent process
    -- closes the pipe.  From the documentation I think it should throw EOF.
    unless (Set.null testNames) $ do
        let tests = filter ((`Set.member` testNames) . testName) allTests
        mapM_ runTest tests
            `Exception.finally` Text.IO.hPutStrLn IO.stderr testsCompleteLine

-- | Signal to the caller that the current batch of tests are done.
testsCompleteLine :: Text
testsCompleteLine = "•complete•"

-- * run tests

-- | Match all tests whose names match any regex, or if a test is an exact
-- match, just that test.
matchingTests :: [String] -> [Test] -> [Test]
matchingTests regexes tests = concatMap match regexes
    where
    match reg = case List.find ((== Text.pack reg) . testName) tests of
        Just test -> [test]
        Nothing -> filter (Regex.matches (Regex.compileUnsafe reg) . testName)
            tests

runTest :: Test -> IO ()
runTest test = Testing.with_test_name name $ isolate $ do
    Text.IO.putStrLn $ Text.unwords [metaPrefix, "run-test", testName test]
    start <- CPUTime.getCPUTime
    Testing.initialize (testModuleMeta test) $
        catch (testSymName test) (testRun test)
    end <- CPUTime.getCPUTime
    -- CPUTime is in picoseconds.
    let secs = fromIntegral (end - start) / 10^12
    -- Grep for timing to make a histogram.
    Text.IO.putStrLn $ Text.unwords [metaPrefix, "timing ", testName test,
        Text.pack $ Numeric.showFFloat (Just 3) secs ""]
    return ()
    where name = last (Text.split (=='.') (testName test))

-- | Try to save and restore any process level state in case the test messes
-- with it.  Currently this just restores CWD, but probably there is more than
-- that.  For actual isolation probably a subprocess is necessary.
isolate :: IO a -> IO a
isolate = Directory.withCurrentDirectory "."

catch :: Text -> IO a -> IO ()
catch name action = do
    result <- Exception.try action
    case result of
        Left (exc :: Exception.SomeException) -> do
            void $ Testing.failure $ name <> " threw exception: " <> showt exc
            -- Die on async exception, otherwise it will try to continue
            -- after ^C or out of memory.
            case Exception.fromException exc of
                Just (exc :: Exception.AsyncException) -> Exception.throwIO exc
                Nothing -> return ()
        Right _ -> return ()


showt :: Show a => a -> Text
showt = Text.pack . show

-- * queue

-- | This is a simple channel which is written to once, and read from until
-- empty.
newtype Queue a = Queue (MVar.MVar [a])

newQueue :: [a] -> IO (Queue a)
newQueue = fmap Queue . MVar.newMVar

takeQueue :: Queue a -> IO (Maybe a)
takeQueue (Queue mvar) = MVar.modifyMVar mvar $ \as -> return $ case as of
    [] -> ([], Nothing)
    a : as -> (as, Just a)

whileJust :: Monad m => m (Maybe a) -> (a -> m ()) -> m ()
whileJust get action = Fix.fix $ \loop -> get >>= \case
    Nothing -> return ()
    Just a -> action a >> loop
