{-# LANGUAGE Trustworthy #-}

-- ----------------------------------------------------------------------------
-- | This module provides scalable event notification for file
-- descriptors and timeouts.
--
-- This module should be considered GHC internal.
--
-- ----------------------------------------------------------------------------

module GHC.Event
    ( -- * Types
      EventManager

      -- * Creation
    , getSystemEventManager

      -- * Registering interest in I/O events
    , Event
    , evtRead
    , evtWrite
    , IOCallback
    , FdKey(keyFd)
    , registerFd
    , unregisterFd
    , unregisterFd_
    , closeFd

      -- * Registering interest in timeout events
    , TimerManager
    , getTimerManager
    , TimeoutCallback
    , TimeoutKey
    , registerTimeout
    , updateTimeout
    , unregisterTimeout
    ) where

import GHC.Event.TimerManager
import GHC.Event.CapManager 
import GHC.Event.Thread (getSystemEventManager, getTimerManager)

