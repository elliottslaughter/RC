{-# LANGUAGE
      TypeSynonymInstances
    , FlexibleInstances
    , DeriveGeneric
    , DeriveDataTypeable
    , RankNTypes
    , ScopedTypeVariables
    , CPP
  #-}

module OskarReader
  ( TaskData(..)
  , Metrix(..)
  , WMaxMin(..)
  , tdVisibilitiesSize
  , tdUVWSize
  , tdVisibilityPtr
  , tdUVWPtr
  , finalizeTaskData
  , readOskarData
  , readOskarDataHeader
  , writeTaskData
  , readTaskData
  , readTaskDataHeader
  ) where

import OskarBinReaderFFI
import Foreign
import Foreign.C
import Foreign.Storable.Complex ()
import Text.Printf
import System.IO
import System.FilePath

import GHC.Generics (Generic)
import Data.Binary
import BinaryInstances ()
import Data.Typeable

foreign import ccall unsafe _aligned_malloc :: Int -> Int -> IO (Ptr a)

alignedMallocArray :: forall a. Storable a => Int -> Int -> IO (Ptr a)
alignedMallocArray size = _aligned_malloc (size * sizeOf (undefined :: a))

data TaskData = TaskData {
    tdBaselines  :: !Int
  , tdTimes      :: !Int
  , tdChannels   :: !Int
  , tdPoints     :: !Int
  , tdMetrix     :: !Metrix
  , tdBlMaxMin   :: !(Ptr WMaxMin)
  , tdVisibilies :: !(Ptr CxDouble)
  , tdUVWs       :: !(Ptr CDouble)
} deriving (Generic, Typeable)
instance Binary TaskData

tdVisibilitiesSize :: TaskData -> Int
tdVisibilitiesSize td = tdPoints td * 8 * sizeOf (undefined :: CDouble)

tdUVWSize :: TaskData -> Int
tdUVWSize td = tdPoints td * 3 * sizeOf (undefined :: CDouble)

-- | Computes pointer to a visibility in the task data
tdVisibilityPtr :: TaskData
                -> Int -- ^ Baseline
                -> Int -- ^ Timestep
                -> Int -- ^ Channel
                -> Int -- ^ Polarisation
                -> Ptr CxDouble
tdVisibilityPtr td bl t ch p
  = tdVisibilies td `advancePtr` (p + 4 * (ch + tdChannels td * (t + tdTimes td * bl)))

-- | Computes pointer to a position in the task data
tdUVWPtr :: TaskData
         -> Int -- ^ Baseline
         -> Int -- ^ Timestep
         -> Int -- ^ U/V/W
         -> Ptr CDouble
tdUVWPtr td bl t o
  = tdUVWs td `advancePtr` (o + 3 * (t + tdTimes td * bl))

#ifdef mingw32_HOST_OS
foreign import ccall unsafe _aligned_free :: Ptr a -> IO ()
#else
_aligned_free :: Ptr a -> IO ()
_aligned_free = free
#endif

finalizeTaskData :: TaskData -> IO ()
finalizeTaskData td = do
  free $ tdBlMaxMin td
  _aligned_free $ tdVisibilies td
  free $ tdUVWs td

readOskarData :: FilePath -> IO TaskData
readOskarData = readOskarDataGen False

readOskarDataHeader :: FilePath -> IO TaskData
readOskarDataHeader = readOskarDataGen True

readOskarDataGen :: Bool -> FilePath -> IO TaskData
readOskarDataGen headerOnly fname = withCString fname doRead
  where
    fi = fromIntegral
    throwErr = throwIf_ (/= 0) (\n -> printf "While trying to read binary file %s : %d" fname $ fi n)
    doRead namep = alloca $ \vptr -> do
      throwErr $ mkFromFile vptr namep
      nbls <- numBaselines vptr
      ntms <- numTimes    vptr
      nchs <- numChannels vptr
      -- it is in fact a product of previous three
      npts <- numPoints vptr
      let
        n = fi npts
        nb = fi nbls
        dummyMx = Metrix 0 0 0 0 0 0
        header = TaskData nb (fi ntms) (fi nchs) n dummyMx nullPtr nullPtr nullPtr
      if headerOnly then freeBinHandler vptr >> return header else do
        mmptr <- mallocArray nb
        visptr <- alignedMallocArray (n * 4) 32
        uvwptr <- mallocArray (n * 3)
        alloca $ \mptr -> do
          throwErr $ readAndReshuffle vptr visptr uvwptr mptr mmptr
          freeBinHandler vptr
          metrics <- peek mptr
          return $ header{ tdMetrix = metrics
                         , tdBlMaxMin = mmptr
                         , tdVisibilies = visptr
                         , tdUVWs = uvwptr
                         }

-- Our Binary instance is unrelated to deep serializing.
-- Here is deep from/to disk marchalling.
writeTaskData :: String -> TaskData -> IO ()
writeTaskData namespace (TaskData nb nt nc np metrics mmptr visptr uvwptr) =
  allocaArray 4 $ \ip -> do
    allocaArray 1 $ \pbc -> do
      let
        pokei = pokeElemOff ip
      pokei 0 nb
      pokei 1 nt
      pokei 2 nc
      pokei 3 np
      poke pbc metrics
      let
        writeb handle = do
          let hput = hPutBuf handle
          hput ip (4 * sizeOf (undefined :: Int))
          hput mmptr  (nb * 6 * cdb_siz)
          hput visptr (np * 8 * cdb_siz)
          hput uvwptr (np * 3 * cdb_siz)
      withBinaryFile (namespace </> "taskdata.dat") WriteMode writeb
  where
    cdb_siz = sizeOf (undefined :: CDouble)

readTaskDataHeader :: String -> IO TaskData
readTaskDataHeader = readTaskDataGen True

readTaskData :: String -> IO TaskData
readTaskData = readTaskDataGen False

readTaskDataGen :: Bool -> String -> IO TaskData
readTaskDataGen headerOnly namespace =
  allocaArray 4 $ \ip ->
    allocaArray 1 $ \pbc -> do
      withBinaryFile (namespace </> "taskdata.dat") ReadMode $ \handle -> do
        let hget p siz = throwIf_ (/= siz)
                           (\n -> printf "While reading taskdata from %s got %d instead of %d" namespace n siz)
                           (hGetBuf handle p siz)
        hget ip (4 * sizeOf (undefined :: Int))
        hget pbc (sizeOf (undefined :: Metrix))
        let
          peeki = peek . advancePtr ip
        nb   <- peeki 0
        nt   <- peeki 1
        nc   <- peeki 2
        np   <- peeki 3
        metrics <- peek pbc
        let header = TaskData nb nt nc np metrics nullPtr nullPtr nullPtr
        if headerOnly then return header else do
          mmptr  <- mallocArray (nb * 6)
          visptr <- alignedMallocArray (np * 4) 32
          uvwptr <- mallocArray (np * 3)
          hget mmptr (tdBaselines header)
          hget visptr (tdVisibilitiesSize header)
          hget uvwptr (tdUVWSize header)
          return header { tdBlMaxMin = mmptr
                        , tdVisibilies = visptr
                        , tdUVWs = uvwptr
                        }
