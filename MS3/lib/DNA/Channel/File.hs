{-# LANGUAGE DeriveDataTypeable, DeriveGeneric, BangPatterns,
             ScopedTypeVariables, RankNTypes, StandaloneDeriving #-}

module DNA.Channel.File (
          FileChan
        , createFileChanImp
        , deleteFileChan
        , withFileChan
        , readFileChan
        , mmapFileChan
        ) where

import Control.Monad

import Data.Vector.Binary ()
import Data.Binary
import Data.Typeable

import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as MS

import Foreign
import Foreign.C.Types
import Foreign.C.String

import System.Directory
import System.FilePath
import System.IO
import System.Posix.Temp

import DNA.Types ( Location(..) )

data FileChan a = FileChan
  { fhPath :: FilePath
  , fhLocation :: Location
  }
  deriving (Typeable)

instance Binary (FileChan a) where
  put ch = do
    put (fhPath ch)
    put (fhLocation ch)
  get = do
    path <- get
    loc <- get
    return $ FileChan path loc

-- | Creates a file handle fit to be shared with another actor with
-- the given locality.
createFileChanImp :: FilePath -> Location -> String -> IO (Maybe (FileChan a))
createFileChanImp workDir loc name = do

    -- Decide parent directory
    let dirs = case loc of
          Local  -> ["/ramdisks", "/tmp", workDir]
          Remote -> [workDir]

    -- Use first directory that actually exists
    edirs <- filterM doesDirectoryExist dirs
    if null edirs then return Nothing else do

      -- Generate temporary directory
      dir <- mkdtemp (head edirs </> name)
      return $ Just $ FileChan{ fhPath = dir
                              , fhLocation = loc
                              }

-- | Deletes the file channel. This frees all files contained inside it.
deleteFileChan :: FileChan a -> IO ()
deleteFileChan ch = removeDirectoryRecursive (fhPath ch)

-- | Open a file in the file channel
withFileChan :: FileChan a -> String -> IOMode -> (Handle -> IO b) -> IO b
withFileChan ch name io = withFile (fhPath ch </> name) io

-- read a buffer from a file into pinned memory
-- arguments: buffer ptr, size, offset, path
foreign import ccall unsafe "read_data"
    c_read_data :: Ptr CDouble -> CLong -> CLong -> CString -> IO ()

-- read a buffer from a file into mmapped memory.
-- arguments: size (num of elements of double type), offset, path
foreign import ccall unsafe "read_data_mmap"
    c_read_data_mmap :: CLong -> CLong -> CString -> CString -> IO (Ptr CDouble)

-- Unmap buffer fir the vector
foreign import ccall unsafe "&munmap_data"
    c_munmap_data :: FunPtr (Ptr CLong -> Ptr CDouble -> IO ())

-- | Read the given portion of a vector from the file channel
readFileChan :: forall a b. Storable b
             => Int64 -- ^ Number of elements to read
             -> Int64 -- ^ Offset to start reading
             -> FileChan a -> String
             -> IO (S.Vector b)
readFileChan n o ch p = do
    mv <- MS.new (fromIntegral n) :: IO (MS.IOVector b)
    let size = fromIntegral $ sizeOf (undefined :: b)
    MS.unsafeWith mv $ \ptr ->
        withCString (fhPath ch </> p) $
            c_read_data (castPtr ptr) (size * fromIntegral n) (size * fromIntegral o)
    S.unsafeFreeze mv

mmapFileChan :: Int64 -> Int64 -> FileChan a -> String -> String -> IO (S.Vector Double)
mmapFileChan n o ch p nodeId =
    withCString (fhPath ch </> p) $ \path ->
    withCString nodeId $ \nodeStr -> do
        ptr  <- c_read_data_mmap (fromIntegral n) (fromIntegral o) path nodeStr
        -- NOTE: pointer with length is freed in c_munmap_data
        nPtr <- new (fromIntegral n :: CLong)
        fptr <- newForeignPtrEnv c_munmap_data nPtr ptr
        return $ S.unsafeFromForeignPtr0 (castForeignPtr fptr) (fromIntegral n)
