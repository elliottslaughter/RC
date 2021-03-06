{-# LANGUAGE TemplateHaskell #-}
module Main(main) where

import DNA

import DDP
import DDP_Slice


----------------------------------------------------------------
-- Distributed dot product
----------------------------------------------------------------

-- | Actor for calculating dot product
ddpDotProduct :: Actor Slice Double
ddpDotProduct = actor $ \size -> do
    shell <- startGroup (Frac 1) (NNodes 1) $ do
        useLocal
        return $(mkStaticClosure 'ddpProductSlice)
    shCol <- startCollector (N 0) $ do
        useLocal
        return $(mkStaticClosure 'ddpCollector)
    broadcast size shell
    connect shell shCol
    res <- delay Remote shCol
    await res

main :: IO ()
main = dnaRun rtable $ do
    -- Vector size:
    --
    -- > 100e4 doubles per node = 800 MB per node
    -- > 4 nodes
    let n        = 4*1000*1
        expected = fromIntegral n*(fromIntegral n-1)/2 * 0.1
    -- Run it
    b <- eval ddpDotProduct (Slice 0 n)
    unboundKernel "output" [] $ liftIO $ putStrLn $ concat
      [ "RESULT: ", show b
      , " EXPECTED: ", show expected
      , if b == expected then " -- ok" else " -- WRONG!"
      ]
  where
    rtable = DDP.__remoteTable
           . DDP_Slice.__remoteTable
