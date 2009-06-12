{-# OPTIONS_GHC -fno-implicit-prelude -funbox-strict-fields #-}
{-# LANGUAGE BangPatterns #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.IO.Encoding.UTF8
-- Copyright   :  (c) The University of Glasgow, 2009
-- License     :  see libraries/base/LICENSE
-- 
-- Maintainer  :  libraries@haskell.org
-- Stability   :  internal
-- Portability :  non-portable
--
-- UTF-8 Codec for the IO library
--
-- Portions Copyright   : (c) Tom Harper 2008-2009,
--                        (c) Bryan O'Sullivan 2009,
--                        (c) Duncan Coutts 2009
--
-----------------------------------------------------------------------------

module GHC.IO.Encoding.UTF8 (
  utf8,
  utf8_decode,
  utf8_encode,
  ) where

import GHC.Base
import GHC.Real
import GHC.Num
import GHC.IO
import GHC.IO.Exception
import GHC.IO.Buffer
import GHC.IO.Encoding.Types
import GHC.Word
import Data.Bits
import Data.Maybe

utf8 :: TextEncoding
utf8 = TextEncoding { mkTextDecoder = utf8_DF,
 	              mkTextEncoder = utf8_EF }

utf8_DF :: IO TextDecoder
utf8_DF = return (BufferCodec utf8_decode (return ()))

utf8_EF :: IO TextEncoder
utf8_EF = return (BufferCodec utf8_encode (return ()))

utf8_decode :: DecodeBuffer
utf8_decode 
  input@Buffer{  bufRaw=iraw, bufL=ir0, bufR=iw,  bufSize=_  }
  output@Buffer{ bufRaw=oraw, bufL=_,   bufR=ow0, bufSize=os }
 = let 
       loop !ir !ow
         | ow >= os || ir >= iw = done ir ow
         | otherwise = do
              c0 <- readWord8Buf iraw ir
              case c0 of
                _ | c0 <= 0x7f -> do 
                           writeCharBuf oraw ow (unsafeChr (fromIntegral c0))
                           loop (ir+1) (ow+1)
                  | c0 >= 0xc0 && c0 <= 0xdf ->
                           if iw - ir < 2 then done ir ow else do
                           c1 <- readWord8Buf iraw (ir+1)
                           if (c1 < 0x80 || c1 >= 0xc0) then invalid else do
                           writeCharBuf oraw ow (chr2 c0 c1)
                           loop (ir+2) (ow+1)
                  | c0 >= 0xe0 && c0 <= 0xef ->
                           if iw - ir < 3 then done ir ow else do
                           c1 <- readWord8Buf iraw (ir+1)
                           c2 <- readWord8Buf iraw (ir+2)
                           if not (validate3 c0 c1 c2) then invalid else do
                           writeCharBuf oraw ow (chr3 c0 c1 c2)
                           loop (ir+3) (ow+1)
                  | otherwise ->
                           if iw - ir < 4 then done ir ow else do
                           c1 <- readWord8Buf iraw (ir+1)
                           c2 <- readWord8Buf iraw (ir+2)
                           c3 <- readWord8Buf iraw (ir+3)
                           if not (validate4 c0 c1 c2 c3) then invalid else do
                           writeCharBuf oraw ow (chr4 c0 c1 c2 c3)
                           loop (ir+4) (ow+1)
         where
           invalid = if ir > ir0 then done ir ow else ioe_decodingError

       -- lambda-lifted, to avoid thunks being built in the inner-loop:
       done !ir !ow = return (if ir == iw then input{ bufL=0, bufR=0 }
                                          else input{ bufL=ir },
                         output{ bufR=ow })
   in
   loop ir0 ow0

ioe_decodingError :: IO a
ioe_decodingError = ioException
     (IOError Nothing InvalidArgument "utf8_decode"
          "invalid UTF-8 byte sequence" Nothing Nothing)

utf8_encode :: EncodeBuffer
utf8_encode
  input@Buffer{  bufRaw=iraw, bufL=ir0, bufR=iw,  bufSize=_  }
  output@Buffer{ bufRaw=oraw, bufL=_,   bufR=ow0, bufSize=os }
 = let 
      done !ir !ow = return (if ir == iw then input{ bufL=0, bufR=0 }
                                         else input{ bufL=ir },
                             output{ bufR=ow })
      loop !ir !ow
        | ow >= os || ir >= iw = done ir ow
        | otherwise = do
           (c,ir') <- readCharBuf iraw ir
           case ord c of
             x | x <= 0x7F   -> do
                    writeWord8Buf oraw ow (fromIntegral x)
                    loop ir' (ow+1)
               | x <= 0x07FF ->
                    if os - ow < 2 then done ir ow else do
                    let (c1,c2) = ord2 c
                    writeWord8Buf oraw ow     c1
                    writeWord8Buf oraw (ow+1) c2
                    loop ir' (ow+2)
               | x <= 0xFFFF -> do
                    if os - ow < 3 then done ir ow else do
                    let (c1,c2,c3) = ord3 c
                    writeWord8Buf oraw ow     c1
                    writeWord8Buf oraw (ow+1) c2
                    writeWord8Buf oraw (ow+2) c3
                    loop ir' (ow+3)
               | otherwise -> do
                    if os - ow < 4 then done ir ow else do
                    let (c1,c2,c3,c4) = ord4 c
                    writeWord8Buf oraw ow     c1
                    writeWord8Buf oraw (ow+1) c2
                    writeWord8Buf oraw (ow+2) c3
                    writeWord8Buf oraw (ow+3) c4
                    loop ir' (ow+4)
   in
   loop ir0 ow0

-- -----------------------------------------------------------------------------
-- UTF-8 primitives, lifted from Data.Text.Fusion.Utf8
  
ord2   :: Char -> (Word8,Word8)
ord2 c = assert (n >= 0x80 && n <= 0x07ff) (x1,x2)
    where
      n  = ord c
      x1 = fromIntegral $ (n `shiftR` 6) + 0xC0
      x2 = fromIntegral $ (n .&. 0x3F)   + 0x80

ord3   :: Char -> (Word8,Word8,Word8)
ord3 c = assert (n >= 0x0800 && n <= 0xffff) (x1,x2,x3)
    where
      n  = ord c
      x1 = fromIntegral $ (n `shiftR` 12) + 0xE0
      x2 = fromIntegral $ ((n `shiftR` 6) .&. 0x3F) + 0x80
      x3 = fromIntegral $ (n .&. 0x3F) + 0x80

ord4   :: Char -> (Word8,Word8,Word8,Word8)
ord4 c = assert (n >= 0x10000) (x1,x2,x3,x4)
    where
      n  = ord c
      x1 = fromIntegral $ (n `shiftR` 18) + 0xF0
      x2 = fromIntegral $ ((n `shiftR` 12) .&. 0x3F) + 0x80
      x3 = fromIntegral $ ((n `shiftR` 6) .&. 0x3F) + 0x80
      x4 = fromIntegral $ (n .&. 0x3F) + 0x80

chr2       :: Word8 -> Word8 -> Char
chr2 (W8# x1#) (W8# x2#) = C# (chr# (z1# +# z2#))
    where
      !y1# = word2Int# x1#
      !y2# = word2Int# x2#
      !z1# = uncheckedIShiftL# (y1# -# 0xC0#) 6#
      !z2# = y2# -# 0x80#
{-# INLINE chr2 #-}

chr3          :: Word8 -> Word8 -> Word8 -> Char
chr3 (W8# x1#) (W8# x2#) (W8# x3#) = C# (chr# (z1# +# z2# +# z3#))
    where
      !y1# = word2Int# x1#
      !y2# = word2Int# x2#
      !y3# = word2Int# x3#
      !z1# = uncheckedIShiftL# (y1# -# 0xE0#) 12#
      !z2# = uncheckedIShiftL# (y2# -# 0x80#) 6#
      !z3# = y3# -# 0x80#
{-# INLINE chr3 #-}

chr4             :: Word8 -> Word8 -> Word8 -> Word8 -> Char
chr4 (W8# x1#) (W8# x2#) (W8# x3#) (W8# x4#) =
    C# (chr# (z1# +# z2# +# z3# +# z4#))
    where
      !y1# = word2Int# x1#
      !y2# = word2Int# x2#
      !y3# = word2Int# x3#
      !y4# = word2Int# x4#
      !z1# = uncheckedIShiftL# (y1# -# 0xF0#) 18#
      !z2# = uncheckedIShiftL# (y2# -# 0x80#) 12#
      !z3# = uncheckedIShiftL# (y3# -# 0x80#) 6#
      !z4# = y4# -# 0x80#
{-# INLINE chr4 #-}

between :: Word8                -- ^ byte to check
        -> Word8                -- ^ lower bound
        -> Word8                -- ^ upper bound
        -> Bool
between x y z = x >= y && x <= z
{-# INLINE between #-}

validate3          :: Word8 -> Word8 -> Word8 -> Bool
{-# INLINE validate3 #-}
validate3 x1 x2 x3 = validate3_1 ||
                     validate3_2 ||
                     validate3_3 ||
                     validate3_4
  where
    validate3_1 = (x1 == 0xE0) &&
                  between x2 0xA0 0xBF &&
                  between x3 0x80 0xBF
    validate3_2 = between x1 0xE1 0xEC &&
                  between x2 0x80 0xBF &&
                  between x3 0x80 0xBF
    validate3_3 = x1 == 0xED &&
                  between x2 0x80 0x9F &&
                  between x3 0x80 0xBF
    validate3_4 = between x1 0xEE 0xEF &&
                  between x2 0x80 0xBF &&
                  between x3 0x80 0xBF

validate4             :: Word8 -> Word8 -> Word8 -> Word8 -> Bool
{-# INLINE validate4 #-}
validate4 x1 x2 x3 x4 = validate4_1 ||
                        validate4_2 ||
                        validate4_3
  where 
    validate4_1 = x1 == 0xF0 &&
                  between x2 0x90 0xBF &&
                  between x3 0x80 0xBF &&
                  between x4 0x80 0xBF
    validate4_2 = between x1 0xF1 0xF3 &&
                  between x2 0x80 0xBF &&
                  between x3 0x80 0xBF &&
                  between x4 0x80 0xBF
    validate4_3 = x1 == 0xF4 &&
                  between x2 0x80 0x8F &&
                  between x3 0x80 0xBF &&
                  between x4 0x80 0xBF
