{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
module Main(main) where

import DNA.Channel.File (readDataMMap)
import DNA

import DDP
import DDP_Slice


----------------------------------------------------------------
-- Distributed dot product
--
-- Note that actors which do not spawn actors on other nodes do not
-- receive CAD.
----------------------------------------------------------------

ddpCollector :: CollectActor Double Double
ddpCollector = collectActor
    (\s a -> return $! s + a)
    (return 0)
    (return)

remotable [ 'ddpCollector
          ]

-- | Actor for calculating dot product
ddpDotProduct :: Actor (String,Slice) Double
ddpDotProduct = actor $ \(fname,size) -> do
    res <- selectMany (Frac 1) (NNodes 1) [UseLocal]
    r   <- select Local (N 0)
    shell <- startGroup res $(mkStaticClosure 'ddpProductSlice)
    shCol <- startCollector r $(mkStaticClosure 'ddpCollector)
    broadcastParam (fname,size) shell
    collect shell shCol
    res <- delayCollector Remote shCol
    await res

main :: IO ()
main = dnaRun rtable $ do
    b <- eval ddpDotProduct ("file.dat",Slice 0 20000000)
    liftIO $ putStrLn $ "RESULT: " ++ show b
  where
    rtable = DDP.__remoteTable
           . DDP_Slice.__remoteTable
           . Main.__remoteTable
