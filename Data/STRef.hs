{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE CPP #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.STRef
-- Copyright   :  (c) The University of Glasgow 2001
-- License     :  BSD-style (see the file libraries/base/LICENSE)
-- 
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (uses Control.Monad.ST)
--
-- Mutable references in the (strict) ST monad.
--
-----------------------------------------------------------------------------

module Data.STRef (
        -- * STRefs
        STRef,          -- abstract, instance Eq
        newSTRef,       -- :: a -> ST s (STRef s a)
        readSTRef,      -- :: STRef s a -> ST s a
        writeSTRef,     -- :: STRef s a -> a -> ST s ()
        modifySTRef,    -- :: STRef s a -> (a -> a) -> ST s ()
        modifySTRef'    -- :: STRef s a -> (a -> a) -> ST s ()
 ) where

import Prelude

#ifdef __GLASGOW_HASKELL__
import GHC.ST
import GHC.STRef
#endif

#ifdef __HUGS__
import Hugs.ST
import Data.Typeable

#include "Typeable.h"
INSTANCE_TYPEABLE2(STRef,stRefTc,"STRef")
#endif

-- | Mutate the contents of an 'STRef'.
--
-- Be warned that 'modifySTRef' does not apply the function strictly.  This
-- means if the program calls 'modifySTRef' many times, but seldomly uses the
-- value, thunks will pile up in memory resulting in a space leak.  This is a
-- common mistake made when using an STRef as a counter.  For example, the
-- following will leak memory and likely produce a stack overflow:
--
-- >print $ runST $ do
-- >    ref <- newSTRef 0
-- >    replicateM_ 1000000 $ modifySTRef ref (+1)
-- >    readSTRef ref
--
-- To avoid this problem, use 'modifySTRef'' instead.
modifySTRef :: STRef s a -> (a -> a) -> ST s ()
modifySTRef ref f = writeSTRef ref . f =<< readSTRef ref

-- | Strict version of 'modifySTRef'
modifySTRef' :: STRef s a -> (a -> a) -> ST s ()
modifySTRef' ref f = do
    x <- readSTRef ref
    let x' = f x
    x' `seq` writeSTRef ref x'
