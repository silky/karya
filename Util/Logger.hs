{-# OPTIONS_GHC -XGeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{- | LoggerT is a specialization of WriterT which only supports 'record', and
    uses 'DList' for efficient appends.
-}
module Util.Logger where
import Prelude hiding (log)
import qualified Control.Monad.Error as Error
import qualified Control.Monad.Trans as Trans
import qualified Control.Monad.Writer as Writer
import qualified Data.DList as DList


type LoggerM w m = Writer.WriterT (DList.DList w) m
newtype LoggerT w m a = LoggerT (LoggerM w m a)
    deriving (Functor, Monad, Trans.MonadIO, Trans.MonadTrans,
        Error.MonadError e)
run_logger_t (LoggerT x) = x

-- | Record a msg to the log.
record :: (Monad m) => w -> LoggerT w m ()
record = LoggerT . Writer.tell . DList.singleton

record_list :: (Monad m) => [w] -> LoggerT w m ()
record_list = LoggerT . Writer.tell . DList.fromList

run :: Monad m => LoggerT w m a -> m (a, [w])
run m = do
    (val, msgs) <- (Writer.runWriterT . run_logger_t) m
    return (val, DList.toList msgs)
