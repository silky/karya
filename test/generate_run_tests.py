#!/usr/bin/env python
"""usage: output.hs test_mod1.hs test_mod2.hs ...

Collect tests from the given modules and generate a haskell module that calls
the tests.  Test functions are any function starting with 'test_' or
'profile_'.  This module doesn't distinguish between tests and profiles, but
they should presumably be compiled separately since they required different
flags.

If a module has a function called 'initialize', it will be called as 'IO ()'
prior to the tests.  Since there is no tear down function, each test requiring
initialization will be called in its own subprocess. (TODO)

The generated haskell module takes a set of regexes, and will run tests that
match any regex.  If given a '--list' flag, it will just print the tests
instead of running them.

Tests are divided into interactive and auto variants.  Interactive tests want
to have a conversation with the user, so they're not appropriate to run
frequently.  Auto tests get an auto- prefix so you can avoid the interactive
ones.  TODO interactive should be removed
"""

import sys, os, re, subprocess


def main():
    if len(sys.argv) < 3:
        print ('usage: generate_run_tests.py output.hs input_test1.hs '
            'input_test2.hs ...')
        return 1

    out_fn = sys.argv[1]
    test_fns = sys.argv[2:]

    init_func = re.compile(r'^initialize .*=', re.MULTILINE)
    test_defs = {}
    init_funcs = {}
    for fn in test_fns:
        src = open(fn).read()
        lines = list(open(fn))
        test_defs[fn] = get_defs(list(enumerate(lines)))
        if not test_defs[fn]:
            print >>sys.stderr, 'Warning: no test_* defs in %r' % fn
        if init_func.search(''.join(lines)):
            init_funcs[fn] = '%s.initialize' % path_to_module(fn)

    output = hs_template % {
        'generator': sys.argv[0],
        'imports': '\n'.join(map(make_import, test_fns)),
        'all_tests': ',\n    '.join(make_tests(test_defs, init_funcs)),
        'argv0': hs_str(out_fn[:-3]), # strip .hs
    }
    subprocess.call(['mkdir', '-p', os.path.dirname(out_fn)])
    out = open(out_fn, 'w')
    out.write(output)
    out.close()


def get_defs(lines):
    # regexes are not liking me, so functional it is
    if not lines:
        return []
    i, line = lines[0]
    i += 1 # enumerate starts from 0
    m = re.match(r'^(?:test|profile)_[a-zA-Z0-9_]+ \=', line)
    if m:
        body, rest = span(
            lambda (_, line): line.startswith(' ') or line == '\n', lines[1:])
        body = ''.join(line for (_, line) in body)
        head = line.split(None, 1)
        return [(i, head[0], head[1]+body)] + get_defs(rest)
    else:
        return get_defs(lines[1:])

def span(f, xs):
    pre = []
    for i, x in enumerate(xs):
        if f(x):
            pre.append(x)
        else:
            break
    return pre, xs[i:]

def make_import(fn):
    return 'import qualified %s' % path_to_module(fn)

def path_to_module(path):
    return os.path.splitext(path)[0].replace('/', '.')

def make_tests(test_defs, init_funcs):
    out = []
    for fn, defs in test_defs.items():
        has_initialize = fn in init_funcs
        for (lineno, test_name, body) in defs:
            if fn in init_funcs:
                init = '(Just %s)' % init_funcs[fn]
            else:
                init = 'Nothing'
            sym = '%s.%s' % (path_to_module(fn), test_name)
            out.append('Test %s (%s >> return ()) %s %d %s %s' % (
                hs_str(sym), sym, hs_str(fn), lineno, init,
                hs_str(test_type(has_initialize, body))))
    return out

def test_type(has_initialize, func_body):
    interactive = any(re.search(r'\b%s\b' % sym, func_body)
        for sym in ['io_human', 'io_human_line'])
    if interactive:
        return 'interactive'
    elif has_initialize:
        return 'gui'
    else:
        return 'normal'

def hs_str(s):
    return '"%s"' % s.replace('"', '\\"').replace('\n', '\\n')

def hs_bool(b):
    return b and 'True' or 'False'


hs_template = r'''-- automatically generated by %(generator)s --
import Control.Monad
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.IORef as IORef
import qualified System.Environment
import qualified System.Exit
import qualified System.Console.GetOpt as GetOpt
import qualified System.Process as Process

import qualified Util.Regex as Regex
import qualified Util.Seq as Seq
import qualified Util.Test as Test

%(imports)s

-- System.Environment.getProgName strips the dir, so I can't use it to
-- reinvoke.
argv0 :: String
argv0 = %(argv0)s

data Test = Test
    { test_sym_name :: String
    , test_test :: IO ()
    , test_file :: String
    , test_line :: Int
    , test_initialize :: Maybe (IO () -> IO ())
    , test_type :: String
    }

test_name :: Test -> String
test_name test = test_type test ++ "-" ++ test_sym_name test

all_tests :: [Test]
all_tests = [
    %(all_tests)s
    ]

test_by_name :: Map.Map String Test
test_by_name = Map.fromList (zip (map test_name all_tests) all_tests)

data Flag = List | Noninteractive deriving (Eq, Show)

options :: [GetOpt.OptDescr Flag]
options =
    [ GetOpt.Option [] ["list"] (GetOpt.NoArg List) "display but don't run"
    , GetOpt.Option [] ["noninteractive"] (GetOpt.NoArg Noninteractive)
        "run though interactive tests without asking"
    ]

main :: IO ()
main = do
    args <- System.Environment.getArgs
    (flags, args) <- case GetOpt.getOpt GetOpt.Permute options args of
        (opts, n, []) -> return (opts, n)
        (_, _, errs) -> error $ "errors:\n" ++ concat errs
    run flags args

run :: [Flag] -> [String] -> IO ()
run flags args
    | List `elem` flags = print_tests
    | otherwise = do
        when (Noninteractive `elem` flags) $
            IORef.writeIORef Test.skip_human True
        print_tests
        let (init_tests, noninit_tests) =
                List.partition (Maybe.isJust . test_initialize) tests
        mapM_ run_test noninit_tests
        case init_tests of
            [test] -> run_test test
            _ -> mapM_ sub_run init_tests
    where
    tests = matching_tests args
    print_tests = mapM_ putStrLn (List.sort (map test_name tests))

sub_run :: Test -> IO ()
sub_run test = do
    putStrLn $ "subprocess: " ++ show argv0 ++ " " ++ show [test_name test]
    val <- Process.rawSystem argv0 [test_name test]
    case val of
        System.Exit.ExitFailure code -> void $ Test.failure_srcpos Nothing $
            "test returned " ++ show code ++ ": " ++ test_name test
        _ -> return ()

-- | Match all tests whose names match any regex, or if a test is an exact
-- match, just that test.
matching_tests :: [String] -> [Test]
matching_tests = concatMap go
    where
    go reg = case Map.lookup reg test_by_name of
        Just test -> [test]
        Nothing ->
            filter (Regex.matches (Regex.make reg) . test_name) all_tests

run_test :: Test -> IO ()
run_test test = do
    putStrLn $ "---------- run test "
        ++ test_file test ++ ": " ++ test_name test
    let name = last (Seq.split "." (test_name test))
    maybe id id (test_initialize test) $ Test.catch_srcpos
        (Just (test_file test, Just name, test_line test)) (test_test test)
    return ()
'''


if __name__ == '__main__':
    sys.exit(main())
