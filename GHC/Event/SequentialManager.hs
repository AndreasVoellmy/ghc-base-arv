{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE BangPatterns
           , CPP
           , ExistentialQuantification
           , NoImplicitPrelude
           , RecordWildCards
           , TypeSynonymInstances
           , FlexibleInstances
  #-}

module GHC.Event.SequentialManager
    ( -- * Types
      EventManager

      -- * Creation
    , new
    , newWith
    , newDefaultBackend

      -- * Running
    , finished
    , loop
    , step
    , shutdown
    , cleanup

      -- * Registering interest in I/O events
    , Event
    , evtRead
    , evtWrite
    , IOCallback
    , FdKey
    , registerFd
    , unregisterFd_
    , unregisterFd
    , closeFd
    , closeFd_
    , callbackTableVar
    , FdData
    ) where

#include "EventConfig.h"

------------------------------------------------------------------------
-- Imports
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar,
                                readMVar)
import Control.Exception (finally)
import Control.Monad ((=<<), forM_, liftM, sequence, when)
import Data.IORef (IORef, atomicModifyIORef, mkWeakIORef, newIORef, readIORef,
                   writeIORef)
import Data.Maybe (Maybe(..))
import Data.Monoid (mappend, mconcat, mempty)
import Data.Tuple (snd)
import GHC.Arr (Array, (!), listArray)
import GHC.Base
import GHC.Conc.Signal (runHandlers)
import GHC.Conc.Sync (yield)
import GHC.List (filter, replicate)
import GHC.Num (Num(..))
import GHC.Real (fromIntegral, mod)
import GHC.Show (Show(..))
import GHC.Event.Control
import GHC.Event.Internal (Backend, Event, evtClose, evtRead, evtWrite,
                           Timeout(..))
import qualified GHC.Event.Internal as I
import qualified GHC.Event.IntMap as IM
import GHC.Event.Unique (Unique, UniqueSource, newSource, newUnique)
import System.Posix.Types (Fd)

#if defined(HAVE_KQUEUE)
import qualified GHC.Event.KQueue as KQueue
#elif defined(HAVE_EPOLL)
import qualified GHC.Event.EPoll  as EPoll
#elif defined(HAVE_POLL)
import qualified GHC.Event.Poll   as Poll
#else
# error not implemented for this operating system
#endif

------------------------------------------------------------------------
-- Types

data FdData = FdData {
  fdKey         :: {-# UNPACK #-} !FdKey
  , fdEvents    :: {-# UNPACK #-} !Event
  , _fdCallback :: !IOCallback
  }

data FdKey = FdKey {
      keyFd     :: {-# UNPACK #-} !Fd
    , keyUnique :: {-# UNPACK #-} !Unique
    } deriving (Eq, Show)

-- | Callback invoked on I/O events.
type IOCallback = FdKey -> Event -> IO ()

data State = Created
           | Running
           | Dying
           | Finished
             deriving (Eq, Show)

-- | The event manager state.
data EventManager = EventManager
    { emBackend      :: !Backend
    , emFds          :: {-# UNPACK #-} !(Array Int (MVar (IM.IntMap [FdData])))
    , emState        :: {-# UNPACK #-} !(IORef State)
    , emUniqueSource :: {-# UNPACK #-} !UniqueSource
    , emControl      :: {-# UNPACK #-} !Control
    }

------------------------------------------------------------------------
-- Creation

handleControlEvent :: EventManager -> Fd -> Event -> IO ()
handleControlEvent mgr fd _evt = do
  msg <- readControlMessage (emControl mgr) fd
  case msg of
    CMsgWakeup      -> return ()
    CMsgDie         -> writeIORef (emState mgr) Finished
    CMsgSignal fp s -> runHandlers fp s

newDefaultBackend :: IO Backend
#if defined(HAVE_KQUEUE)
newDefaultBackend = KQueue.new
#elif defined(HAVE_EPOLL)
newDefaultBackend = EPoll.new
#elif defined(HAVE_POLL)
newDefaultBackend = Poll.new
#else
newDefaultBackend = error "no back end for this platform"
#endif

-- | Create a new event manager.
new :: IO EventManager
new = newWith =<< newDefaultBackend

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
  I.delete emBackend
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
                  error $ "GHC.Event.SequentialManager.loop: state is already "
                          ++ show state
 where
  go = do running <- step mgr
          when running (yield >> go)

step :: EventManager -> IO Bool
step mgr@EventManager{..} = do
  waitForIO
  state <- readIORef emState
  state `seq` return (state == Running)
 where
  waitForIO =
    do n <- I.pollNonBlock emBackend (onFdEvent mgr)
       when (n <= 0) (do yield
                         m <- I.pollNonBlock emBackend (onFdEvent mgr)
                         when
                           (m <= 0)
                           (do I.poll emBackend Forever (onFdEvent mgr)
                               return ())
                     )

arraySize :: Int
arraySize = 32

hashFd :: Fd -> Int
hashFd fd = fromIntegral fd `mod` arraySize
{-# INLINE hashFd #-}

callbackTableVar :: EventManager -> Fd -> MVar (IM.IntMap [FdData])
callbackTableVar mgr fd = emFds mgr ! hashFd fd

eventsOf :: [FdData] -> Event
eventsOf = mconcat . map fdEvents

nullToNothing :: [a] -> Maybe [a]
nullToNothing []       = Nothing
nullToNothing xs@(_:_) = Just xs

-- | Register interest in the given events, without waking the event
-- manager thread.  The 'Bool' return value indicates whether the
-- event manager ought to be woken.
registerControlFd :: EventManager -> Fd -> Event -> IO ()
registerControlFd mgr fd evs = I.modifyFd (emBackend mgr) fd mempty evs

-- | Does everything that closeFd does, except for updating the callback tables.
-- It assumes the caller will update the callback tables and that the caller
-- holds the callback table lock for the fd.
closeFd_ :: EventManager -> IM.IntMap [FdData] -> Fd -> IO (IM.IntMap [FdData])
closeFd_ mgr oldMap fd = do
  case IM.delete (fromIntegral fd) oldMap of
    (Nothing,  _)       -> return oldMap
    (Just fds, !newMap) -> do
      let oldEvs = eventsOf fds
      I.modifyFd (emBackend mgr) fd oldEvs mempty
      forM_ fds $ \(FdData reg ev cb) -> cb reg (ev `mappend` evtClose)
      return newMap

#if defined(HAVE_EPOLL)
newWith :: Backend -> IO EventManager
newWith be = do
  fdVars <- sequence $ replicate arraySize (newMVar IM.empty)
  let !iofds = listArray (0, arraySize - 1) fdVars
  ctrl <- newControl
  state <- newIORef Created
  us <- newSource
  _ <- mkWeakIORef state $ do
               st <- atomicModifyIORef state $ \s -> (Finished, s)
               when (st /= Finished) $ do
                 I.delete be
                 closeControl ctrl
  let mgr = EventManager { emBackend = be
                         , emFds = iofds
                         , emState = state
                         , emUniqueSource = us
                         , emControl = ctrl
                         }
  registerControlFd mgr (controlReadFd ctrl) evtRead
  registerControlFd mgr (wakeupReadFd ctrl) evtRead
  return mgr

------------------------------------------------------------------------
-- Registering interest in I/O events

-- | Register interest in the given events, without waking the event
-- manager thread.
registerFd_ :: EventManager -> IOCallback -> Fd -> Event -> IO FdKey
registerFd_ mgr@EventManager{..} cb fd evs = do
  u <- newUnique emUniqueSource
  let !reg = FdKey fd u
      !fd' = fromIntegral fd
      !fdd = FdData reg evs cb
  modifyMVar_ (emFds ! hashFd fd) $ \oldMap ->
    case IM.insertWith (++) fd' [fdd] oldMap of
      (Nothing,   n) -> do I.modifyFdOnce emBackend fd evs
                           return n
      (Just prev, n) -> do I.modifyFdOnce emBackend fd (combineEvents evs prev)
                           return n
  return reg
{-# INLINE registerFd_ #-}

-- | @registerFd mgr cb fd evs@ registers interest in the events @evs@
-- on the file descriptor @fd@.  @cb@ is called for each event that
-- occurs.  Returns a cookie that can be handed to 'unregisterFd'.
registerFd :: EventManager -> IOCallback -> Fd -> Event -> IO FdKey
registerFd = registerFd_
{-# INLINE registerFd #-}

combineEvents :: Event -> [FdData] -> Event
combineEvents ev [fdd] = mappend ev (fdEvents fdd)
combineEvents ev fdds = mappend ev (eventsOf fdds)
{-# INLINE combineEvents #-}

-- | Close a file descriptor in a race-safe way.
closeFd :: EventManager -> Fd -> IO ()
closeFd mgr fd = do
  do mfds <- modifyMVar (emFds mgr ! hashFd fd) $ \oldMap ->
       case IM.delete (fromIntegral fd) oldMap of
         (Nothing,  _)       -> return (oldMap, Nothing)
         (Just fds, !newMap) -> return (newMap, Just fds)
     case mfds of
       Nothing -> return ()
       Just fds -> do
         let oldEvs = eventsOf fds
         I.modifyFd (emBackend mgr) fd oldEvs mempty
         forM_ fds $ \(FdData reg ev cb) -> cb reg (ev `mappend` evtClose)

------------------------------------------------------------------------
-- Utilities

-- | Call the callbacks corresponding to the given file descriptor.
-- Combines invoking the callback and removing callbacks.  Note that
-- with the ONESHOT backends the callback does not perform the deregistration
-- with the backend, and hence does not need to be holding the callback table
-- lock.
onFdEvent :: EventManager -> Fd -> Event -> IO ()
onFdEvent mgr@EventManager{..} fd evs =
  if fd == controlReadFd emControl || fd == wakeupReadFd emControl
  then handleControlEvent mgr fd evs
  else do fdds <- modifyMVar (emFds ! hashFd fd) $ \oldMap ->
            case IM.delete (fromIntegral fd) oldMap of
                    (Nothing, _) -> return (oldMap, [])
                    (Just cbs, newmap) -> selectCallbacks newmap cbs
          forM_ fdds $ \(FdData reg _ cb) -> cb reg evs
  where
    fd' :: Int
    fd' = fromIntegral fd
    selectCallbacks ::
      IM.IntMap [FdData] -> [FdData] -> IO (IM.IntMap [FdData], [FdData])
    selectCallbacks curmap cbs = loop cbs [] []
      where
        loop [] fdds []     = return (curmap,cbs)
        loop [] fdds saved =
          return (snd $ IM.insertWith (\_ _ -> saved) fd' saved curmap, fdds)
        loop (fdd@(FdData reg evs' cb) : cbs') fdds saved
          | evs `I.eventIs` evs' = loop cbs' (fdd:fdds) saved
          | otherwise            = loop cbs' fdds (fdd:saved)

-- | Drop a previous file descriptor registration, without waking the
-- event manager thread.  The return value indicates whether the event
-- manager ought to be woken.
unregisterFd_ :: EventManager -> FdKey -> IO Bool
unregisterFd_ EventManager{..} (FdKey fd u) =
  do modifyMVar_ (emFds ! hashFd fd) $ \oldMap ->
       let dropReg = nullToNothing . filter ((/= u) . keyUnique . fdKey)
           fd'     = fromIntegral fd
       in case IM.updateWith dropReg fd' oldMap of
         (Nothing,   _)    -> return oldMap
         (Just prev, newm) -> return newm
     return False

-- | Drop a previous file descriptor registration.
unregisterFd :: EventManager -> FdKey -> IO ()
unregisterFd mgr reg
  = do unregisterFd_ mgr reg
       return ()
#else
newWith :: Backend -> IO EventManager
newWith be = do
  fdVars <- sequence $ replicate arraySize (newMVar IM.empty)
  let !iofds = listArray (0, arraySize - 1) fdVars
  ctrl <- newControl
  state <- newIORef Created
  us <- newSource
  _ <- mkWeakIORef state $ do
               st <- atomicModifyIORef state $ \s -> (Finished, s)
               when (st /= Finished) $ do
                 I.delete be
                 closeControl ctrl
  let mgr = EventManager { emBackend = be
                         , emFds = iofds
                         , emState = state
                         , emUniqueSource = us
                         , emControl = ctrl
                         }
  registerControlFd mgr (controlReadFd ctrl) evtRead
  registerControlFd mgr (wakeupReadFd ctrl) evtRead
  return mgr

------------------------------------------------------------------------
-- Registering interest in I/O events

-- | Register interest in the given events, without waking the event
-- manager thread.  The 'Bool' return value indicates whether the
-- event manager ought to be woken.
registerFd_ :: EventManager -> IOCallback -> Fd -> Event
                         -> IO (FdKey, Bool)
registerFd_ mgr@EventManager{..} cb fd evs = do
  u <- newUnique emUniqueSource
  let !reg  = FdKey fd u
      !fd'  = fromIntegral fd
      !fdd  = FdData reg evs cb
  modify <- modifyMVar (emFds ! hashFd fd) $ \oldMap ->
    let (!newMap, (oldEvs, newEvs)) =
          case IM.insertWith (++) fd' [fdd] oldMap of
            (Nothing,   n) -> (n, (mempty, evs))
            (Just prev, n) -> (n, pairEvents prev newMap fd')
        !modify = oldEvs /= newEvs
    in do when modify $ I.modifyFd emBackend fd oldEvs newEvs
          return (newMap, modify)
  return (reg, modify)
{-# INLINE registerFd_ #-}

-- | @registerFd mgr cb fd evs@ registers interest in the events @evs@
-- on the file descriptor @fd@.  @cb@ is called for each event that
-- occurs.  Returns a cookie that can be handed to 'unregisterFd'.
registerFd :: EventManager -> IOCallback -> Fd -> Event -> IO FdKey
registerFd mgr cb fd evs = do
  (r,wake) <- registerFd_ mgr cb fd evs
  when wake $ wakeManager mgr
  return r
{-# INLINE registerFd #-}

-- | Wake up the event manager.
wakeManager :: EventManager -> IO ()
wakeManager mgr = sendWakeup (emControl mgr)

pairEvents :: [FdData] -> IM.IntMap [FdData] -> Int -> (Event, Event)
pairEvents prev m fd = let l = eventsOf prev
                           r = case IM.lookup fd m of
                                 Nothing  -> mempty
                                 Just fds -> eventsOf fds
                       in (l, r)

-- | Drop a previous file descriptor registration, without waking the
-- event manager thread.  The return value indicates whether the event
-- manager ought to be woken.
unregisterFd_ :: EventManager -> FdKey -> IO Bool
unregisterFd_ EventManager{..} (FdKey fd u) =
  modifyMVar (emFds ! hashFd fd) $ \oldMap -> do
    let dropReg = nullToNothing . filter ((/= u) . keyUnique . fdKey)
        fd'     = fromIntegral fd
        (!newMap, (oldEvs, newEvs)) =
          case IM.updateWith dropReg fd' oldMap of
            (Nothing,   _)    -> (oldMap, (mempty, mempty))
            (Just prev, newm) -> (newm, pairEvents prev newm fd')
        !modify = oldEvs /= newEvs
    when modify $ I.modifyFd emBackend fd oldEvs newEvs
    return (newMap, modify)

-- | Drop a previous file descriptor registration.
unregisterFd :: EventManager -> FdKey -> IO ()
unregisterFd mgr reg = do
  wake <- unregisterFd_ mgr reg
  when wake $ wakeManager mgr

-- | Close a file descriptor in a race-safe way.
closeFd :: EventManager -> Fd -> IO ()
closeFd mgr fd = do
  modifyMVar_ (emFds mgr ! hashFd fd) $ closeFd_ fd
  wakeManager mgr

------------------------------------------------------------------------
-- Utilities

-- | Call the callbacks corresponding to the given file descriptor.
onFdEvent :: EventManager -> Fd -> Event -> IO ()
onFdEvent mgr fd evs =
  if fd == controlReadFd emControl || fd == wakeupReadFd emControl
  then handleControlEvent mgr fd evs
  else do fdMap <- readMVar (emFds mgr ! hashFd fd)
          case IM.lookup (fromIntegral fd) fdMap of
            Just cbs ->
              forM_ cbs $ \(FdData reg ev cb) ->
              when (evs `I.eventIs` ev) (unregisterFd_ mgr reg >> cb reg evs)
            Nothing  -> return ()
#endif
