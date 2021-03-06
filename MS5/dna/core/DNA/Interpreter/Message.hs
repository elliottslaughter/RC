{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE RankNTypes                #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Handling of message for CH interpreter
--
-- Following messages must be handled by actors:
--
--  * Terminate - terminate immediately
--
--  * Timeout - child actor timed out
--
--  * ProcessMonitorNotification - notifications about child process
--    termination
--
--  * SentTo - child actor sent data to its destination and need
--    acknowledgement that it's correct
--
--
module DNA.Interpreter.Message (
      -- * Message handlers
      messageHandlers
    , terminateActor
      -- * Helpers
    , MatchS(..)
    , handleRecieve
    ) where

-- import Control.Applicative
import Control.Monad
import Control.Monad.Reader
-- import Control.Monad.State.Strict
import Control.Distributed.Process
-- import Control.Distributed.Process.Serializable
-- import qualified Data.Map as Map
import Data.List   (isPrefixOf)
import qualified Data.Foldable as T
import Text.Printf

import DNA.Lens
import DNA.Types
import DNA.Interpreter.Types
import DNA.Interpreter.Spawn
import DNA.Logging


----------------------------------------------------------------
-- Handlers for incoming messages
----------------------------------------------------------------

-- List of handlers for auxiliary messages
messageHandlers :: [MatchS]
messageHandlers =
    [ MatchS handleProcessTermination
    , MatchS handleTerminate
    , MatchS handleDataSent
    , MatchS handleTimeout
      --
    -- , MatchS handleReady
    ]


-- Process need to terminate immediately
handleTerminate :: Terminate -> Controller ()
handleTerminate (Terminate msg) =
    fatal $ "Terminate arrived: " ++ msg


-- Monitored process terminated normally or abnormally
handleProcessTermination
    :: ProcessMonitorNotification
    -> Controller ()
handleProcessTermination (ProcessMonitorNotification _ pid reason) =
    case reason of
      -- Monitored process terminated normally. We don't do anything
      -- here because we mark actor as terminated after receiving
      -- 'SentTo' message. Since there's race between receiving
      -- monitor message and 'SentTo' message we have to put all logic
      -- into handler for one message.
      DiedNormal -> return ()
      -- We need to propagate exception from other actors. If some
      -- actor paniced we have no other choice but to spread panic
      --
      -- FIXME: CH doesn't propagate type information about exceptions
      --        thrown so we have to rely on Show instance (fragile)
      DiedException e
        | "Panic " `isPrefixOf` e
        -> doPanic e
      -- Otherwise treat it as normal crash
      _ -> handleProcessCrash (show reason) pid



----------------------------------------------------------------
-- Handle child process termination
----------------------------------------------------------------

-- Monitored process crashed or was disconnected
handleProcessCrash :: String -> ProcessId -> Controller ()
handleProcessCrash msg pid = do
    errorMsg $ printf "Child %s crashed: %s" (show pid) msg
    -- We can receive notifications from unknown processes. When we
    -- terminate actor forcefully we remove it from registry at the
    -- same time
    maid <- use $ stPid2Aid . at pid
    stPid2Aid . at pid .= Nothing
    case maid of
      Nothing  -> return ()
      Just aid -> do
        Just st <- use $ stActorState . at aid
        topAid  <- topLevelActor aid
        msrc    <- use $ stActorSrc . at topAid
        case st of
          Completed    -> panic "Completed process crashed"
          Failed       -> panic "Failed process crashed twice"
          GrpRunning{} -> panic "Group actor could not be linked to single process"
          -- If actor is/was still running we need to decide whether to
          -- restart or accept failure. We can restart actor iff one of
          -- the following is true in addition to having closure
          --
          -- FIXME: what to do with failed node? 
          Running pinfo
            --  * It's not connected yet
            | Just restart <- pinfo^.pinfoClosure
            , Nothing      <- msrc
            -> do lift $ spawnSingleActor aid (pinfo^.pinfoNodes) restart
                  sendDestinationAddr aid
                  errorMsg $ "Restarted unconnected actor " ++ show aid
            --  * It's local process and we can resend data
            | Just restart             <- pinfo^.pinfoClosure
            , Just (SrcParent trySend) <- msrc
            -> do lift  $ spawnSingleActor aid (pinfo^.pinfoNodes) restart
                  liftP $ trySend (pinfo^.pinfoRecvAddr)
                  sendDestinationAddr aid
                  errorMsg $ "Restarted locally connected actor " ++ show aid
            --  * It receives data from live actor
            | Just restart           <- pinfo^.pinfoClosure
            , Just (SrcActor aidSrc) <- msrc
            -> do Just stSrc <- use $ stActorState . at aidSrc
                  case stSrc of
                    -- Upstream is done, cannot respawn since we won't get input data
                    Completed -> handleFail aid
                    Failed    -> handleFail aid
                    -- Upstream is still running simply respawn
                    Running{} -> do lift $ spawnSingleActor aid (pinfo^.pinfoNodes) restart
                                    sendDestinationAddr aid
                                    sendDestinationAddr aidSrc
                    -- Upstream is running but could be completed partially
                    GrpRunning nFail -> do
                        -- Respawn
                        lift $ spawnSingleActor aid (pinfo^.pinfoNodes) restart
                        sendDestinationAddr aid
                        sendDestinationAddr aidSrc
                        -- All completed processes now must marked as
                        -- failed since their output is lost.
                        children <- getCompundActorSubordinates aidSrc
                        forM_ children $ \case
                            (a,Completed) -> stActorState . at a .= Just Failed
                            _             -> return ()
                        let nDone = sum [ 1 | (_,Completed) <- children ]
                        -- If we marked any of completed processes as
                        -- failed we have to handle failure
                        --
                        -- (+1 is needed since handleFail will subtract one)
                        when (nDone > 0) $ do
                            stActorState . at aidSrc .= Just (GrpRunning (nFail - nDone + 1))
                            handleFail aidSrc
            --  * Otherwise we don't try to restart actor
            | otherwise -> handleFail aid


-- Process has failed and wasn't respawned
handleFail :: AID -> Controller ()
handleFail aid = do
    Just descr <- use $ stActors . at aid
    case descr of
      -- Simple actor directly mapping to CH processes
      SimpleActor        -> do
          freeActor aid
          stActorState . at aid .= Just Failed
          terminateDependencies aid
      GroupMember parent -> do
          freeActor aid
          stActorState . at aid .= Just Failed
          handleFail parent
      -- Tree actors fail unconditionally
      ActorTree{} -> do
          flip traverseActor aid $ \a -> do
              terminateActor a
              freeActor a
              stActorState . at a .= Just Failed
          terminateDependencies aid
      -- Group of actors
      ActorGroup{} -> do
          Just (GrpRunning nFail) <- use $ stActorState . at aid
          case () of
            _| nFail > 0 -> do
                 stActorState . at aid .= Just (GrpRunning (nFail - 1))
                 checkIfGroupDone aid
             | otherwise -> do
                 flip traverseActor aid $ \a -> do
                     terminateActor a
                     freeActor a
                     stActorState . at a .= Just Failed
                 terminateDependencies aid


-- Terminate all actors which cannot continue anymore
terminateDependencies :: AID -> Controller ()
terminateDependencies aid = do
    use (stActorSrc . at aid) >>= \case 
      Just SrcParent{}  -> fatal "Child actor died. Cannot continue"
      Just (SrcActor a) -> terminateActor a
      _                 -> return ()
    use (stActorDst . at aid) >>= \case
      Just DstParent{}  -> fatal "Child actor died. Cannot continue"
      Just (DstActor a) -> terminateActor a
      _                 -> return ()

-- Send destination address to an actor if it's connected already
sendDestinationAddr :: AID -> Controller ()
sendDestinationAddr aid =
    use (stActorDst . at aid) >>= \case
      Just (DstParent v) -> do Just addr <- use $ stVars . at v
                               sendToActor aid addr
      Just (DstActor  a) -> sendToActor aid =<< getRecvAddress a
      Nothing            -> panic "No destination address!"

-- Check if group actor completed is execution
checkIfGroupDone :: AID -> Controller ()
checkIfGroupDone aid = do
    -- Get states for all actors
    states <- getCompundActorSubordinates aid
    -- Calculate whether we are done or not
    let nDone  = sum [ 1 | (_, Completed) <- states ]
        isDone = and [ case s of
                         (_,Completed) -> True
                         (_,Failed   ) -> True
                         _             -> False
                     | s <- states ]
    -- Send notification is
    when isDone $ do
        stActorState . at aid .= Just Completed
        use (stActorDst . at aid) >>= \case
          Nothing -> return ()
          Just (DstParent v) -> do Just addr <- use $ stVars . at v
                                   sendNItems nDone addr
          Just (DstActor  a) -> sendNItems nDone =<< getRecvAddress a
  where
    sendNItems n addr = case addr of
      RcvTree   ps  -> forM_ ps $ \case
        RcvReduce _ ch -> liftP $ sendChan ch n
        _              -> panic "checkIfGroupDone: bad address"
      RcvReduce _ p -> liftP $ sendChan p n
      _             -> panic "Cannot send group of values to simple address"

-- Get list of worker actors in compound actor
getCompundActorSubordinates :: AID -> Controller [(AID,ActorState)]
getCompundActorSubordinates aid = do
    children <- use (stActors . at aid) >>= \case
        Just (ActorGroup as) -> return as
        Just (ActorTree  as) -> return as
        _                    -> panic "Bad actor type!"
    forM children $ \a -> do
        Just s <- use $ stActorState . at a
        return (a,s)

-- Process sent its result to some destination. Check if it's
-- correct. Due to respawning of actors it's possible that data was
-- sent to now defunct actor
handleDataSent :: SentTo -> Controller ()
handleDataSent (SentTo pid dst) = do
    maid <- use $ stPid2Aid . at pid
    T.forM_ maid $ \aid -> do
        Just d <- use $ stActorDst . at aid
        case d of
          DstParent {}     -> sendAck aid
          DstActor  aidDst -> do
              trueDst <- getRecvAddress aidDst
              ok      <- checkDestination dst trueDst
              if ok then sendAck aid
                    else sendToActor aid trueDst
  where
    -- Send confirmation to the actor and remove it from registry
    sendAck aid = do
        liftP $ send pid AckSend
        freeActor aid
        stActorState . at aid .= Just Completed
        top <- topLevelActor aid
        when (aid /= top) $ checkIfGroupDone top

-- Check if data was sent to correct destination
checkDestination :: RecvAddr Recv -> RecvAddr Recv -> Controller Bool
checkDestination = check
  where
    check _ RcvFailed    = return True
    check _ RcvCompleted = return True
    -- Grp
    check (RcvGrp []) (RcvGrp []) = return True
    check (RcvGrp (x:xs)) (RcvGrp (y:ys)) = do
      a <- check x y
      b <- check (RcvGrp xs) (RcvGrp ys)
      return (a && b)
    check RcvGrp{} RcvGrp{} = return False
    -- Tree
    check (RcvTree []) (RcvTree []) = return True
    check (RcvTree (x:xs)) (RcvTree (y:ys)) = do
      a <- check x y
      b <- check (RcvTree xs) (RcvTree ys)
      return (a && b)
    check RcvTree{} RcvTree{} = return False
    -- Rest
    check a b = return $ a == b


{-
-- Many-rank actor is ready to process next message.
handleReady :: (ProcessId,SendPort (Maybe Rank)) -> Controller ()
handleReady (pid,chRnk) = do
    -- FIXME: do better than pattern match failure
    Just (Right gid) <- use $ stChildren  . at pid
    Just (n,nMax)    <- use $ stCountRank . at gid
    -- Send new rank to actor
    case () of
      _| n >= nMax -> do
          Just chans <- use $ stPooledProcs . at gid
          liftP $ forM_ chans $ \c -> sendChan c Nothing
       | otherwise -> do
          liftP $ sendChan chRnk (Just $ Rank n)
          stCountRank . at gid .= Just (n+1,nMax)
-}

-- Some process timed out
handleTimeout :: Timeout -> Controller ()
handleTimeout (Timeout aid) = terminateActor aid
