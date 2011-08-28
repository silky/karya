-- | Load and save files to update them to the latest version.  Useful when
-- a non-versioned datatype changes.
module App.Update where
import qualified System.Environment as Environment
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified Cmd.Serialize as Serialize


main :: IO ()
main = do
    args <- Environment.getArgs
    case args of
        [from_fn, to_fn] -> update from_fn to_fn
        _ -> fail_with "usage: update from_fn to_fn"

update :: String -> String -> IO ()
update from_fn to_fn = do
    either_state <- Serialize.unserialize from_fn
    case either_state of
        Left exc -> err_msg $
            "Error reading " ++ show from_fn ++ ": " ++ show exc
        Right (Serialize.SaveState st dt) ->
            Serialize.serialize to_fn (Serialize.SaveState st dt)

err_msg :: String -> IO ()
err_msg = IO.hPutStrLn IO.stderr

fail_with :: String -> IO ()
fail_with msg = do
    err_msg msg
    Exit.exitWith (Exit.ExitFailure 1)
