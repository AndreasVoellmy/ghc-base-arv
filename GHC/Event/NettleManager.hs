{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE BangPatterns
           , CPP
           , ExistentialQuantification
           , NoImplicitPrelude
           , RecordWildCards
           , TypeSynonymInstances
           , FlexibleInstances
  #-}

module GHC.Event.NettleManager
    ( -- * Types
      EventManager

      -- * Creation
    , new
    , newWith
    , newDefaultBackend

      -- * Running
    , finished
    , loop
    , shutdown
    , cleanup
    , wakeManager

      -- * Registering interest in I/O events
    , Event
    , evtRead
    , evtWrite
    , IOCallback
    , FdKey
--    , registerFd_
    , registerFd
--    , unregisterFd_
    , unregisterFd
    , closeFd
    ) where

#include "EventConfig.h"

------------------------------------------------------------------------
-- Imports

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (finally)
import Control.Monad ((=<<), forM_, liftM, sequence, sequence_, when)
import Data.IORef (IORef, atomicModifyIORef, mkWeakIORef, newIORef, readIORef,
                   writeIORef)
import Data.Maybe (Maybe(..))
import Data.Monoid (mappend, mconcat, mempty)
import GHC.Base
import GHC.Err (undefined)
import GHC.Conc.Signal (runHandlers)
import GHC.List (filter, replicate)
import GHC.Num (Num(..))
import GHC.Real ((/), fromIntegral , div)
import GHC.Show (Show(..))
import GHC.Event.Control
import GHC.Event.Internal (Event, evtClose, evtRead, evtWrite)
import System.Posix.Types (Fd)
import GHC.Conc (numCapabilities)
--import GHC.Arr
import GHC.IOArray
import GHC.Real ((/), fromIntegral, mod )
#if defined(HAVE_EPOLL)
import qualified GHC.Event.EPoll  as E
#else
# error not implemented for this operating system
#endif
------------------------------------------------------------------------
-- Types

data FdData = FdData {
      fdEvents    :: {-# UNPACK #-} !Event
    , _fdCallback :: !IOCallback
    }

-- | A file descriptor registration cookie.
type FdKey = Fd

-- | Callback invoked on I/O events.
type IOCallback = Event -> IO ()

data State = Created
           | Running
           | Dying
           | Finished
             deriving (Eq, Show)

-- | The event manager state.
data EventManager = EventManager
    { emBackend      :: !E.EPoll
    , emFds          :: {-# UNPACK #-} !(IOArray Int FdData)
    , emState        :: {-# UNPACK #-} !(IORef State)
    , emControl      :: {-# UNPACK #-} !Control
    }

{- for one
arraySize :: Int
arraySize = 2048

hashFd :: Fd -> Int
hashFd fd = fromIntegral fd
{-# INLINE hashFd #-}
-}
{- for two -}
{-
arraySize :: Int
arraySize = 2048 --1024 -- 128 --32 --8

hashFd :: Fd -> Int
hashFd fd = (fromIntegral fd `div` 2) -- `mod` arraySize
{-# INLINE hashFd #-}
-}

{- for n -}
numEventManagers :: Int
numEventManagers = 2 -- numCapabilities

arraySize :: Int
arraySize = 2048 --1024 -- 128 --32 --8

hashFd :: Fd -> Int
hashFd fd = (fromIntegral fd `div` numEventManagers) -- `mod` arraySize
{-# INLINE hashFd #-}


------------------------------------------------------------------------
-- Creation

handleControlEvent :: EventManager -> FdKey -> Event -> IO ()
handleControlEvent mgr reg _evt = do
  msg <- readControlMessage (emControl mgr) reg
  case msg of
    CMsgWakeup      -> return ()
    CMsgDie         -> writeIORef (emState mgr) Finished
    CMsgSignal fp s -> runHandlers fp s

newDefaultBackend :: IO E.EPoll
#if defined(HAVE_EPOLL)
newDefaultBackend = E.newEPoll
#else
newDefaultBackend = error "no back end for this platform"
#endif

-- | Create a new event manager.
new :: IO EventManager
new = newWith =<< newDefaultBackend

newWith :: E.EPoll -> IO EventManager
newWith be = do
  fdarray <- newIOArray (0, arraySize - 1) undefined
  -- fdVars <- sequence $ replicate arraySize (newIORef undefined)
  -- let !iofds = listArray (0, arraySize - 1) fdVars
  ctrl <- newControl
  state <- newIORef Created
  _ <- mkWeakIORef state $ do
               st <- atomicModifyIORef state $ \s -> (Finished, s)
               when (st /= Finished) $ do
                 E.delete be
                 closeControl ctrl
  let mgr = EventManager { emBackend = be
                         , emFds     = fdarray --iofds
                         , emState   = state
                         , emControl = ctrl
                         }
  _ <- registerFdInternal_ mgr (handleControlEvent mgr (controlReadFd ctrl)) (controlReadFd ctrl) 
  _ <- registerFdInternal_ mgr (handleControlEvent mgr (wakeupReadFd ctrl)) (wakeupReadFd ctrl) 
  return mgr

-- | Asynchronously shuts down the event manager, if running.
shutdown :: EventManager -> IO ()
shutdown mgr = do
  state <- atomicModifyIORef (emState mgr) $ \s -> (Dying, s)
  when (state == Running) $ sendDie (emControl mgr)

finished :: EventManager -> IO Bool
finished mgr = (== Finished) `liftM` readIORef (emState mgr)

cleanup :: EventManager -> IO ()
cleanup EventManager{..} = do
  writeIORef emState Finished
  E.delete emBackend
  closeControl emControl

------------------------------------------------------------------------
-- Event loop

-- | Start handling events.  This function loops until told to stop,
-- using 'shutdown'.
--
-- /Note/: This loop can only be run once per 'EventManager', as it
-- closes all of its control resources when it finishes.
loop :: EventManager -> IO ()
loop mgr@EventManager{..} = do
  state <- atomicModifyIORef emState $ \s -> case s of
    Created -> (Running, s)
    _       -> (s, s)
  case state of
    Created -> go `finally` cleanup mgr
    Dying   -> cleanup mgr
    _       -> do cleanup mgr
                  error $ "GHC.Event.Manager.loop: state is already " ++
                      show state
 where
  go = do running <- step mgr
          when running go

step :: EventManager -> IO Bool
step mgr@EventManager{..} = do
  E.pollForever emBackend (onFdEvent mgr)
  state <- readIORef emState
  state `seq` return (state == Running)


------------------------------------------------------------------------
-- Registering interest in I/O events

registerFdInternal_ :: EventManager -> IOCallback -> Fd -> IO ()
registerFdInternal_ EventManager{..} cb fd = do
  E.modifyFd emBackend fd mempty evtRead
  return ()


-- | Register interest in the given events, without waking the event
-- manager thread.  The 'Bool' return value indicates whether the
-- event manager ought to be woken.
registerFd_ :: EventManager -> IOCallback -> Fd -> IO ()
registerFd_ EventManager{..} cb fd = do
  writeIOArray emFds (hashFd fd) (FdData evtRead cb) --writeIORef (emFds ! (hashFd fd)) (FdData evtRead cb)
  E.oneShotRead emBackend fd 
  return ()
{-# INLINE registerFd_ #-}

-- | @registerFd mgr cb fd evs@ registers interest in the events @evs@
-- on the file descriptor @fd@.  @cb@ is called for each event that
-- occurs.  Returns a cookie that can be handed to 'unregisterFd'.
registerFd :: EventManager -> IOCallback -> Fd -> IO ()
registerFd mgr cb fd = do
  registerFd_ mgr cb fd
  -- wakeManager mgr
  -- return fd
{-# INLINE registerFd #-}

-- | Wake up the event manager.
wakeManager :: EventManager -> IO ()
wakeManager mgr = sendWakeup (emControl mgr)


-- | Drop a previous file descriptor registration, without waking the
-- event manager thread.  The return value indicates whether the event
-- manager ought to be woken.
unregisterFd :: EventManager -> FdKey -> IO ()
unregisterFd EventManager{..} fd =
  do writeIOArray emFds (hashFd fd) undefined --writeIORef (emFds ! (hashFd fd)) undefined
     E.modifyFd emBackend fd evtRead mempty
     return () 
    
{-
-- | Drop a previous file descriptor registration.
unregisterFd :: EventManager -> FdKey -> IO ()
unregisterFd mgr reg = do
  unregisterFd_ mgr reg
  wakeManager mgr
-}
-- | Close a file descriptor in a race-safe way.
closeFd :: EventManager -> (Fd -> IO ()) -> Fd -> IO ()
closeFd mgr close fd = do
  close fd
  --let ref = emFds mgr ! (hashFd fd)
  FdData ev cb <- readIOArray (emFds mgr) (hashFd fd) --readIORef ref
  writeIOArray (emFds mgr) (hashFd fd) undefined --writeIORef ref undefined 
  wakeManager mgr
  cb (ev `mappend` evtClose)

------------------------------------------------------------------------
-- Utilities

-- | Call the callbacks corresponding to the given file descriptor.
onFdEvent :: EventManager -> Fd -> Event -> IO ()
onFdEvent mgr@(EventManager{..}) fd evs = 
  if (fd == controlReadFd emControl || fd == wakeupReadFd emControl)
  then handleControlEvent mgr fd evs
  else do FdData ev cb <- readIOArray emFds (hashFd fd) --readIORef (emFds ! (hashFd fd)) 
          cb evs

