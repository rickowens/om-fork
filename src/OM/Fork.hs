{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

{- | Provides the `ForkM` typeclass, and other related utilities. -}
module OM.Fork (
  forkC,
  ForkM(..),
  Actor(..),
  Responder,
  respond,
  call,
  cast,
) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar,
   Chan, writeChan)
import Control.Exception.Safe (SomeException, try, MonadCatch)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Logger (logError, askLoggerIO, runLoggingT,
  MonadLoggerIO, LoggingT, MonadLoggerIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT, runReaderT, ask)
import Data.Text (pack)
import System.Exit (ExitCode(ExitFailure))
import System.IO (hPutStrLn, stderr)
import System.Posix.Process (exitImmediately)

{- |
  Forks a critical thread. \"Critical\" in this case means that if the
  thread crashes for whatever reason, then the program cannot continue
  correctly, so we should crash the program instead of running in some
  kind of zombie broken state.
-}
forkC :: (ForkM m, MonadCatch m, MonadLoggerIO m)
  => String {- ^ The name of the critical thread, used for logging. -}
  -> m () {- ^ The IO to execute. -}
  -> m ()
forkC name action =
  forkM $ do
    result <- try action
    case result of
      Left err -> do
        let msg =
              "Exception caught in critical thread " ++ show name
              ++ ". We are crashing the entire program because we can't "
              ++ "continue without this thread. The error was: "
              ++ show (err :: SomeException)
        {- write the message to every place we can think of. -}
        $(logError) . pack $ msg
        liftIO (putStrLn msg)
        liftIO (hPutStrLn stderr msg)
        liftIO (exitImmediately (ExitFailure 1))
      Right v -> return v


{- |
  Class of monads that can be forked. I'm sure there is a better solution for
  this, maybe using MonadBaseControl or something. This needs looking into.
-}
class (Monad m) => ForkM m where
  forkM :: m () -> m ()

instance ForkM IO where
  forkM = void . forkIO

instance (ForkM m, MonadIO m) => ForkM (LoggingT m) where
  forkM action = do
    logging <- askLoggerIO
    lift . forkM $ runLoggingT action logging

instance (ForkM m) => ForkM (ReaderT a m) where
  forkM action = lift . forkM . runReaderT action =<< ask


{- | How to respond to a asynchronous message. -}
newtype Responder a = Responder {
    unResponder :: a -> IO ()
  }
instance Show (Responder a) where
  show _ = "Responder"


{- | The class of types that can act as the handle for an asynchronous actor. -}
class Actor a where
  {- | The type of messages associated with the actor. -}
  type Msg a
  {- | The channel through which messages can be sent to the actor. -}
  actorChan :: a -> Msg a -> IO ()
instance Actor (Chan m) where
  type Msg (Chan m) = m
  actorChan = writeChan



{- | Respond to an asynchronous message. -}
respond :: (MonadIO m) => Responder a -> a -> m ()
respond responder = liftIO . unResponder responder


{- | Send a message to an actor, and wait for a response. -}
call :: (Actor actor, MonadIO m) => actor -> (Responder a -> Msg actor) -> m a
call actor mkMessage = liftIO $ do
  mVar <- newEmptyMVar
  actorChan actor (mkMessage (Responder (putMVar mVar)))
  takeMVar mVar


{- | Send a message to an actor, but do not wait for a response. -}
cast :: (Actor actor, MonadIO m) => actor -> Msg actor -> m ()
cast actor = liftIO . actorChan actor


