{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module GHC.Event.NewThread ( 
  ensureIOManagerIsRunning
  , shutdownManagers
  , threadWaitRead
  , threadWaitWrite
  , closeFdWith
  , threadDelay
  , registerDelay
  ) where 


import qualified GHC.Arr as A
import qualified GHC.Event as E

import System.Posix.Types (Fd)
import Control.Concurrent hiding (threadWaitRead,threadWaitWrite, threadDelay)

import qualified GHC.Event.Internal as E    
import qualified GHC.Event.Manager as NE
import qualified GHC.Event.SequentialManager as SM
import Foreign.C.Error
import Control.Exception
import Text.Printf
import Data.IORef
import GHC.Conc.Sync
import System.IO.Unsafe

shutdownManagers :: IO ()
shutdownManagers = 
  do mgrs <- getSystemEventManagers
     case mgrs of 
       Nothing -> return ()
       Just mgrArray -> sequence_ [ SM.shutdown mgr | (i,mgr) <- A.assocs mgrArray ]
     mtmgr <- getTimerManager
     case mtmgr of 
       Nothing -> return ()
       Just tmgr -> NE.shutdown tmgr

getSystemEventManager :: IO SM.EventManager
getSystemEventManager = 
  do Just mgrArray <- getSystemEventManagers
     t <- myThreadId
     (cap, _) <- threadCapability t
     return (mgrArray A.! cap)


getSystemEventManagers :: IO (Maybe (A.Array Int SM.EventManager))
getSystemEventManagers = readIORef eventManagerRef

getTimerManager :: IO (Maybe NE.EventManager)
getTimerManager = readIORef timerManagerRef


eventManagerRef :: IORef (Maybe (A.Array Int SM.EventManager))
eventManagerRef = unsafePerformIO $ do
  em <- newIORef Nothing
  return em
{-# NOINLINE eventManagerRef #-}  

timerManagerRef :: IORef (Maybe NE.EventManager)
timerManagerRef = unsafePerformIO $ do
  em <- newIORef Nothing
  return em
{-# NOINLINE timerManagerRef #-}  

ensureIOManagerIsRunning :: IO ()  
ensureIOManagerIsRunning = 
  do let numEventManagers = numCapabilities 
     mgrs <- sequence (replicate numEventManagers SM.new)
     let !mgrArray = A.listArray (0, numEventManagers - 1) mgrs
     writeIORef eventManagerRef (Just mgrArray)
     sequence_ [ do t <- forkOn i (SM.loop mgr) 
                    labelThread t (printf "IOManager%d" i)
               | (i,mgr) <- A.assocs mgrArray ]
     tmgr <- NE.new
     writeIORef timerManagerRef (Just tmgr)
     tid <- forkIO (NE.loop tmgr)
     labelThread tid "TimerManager"
     
threadWait :: NE.Event -> Fd -> IO ()
threadWait evt fd = mask_ $ do
  m <- newEmptyMVar
  !mgr <- getSystemEventManager 
  SM.registerFd_ mgr (putMVar m) fd evt
  evt' <- takeMVar m 
  if evt' `E.eventIs` E.evtClose
    then ioError $ errnoToIOError "threadWait" eBADF Nothing Nothing
    else return ()



threadWaitRead :: Fd -> IO ()
threadWaitRead = threadWait SM.evtRead
{-# INLINE threadWaitRead #-}

threadWaitWrite :: Fd -> IO ()
threadWaitWrite = threadWait SM.evtWrite
{-# INLINE threadWaitWrite #-}

closeFdWith :: (Fd -> IO ())        -- ^ Action that performs the close.
            -> Fd                   -- ^ File descriptor to close.
            -> IO ()
closeFdWith close fd = do
  !mgr <- getSystemEventManager
  SM.closeFd mgr close fd

threadDelay :: Int -> IO ()
threadDelay usecs = mask_ $ do
  Just mgr <- getTimerManager
  m <- newEmptyMVar
  reg <- NE.registerTimeout mgr usecs (putMVar m ())
  takeMVar m `onException` NE.unregisterTimeout mgr reg

registerDelay :: Int -> IO (TVar Bool)
registerDelay usecs = do
  t <- atomically $ newTVar False
  Just mgr <- getTimerManager
  _ <- NE.registerTimeout mgr usecs . atomically $ writeTVar t True
  return t
