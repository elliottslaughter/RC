{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns    #-}
module DDP_Slice where

import Control.Monad
import qualified Data.Vector.Storable as S
import System.Directory ( removeFile )
import Foreign.Storable ( sizeOf )

import DNA
import DNA.Channel.File

import DDP

-- | Calculate dot product of slice of vector.
--
--  * Input:  slice of vectors which we want to use
--  * Output: dot product of slice
ddpProductSlice :: Actor Slice Double
ddpProductSlice = actor $ \(fullSlice) -> duration "vector slice" $ do
    -- Calculate offsets
    nProc <- groupSize
    rnk   <- rank
    -- FIXME: Bad!
    let slice@(Slice _ n) = scatterSlice (fromIntegral nProc) fullSlice !! rnk
    -- First we need to generate files on tmpfs
    vecChan <- duration "generate" $ eval (ddpGenerateVector Local) n
    -- Start local processes
    shellVA <- startActor (N 0) $ do
        useLocal
        return $(mkStaticClosure 'ddpComputeVector)
    shellVB <- startActor (N 0) $ do
        useLocal
        return $(mkStaticClosure 'ddpReadVector   )
    -- Connect actors
    sendParam slice                shellVA
    sendParam (vecChan, Slice 0 n) shellVB
    --
    futVA <- delay Local shellVA
    futVB <- delay Local shellVB
    --
    va <- duration "receive compute" $ await futVA
    vb <- duration "receive read"    $ await futVB
    -- Clean up, compute sum
    let dblSize = sizeOf (undefined :: Double)
    kernel "cleanup" [] $ liftIO $ deleteFileChan vecChan
    kernel "compute sum" [ FloatHint 0 (2 * fromIntegral n)
                         , MemHint (dblSize * (S.length va + S.length vb)) ] $ do
      return (S.sum $ S.zipWith (*) va vb :: Double)

-- | Calculate dot product of slice of vector.
--
--  Process will fail if rank is equal to 1
--
--  * Input:  slice of vectors which we want to use
--  * Output: dot product of slice 
ddpProductSliceFailure :: Actor Slice Double
ddpProductSliceFailure = actor $ \(fullSlice) -> duration "vector slice" $ do
  do  
    -- Calculate offsets
    nProc <- groupSize
    rnk   <- rank
    -- FIXME: Bad!
    let slice@(Slice _ n) = scatterSlice (fromIntegral nProc) fullSlice !! rnk
    -- First we need to generate files on tmpfs
    vecChan <- duration "generate" $ eval (ddpGenerateVector Local) n
    -- Start local processes
    shellVA <- startActor (N 0) $ do
        useLocal
        return $(mkStaticClosure 'ddpComputeVector)
    shellVB <- startActor (N 0) $ do
        useLocal
        return $(mkStaticClosure 'ddpReadVector   )
    -- Connect actors
    sendParam slice                shellVA
    sendParam (vecChan, Slice 0 n) shellVB
    --
    futVA <- delay Local shellVA
    futVB <- delay Local shellVB
    --
    when (rnk == 1) $
        error "Process killed"
    va <- duration "receive compute" $ await futVA
    vb <- duration "receive read"    $ await futVB
    -- Clean up, compute sum
    let dblSize = sizeOf (undefined :: Double)
    kernel "compute sum" [ FloatHint 0 (2 * fromIntegral n)
                         , MemHint (dblSize * 2 * fromIntegral n) ] $ do
      liftIO $ deleteFileChan vecChan
      return (S.sum $ S.zipWith (*) va vb :: Double)


remotable [ 'ddpProductSlice
          , 'ddpProductSliceFailure
          ]
