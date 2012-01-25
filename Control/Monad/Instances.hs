{-# LANGUAGE Safe #-}
{-# OPTIONS_NHC98 --prelude #-}
-- This module deliberately declares orphan instances:
{-# OPTIONS_GHC -fno-warn-orphans #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Monad.Instances
-- Copyright   :  (c) The University of Glasgow 2001
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- /This module is DEPRECATED and will be removed in the future!/
--
-- 'Functor' and 'Monad' instances for @(->) r@ and
-- 'Functor' instances for @(,) a@ and @'Either' a@.

module Control.Monad.Instances (Functor(..),Monad(..)) where

import Prelude
