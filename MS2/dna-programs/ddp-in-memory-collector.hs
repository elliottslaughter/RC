{-# LANGUAGE TemplateHaskell #-}
module Main(main) where

import DNA.Channel.File (readDataMMap)
import DNA

import DDP
import DDP_Slice


----------------------------------------------------------------
-- Distributed dot product
----------------------------------------------------------------

ddpCollector :: CollectActor Double Double
ddpCollector = collectActor
    (\s a -> return $! s + a)
    (return 0)
    (return)

remotable [ 'ddpCollector
          ]

-- | Actor for calculating dot product
ddpDotProduct :: Actor Slice Double
ddpDotProduct = actor $ \size -> do
    res <- selectMany (Frac 1) (NNodes 1) [UseLocal]
    r   <- select Local (N 0)
    shell <- startGroup res Failout $(mkStaticClosure 'ddpProductSlice)
    shCol <- startCollector r $(mkStaticClosure 'ddpCollector)
    sendParam size $ broadcast shell
    connect shell shCol
    res <- delay Remote shCol
    await res

main :: IO ()
main = dnaRun rtable $ do
    b <- eval ddpDotProduct (Slice 0 (1*1000*1000))
    liftIO $ putStrLn $ "RESULT: " ++ show b
  where
    rtable = DDP.__remoteTable
           . DDP_Slice.__remoteTable
           . Main.__remoteTable
