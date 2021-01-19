-- Copyright 2018 Evan Laforge
-- This program is distributed under the terms of the GNU General Public
-- License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

-- | A higher level wrapper around "Network.Socket", since "Network" is
-- deprecated.
module Util.Network where
import qualified Control.Exception as Exception
import qualified Foreign
import qualified Foreign.C as C
import qualified Network.Socket as Socket
import qualified Network.Socket.Internal as Socket.Internal
import qualified System.IO as IO


data Addr = Unix FilePath | IP Socket.PortNumber
    deriving (Eq, Show)

listenUnix :: FilePath -> IO Socket.Socket
listenUnix fname = do
    socket <- unixSocket
    -- Make sure subprocesses don't inherit this.  Otherwise a subprocess such
    -- as lilypond causes the REPL command to block until the subprocess
    -- completes.
    Socket.withFdSocket socket Socket.setCloseOnExecIfNeeded
    Socket.bind socket (Socket.SockAddrUnix fname)
    Socket.listen socket 1
    return socket

withConnection :: Addr -> (IO.Handle -> IO a) -> IO a
withConnection addr action = do
    socket <- case addr of
        Unix {} -> unixSocket
        IP {} -> ipSocket
    -- Make sure to close the socket even if Socket.connect fails.  It will
    -- get closed twice if it doesn't, but Socket.close says it ignores errors.
    Exception.bracket_ (Socket.connect socket saddr) (Socket.close socket) $
        Exception.bracket (Socket.socketToHandle socket IO.ReadWriteMode)
            IO.hClose action
    where
    saddr = case addr of
        IP port -> Socket.SockAddrInet port
            (Socket.tupleToHostAddress (127, 0, 0, 1))
        Unix fname -> Socket.SockAddrUnix fname

unixSocket :: IO Socket.Socket
unixSocket = Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol

ipSocket :: IO Socket.Socket
ipSocket = Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol

-- | getHostName from Network.BSD, which is deprecated.
getHostName :: IO String
getHostName = do
    let size = 256
    Foreign.allocaArray0 size $ \cstr -> do
        Socket.Internal.throwSocketErrorIfMinus1_ "Network.getHostName" $
            c_gethostname cstr (fromIntegral size)
        C.peekCString cstr

foreign import ccall unsafe "gethostname"
   c_gethostname :: C.CString -> C.CSize -> IO C.CInt
