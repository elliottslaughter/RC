{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
-- |
-- Functions which execute DNA routines on remote nodes. Below is
-- general algorithms:
--
--  1. Obtain auxiliary parameters ('ActorParam')
--
--  2. Send receive address back to parent ('RecvAddr')
--
--  3. Receive initial parameters and execute program
--
--  4. Send result to latest destination received
--
module DNA.Interpreter.Run (
      -- * Run actors
      runActor
    , runActorManyRanks
    , runCollectActor
    -- , runCollectActorMR
    -- , runMapperActor
    , runDnaParam 
      -- * Helpers
    , doGatherM
    , doGatherDna
      -- * CH
    , runActor__static
    , runActorManyRanks__static
    , runCollectActor__static
    -- , runCollectActorMR__static
    -- , runMapperActor__static
    , __remoteTable
    ) where

import Control.Monad
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Control.Distributed.Process.Closure
import Data.Typeable (Typeable)
import System.Random

import DNA.CH
import DNA.Types
import DNA.DSL
import DNA.Interpreter.Types
import DNA.Interpreter.Message


----------------------------------------------------------------
-- Functions for starting actors
----------------------------------------------------------------

-- | Start execution of standard actor
runActor :: Actor a b -> Process ()
runActor (Actor action) = do
    -- Obtain parameters
    p <- expect
    -- Create channels for communication
    (chSendParam,chRecvParam) <- newChan
    -- Send data destination back
    sendChan (actorSendBack p)
             (RcvSimple (wrapMessage chSendParam))
    -- Now we can start execution and send back data
    a   <- receiveChan chRecvParam
    !b  <- runDnaParam p (action a)
    sendResult b



-- | Run actor for group of processes which allow more than 1 task per
--   actor.
runActorManyRanks :: Actor a b -> Process ()
runActorManyRanks (Actor action) = do
    undefined
    -- -- Obtain parameters
    -- p <- expect
    -- -- Create channels for communication
    -- (chSendParam,chRecvParam) <- newChan
    -- (chSendDst,  chRecvDst  ) <- newChan
    -- (chSendRnk,  chRecvRnk  ) <- newChan
    -- -- Send shell process back
    -- me <- getSelfPid
    -- let shell = ( RecvVal chSendParam
    --             , SendVal chSendDst  )
    -- send (actorParent p) (chSendRnk,shell)
    -- -- Start actor execution
    -- a   <- receiveChan chRecvParam
    -- let loop dst = do
    --         send (actorParent p) (me,chSendRnk)
    --         mrnk <- receiveChan chRecvRnk
    --         case mrnk of
    --             Nothing  -> return ()
    --             Just rnk -> do
    --                 !b  <- runDnaParam p{actorRank = rnk} (action a)
    --                 dst' <- drainChannel0 chRecvDst dst
    --                 sendToDest dst' b
    --                 send (actorParent p) (me,DoneTask)
    --                 loop dst'
    -- loop =<< drainChannel chRecvDst


-- | Start execution of collector actor
runCollectActor :: CollectActor a b -> Process ()
runCollectActor (CollectActor step start fini) = do
    -- Obtain parameters
    p <- expect
    -- -- Create channels for communication
    (chSendParam,chRecvParam) <- newChan
    (chSendN,    chRecvN    ) <- newChan
    -- Send shell process description back
    sendChan (actorSendBack p)
         (RcvReduce (wrapMessage chSendParam) chSendN)
    -- Now we want to check if process was requested to crash
    case [pCrash | CrashProbably pCrash <- actorDebugFlags p] of
      pCrash : _ -> do
          roll <- liftIO randomIO
          when (roll < pCrash) $ do
              me <- getSelfPid
              liftIO $ print $ "CRASH! " ++ show me
              error "Ooops crashed"
      _ -> return ()
    -- Start execution of an actor
    --
    -- FIXME: I constrained CollectActor to IO only (no DNA) which
    --        means it cannot do anything specific to DNA.
    --
    --        Check for proper concurrency
    s0 <- liftIO start
    s  <- doGatherM (Group chRecvParam chRecvN) step s0
    !b <- liftIO $ fini s
    sendResult b


-- -- | Start execution of collector actor
-- runCollectActorMR :: CollectActor a b -> Process ()
-- runCollectActorMR (CollectActor step start fini) = do
--     undefined
--     -- -- Obtain parameters
--     -- p <- expect
--     -- -- Create channels for communication
--     -- (chSendParam,chRecvParam) <- newChan
--     -- (chSendDst,  chRecvDst  ) <- newChan
--     -- (chSendN,    chRecvN    ) <- newChan
--     -- -- Send shell process description back
--     -- send (actorParent p)
--     --   ( (RecvMR    [(chSendN,chSendParam)])
--     --   , (SendVal    chSendDst))
--     -- let loop n tot !b
--     --       | n >= tot && tot >= 0 = return b
--     --       | otherwise = do
--     --           r <- liftP $ receiveWait [ matchChan chRecvParam (return . Right)
--     --                                    , matchChan chRecvN     (return . Left)
--     --                                    ]
--     --           case r of
--     --             Right (Just a) -> loop n tot =<< liftIO (step b a)
--     --             Right Nothing  -> loop (n+1) tot b
--     --             Left  k        -> loop n k b
--     -- s <- loop 0 (-1) =<< liftIO start
--     -- b <- liftIO $ fini s
--     -- sendToDestChan chRecvDst b


-- runMapperActor :: Mapper a b -> Process ()
-- runMapperActor (Mapper start step shuffle) = do
--     undefined
--     -- -- Obtain parameters
--     -- p <- expect
--     -- -- Create channels for communication
--     -- (chSendParam,chRecvParam) <- newChan
--     -- (chSendDst,  chRecvDst  ) <- newChan
--     -- -- Send shell process description back
--     -- send (actorParent p)
--     --     ( RecvVal chSendParam
--     --     , SendMR [chSendDst])
--     -- -- Get initial parameters for unfolding
--     -- a   <- receiveChan chRecvParam
--     -- s0  <- liftIO $ start a
--     -- -- Unfold loop
--     -- let loop s dst = do
--     --         dst' <- drainChannel0 chRecvDst dst
--     --         let n = length dst'
--     --         ms <- liftIO $ step s
--     --         case ms of
--     --           Nothing     -> return dst'
--     --           Just (s',b) -> do let i = shuffle n b
--     --                             sendChan (dst' !! i) (Just b)
--     --                             loop s' dst'
--     -- dst <- loop s0 =<< drainChannel chRecvDst
--     -- forM_ dst $ \ch -> sendChan ch Nothing

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

-- -- Send value to the destination
sendToDest :: (Serializable a) => Dest a -> a -> Process ()
sendToDest dst a = case dst of
    SendLocally ch  -> unsafeSendChan ch a
    SendRemote  chs -> forM_ chs $ \ch -> sendChan ch a

-- Send value to the destination
sendResult :: (Serializable a) => a -> Process ()
sendResult a = do
    dst <- drainExpect
    case dst of
      RcvSimple msg   -> trySend msg
      RcvReduce msg _ -> trySend msg
      RcvGrp    msgs  -> mapM_ trySend msgs
  where
    trySend msg = do
        mch <- unwrapMessage msg
        case mch of
          Just ch -> sendChan ch a
          Nothing -> doPanic "Type error in channel!"

doGatherM :: Serializable a => Group a -> (b -> a -> IO b) -> b -> Process b
doGatherM (Group chA chN) f x0 = do
    let loop n tot !b
            | n >= tot && tot >= 0 = return b
        loop n tot !b = do
            r <- receiveWait [ matchChan chA (return . Right)
                             , matchChan chN (return . Left)
                             ]
            case r of
              Right a -> loop (n + 1) tot =<< liftIO (f b a)
              Left  k -> loop n k b
    loop 0 (-1) x0


doGatherDna
    :: Serializable a
    => [MatchS]
    -> Group a
    -> (b -> a -> IO b)
    -> b
    -> DnaMonad b
doGatherDna ms (Group chA chN) f x0 = do
    let loop n tot !b
            | n >= tot && tot >= 0 = return b
        loop n tot !b = do
            r <- handleRecieve ms
                     [ Right `fmap` matchChan' chA
                     , Left  `fmap` matchChan' chN
                     ]
            case r of
              Right a -> loop (n + 1) tot =<< liftIO (f b a)
              Left  k -> loop n k b
    loop 0 (-1) x0

----------------------------------------------------------------
-- CH's TH
----------------------------------------------------------------

remotable [ 'runActor
          , 'runActorManyRanks
          , 'runCollectActor
          -- , 'runCollectActorMR
          -- , 'runMapperActor
          ]
