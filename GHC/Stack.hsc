-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.Stack
-- Copyright   :  (c) The University of Glasgow 2011
-- License     :  see libraries/base/LICENSE
-- 
-- Maintainer  :  cvs-ghc@haskell.org
-- Stability   :  internal
-- Portability :  non-portable (GHC Extensions)
--
-- Access to GHC's call-stack simulation
--
-----------------------------------------------------------------------------

{-# LANGUAGE UnboxedTuples, MagicHash, EmptyDataDecls #-}
module GHC.Stack (
    -- * Call stack
    currentCallStack,

    -- * Internals
    CostCentreStack,
    CostCentre,
    getCCCS,
    ccsCC,
    ccsParent,
    ccLabel,
    ccModule,
  ) where

import Foreign
import Foreign.C

import GHC.IO
import GHC.Base
import GHC.Ptr

#define PROFILING
#include "Rts.h"

data CostCentreStack
data CostCentre

getCCCS :: IO (Ptr CostCentreStack)
getCCCS = IO $ \s -> case getCCCS## s of (## s', addr ##) -> (## s', Ptr addr ##)

ccsCC :: Ptr CostCentreStack -> IO (Ptr CostCentre)
ccsCC p = (# peek CostCentreStack, cc) p

ccsParent :: Ptr CostCentreStack -> IO (Ptr CostCentreStack)
ccsParent p = (# peek CostCentreStack, prevStack) p

ccLabel :: Ptr CostCentre -> IO CString
ccLabel p = (# peek CostCentre, label) p

ccModule :: Ptr CostCentre -> IO CString
ccModule p = (# peek CostCentre, module) p

-- | returns a '[String]' representing the current call stack.  This
-- can be useful for debugging.
--
-- The implementation uses the call-stack simulation maintined by the
-- profiler, so it only works if the program was compiled with @-prof@
-- and contains suitable SCC annotations (e.g. by using @-fprof-auto@).
-- Otherwise, the list returned is likely to be empty or
-- uninformative.

currentCallStack :: IO [String]
currentCallStack = do
  let
    go ccs acc
     | ccs == nullPtr = return acc
     | otherwise = do
        cc  <- ccsCC ccs
        lbl <- peekCAString =<< ccLabel cc
        mdl <- peekCString =<< ccModule cc
        parent <- ccsParent ccs
        go parent ((mdl ++ '.':lbl) : acc)
  --
  ccs <- getCCCS
  go ccs []
