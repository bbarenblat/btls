{-# OPTIONS_GHC -Wno-missing-methods #-}

module Data.Hmac
  ( SecretKey(SecretKey)
  , Hmac
  , hmac
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as ByteString.Lazy
import qualified Data.ByteString.Unsafe as ByteString
import Foreign
       (FinalizerPtr, ForeignPtr, Ptr, Storable(alignment, peek, sizeOf),
        addForeignPtrFinalizer, alloca, allocaArray, mallocForeignPtr,
        withForeignPtr)
import Foreign.C.Types
import Foreign.Marshal.Unsafe (unsafeLocalState)
import Unsafe.Coerce (unsafeCoerce)

import Data.Digest.Internal
       (Algorithm(Algorithm), Digest(Digest), Engine, EvpMd,
        alwaysSucceeds, evpMaxMdSize, noEngine, requireSuccess)
import Foreign.Ptr.ConstantTimeEquals (constantTimeEquals)

type LazyByteString = ByteString.Lazy.ByteString

#include <openssl/hmac.h>

-- First, we build basic bindings to the BoringSSL HMAC interface.

-- | The BoringSSL @HMAC_CTX@ type, representing the state of a pending HMAC
-- operation.
data HmacCtx

instance Storable HmacCtx where
  sizeOf _ = #size HMAC_CTX
  alignment _ = #alignment HMAC_CTX

-- Imported functions from BoringSSL. See
-- https://commondatastorage.googleapis.com/chromium-boringssl-docs/hmac.h.html
-- for documentation.

foreign import ccall "openssl/hmac.h HMAC_CTX_init"
  hmacCtxInit :: Ptr HmacCtx -> IO ()

foreign import ccall "openssl/hmac.h HMAC_Init_ex"
  hmacInitEx' ::
       Ptr HmacCtx -> Ptr a -> CSize -> Ptr EvpMd -> Ptr Engine -> IO CInt

foreign import ccall "openssl/hmac.h HMAC_Update"
  hmacUpdate' :: Ptr HmacCtx -> Ptr CUChar -> CSize -> IO CInt

foreign import ccall "openssl/hmac.h HMAC_Final"
  hmacFinal' :: Ptr HmacCtx -> Ptr CUChar -> Ptr CUInt -> IO CInt

-- Some of these functions return 'CInt' even though they can never fail. Wrap
-- them to prevent warnings.

hmacUpdate :: Ptr HmacCtx -> Ptr CUChar -> CSize -> IO ()
hmacUpdate ctx bytes size = alwaysSucceeds $ hmacUpdate' ctx bytes size

-- Convert functions that can in fact fail to throw exceptions instead.

hmacInitEx :: Ptr HmacCtx -> Ptr a -> CSize -> Ptr EvpMd -> Ptr Engine -> IO ()
hmacInitEx ctx bytes size md engine =
  requireSuccess $ hmacInitEx' ctx bytes size md engine

hmacFinal :: Ptr HmacCtx -> Ptr CUChar -> Ptr CUInt -> IO ()
hmacFinal ctx out outSize = requireSuccess $ hmacFinal' ctx out outSize

-- Now we can build a memory-safe allocator.

-- | Memory-safe allocator for 'HmacCtx'.
mallocHmacCtx :: IO (ForeignPtr HmacCtx)
mallocHmacCtx = do
  fp <- mallocForeignPtr
  withForeignPtr fp hmacCtxInit
  addForeignPtrFinalizer hmacCtxCleanup fp
  return fp

foreign import ccall "&HMAC_CTX_cleanup"
  hmacCtxCleanup :: FinalizerPtr HmacCtx

-- Finally, we're ready to actually implement the HMAC interface.

-- | A secret key used as input to a cipher or HMAC. Equality comparisons on
-- this type are variable-time.
newtype SecretKey = SecretKey ByteString
  deriving (Eq, Ord, Show)

-- | A hash-based message authentication code. Equality comparisons on this type
-- are constant-time.
newtype Hmac = Hmac ByteString

instance Eq Hmac where
  (Hmac a) == (Hmac b) =
    unsafeLocalState $
    ByteString.unsafeUseAsCStringLen a $ \(a', size) ->
      ByteString.unsafeUseAsCStringLen b $ \(b', _) ->
        constantTimeEquals a' b' size

instance Show Hmac where
  show (Hmac m) = show (Digest m)

-- | Creates an HMAC according to the given 'Algorithm'.
hmac :: Algorithm -> SecretKey -> LazyByteString -> Hmac
hmac (Algorithm md) (SecretKey key) bytes =
  unsafeLocalState $ do
    ctxFP <- mallocHmacCtx
    withForeignPtr ctxFP $ \ctx -> do
      ByteString.unsafeUseAsCStringLen key $ \(keyBytes, keySize) ->
        hmacInitEx ctx keyBytes (fromIntegral keySize) md noEngine
      mapM_ (updateBytes ctx) (ByteString.Lazy.toChunks bytes)
      m <-
        allocaArray (fromIntegral evpMaxMdSize) $ \hmacOut ->
          alloca $ \pOutSize -> do
            hmacFinal ctx hmacOut pOutSize
            outSize <- fromIntegral <$> peek pOutSize
            -- As in 'Data.Digest.Internal', 'hmacOut' is a 'Ptr CUChar'. Have
            -- GHC reinterpret it as a 'Ptr CChar' so that it can be ingested
            -- into a 'ByteString'.
            ByteString.packCStringLen (unsafeCoerce hmacOut, outSize)
      return (Hmac m)
  where
    updateBytes ctx chunk =
      -- 'hmacUpdate' treats its @bytes@ argument as @const@, so the sharing
      -- inherent in 'ByteString.unsafeUseAsCStringLen' is fine.
      ByteString.unsafeUseAsCStringLen chunk $ \(buf, len) ->
        -- 'buf' is a 'Ptr CChar', but 'hmacUpdate' takes a 'Ptr CUChar', so we
        -- do the 'unsafeCoerce' dance yet again.
        hmacUpdate ctx (unsafeCoerce buf) (fromIntegral len)
