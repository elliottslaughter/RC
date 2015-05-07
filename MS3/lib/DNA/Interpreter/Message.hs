{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE RankNTypes                 #-}
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

import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
-- import qualified Data.Map as Map
import Data.List   (isPrefixOf)
import qualified Data.Set as Set
import qualified Data.Foldable as T
import Text.Printf

import DNA.CH
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
    -- -- , MatchS handleReady
    -- -- , MatchS handleDone
    , MatchS handleTimeout
    ]


-- Process need to terminate immediately
handleTerminate :: Terminate -> Controller ()
handleTerminate (Terminate msg) = do
    -- liftIO $ putStrLn $ "actor terminated because of: " ++ msg
    fatal $ "Terminate arrived: " ++ msg


-- Monitored process terminated normally or abnormally
handleProcessTermination
    :: ProcessMonitorNotification
    -> Controller ()
handleProcessTermination (ProcessMonitorNotification _ pid reason) =
    case reason of
      DiedNormal -> handleProcessDone  pid
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

      -- FIXME: restart
      -- _          -> do
      --     m <- use $ stRestartable . at pid
      --     case m of
      --       Just (mtch,clos,msg) -> handleProcessRestart pid mtch clos msg
      --       Nothing              -> handleProcessCrash (show reason) pid


----------------------------------------------------------------
-- Handle child process termination
----------------------------------------------------------------

-- Monitored process terminated normally. We don't do anything here
-- because we mark actor as terminated after receiving 'SentTo'
-- message. Since there's race between receiving monitor message and
-- 'SentTo' message we have to put all logic into handler for one
-- handler.
handleProcessDone :: ProcessId -> Controller ()
handleProcessDone _pid = return ()


-- Monitored process crashed or was disconnected
handleProcessCrash :: String -> ProcessId -> Controller ()
handleProcessCrash _msg pid = withAID pid $ \aid -> do
    -- We can receive notifications from unknown processes. When we
    -- terminate actor forcefully we remove it from registry at the
    -- same time
    Just st  <- use $ stChildren     . at aid
    mRestart <- use $ stActorClosure . at aid
    msrc     <- use $ stActorSrc     . at aid
    case st of
      Completed _ -> fatal "Completed process crashed"
      Failed      -> fatal "Process failed process "
      -- If actor is still running we need to decide whether to
      -- restart or accept failure. We can restart actor iff one of
      -- the following is true in addition to having closure
      --
      --  * It's not connected yet
      --  * It's local process and we're holding var
      --  * It receives data from live actor
      Running runInfo@(RunInfo nDone nFails)
        | Just restart <- mRestart
        , Nothing      <- msrc
          -> do Just cad <- use $ stUsedResources . at pid
                stUsedResources . at pid .= Nothing
                lift $ spawnSingleActor aid cad restart
                actorDestinationAddr aid >>= T.mapM_ (sendToActor aid)
        ----------------
        | Just restart        <- mRestart
        , Just (Left trySend) <- msrc
          -> do Just cad <- use $ stUsedResources . at pid
                stUsedResources . at pid .= Nothing
                lift $ spawnSingleActor aid cad restart
                Just (Just (dst,_)) <- use $ stActorRecvAddr . at aid
                liftP $ trySend dst
                actorDestinationAddr aid >>= T.mapM_ (sendToActor aid)
        ----------------
        | Just restart        <- mRestart
        , Just (Right aidSrc) <- msrc
          -> do Just stSrc <- use $ stChildren . at aidSrc
                case stSrc of
                  Completed{} -> handleFail aid pid runInfo
                  Failed      -> killActorAndCleanUp aid pid
                  Running (RunInfo _ nFailsSrc) -> do
                      Just cad <- use $ stUsedResources . at pid
                      stUsedResources . at pid .= Nothing
                      lift $ spawnSingleActor aid cad restart
                      Just (Just dst) <- use $ stActorRecvAddr . at aid
                      stChildren . at aidSrc .= Just (Running $ RunInfo 0 nFailsSrc)
                      sendToActor aidSrc dst
                      dest <- use $ stActorDst . at aid
                      case dest of
                        Nothing -> return ()
                        Just (Left _) -> return ()
                        Just (Right aidDst) -> do
                            mdst <- use $ stActorRecvAddr . at aidDst
                            case mdst of
                              Nothing -> return ()
                              Just d  -> sendToActor aid d
        ----------------
        | otherwise -> handleFail aid pid runInfo


handleFail :: AID -> ProcessId -> RunInfo -> Controller ()
handleFail aid pid (RunInfo nDone nFails)
    -- Terminate process forcefully
    | nFails <= 0 = killActorAndCleanUp aid pid
    -- We can still tolerate failures
    | otherwise = do
          freeResouces pid
          dropPID pid aid
            ( do stChildren . at aid .= Just (Completed nDone)
                 mch <- actorDestinationAddr aid
                 case mch of
                   -- It's possible that all actors crashed but
                   -- actor is not connected yet. But it's not
                   -- possible to get normal termination without
                   -- connection
                   Nothing | nDone == 0   -> return ()
                           | otherwise    -> panic "Unconnected actor terminated normally (crash)"
                   Just (RcvReduce chans) -> liftP $ forM_ chans $ \(_,chN) -> sendChan chN nDone
                   Just _                 -> return ()
            )
            ( stChildren . at aid .= Just (Running $ RunInfo nDone nFails)
            )

killActorAndCleanUp :: AID -> ProcessId -> Controller ()
killActorAndCleanUp aid pid = do
    freeResouces pid
    -- Clean up after actor
    terminateActor  aid
    dropActor       aid
    stChildren . at aid .= Just Failed
    -- Notify dependent processes
    mdst <- use $ stActorDst . at aid
    T.forM_ mdst $ \dst -> case dst of
        Left  _      -> fatal "Dependent actor died"
        Right aidDst -> terminateActor aidDst


-- Handle message that actor sent data to some destination
handleDataSent :: SentTo -> Controller ()
handleDataSent (SentTo aid pid dstID) = do
    -- Check that data was sent to correct destination
    me <- liftP getSelfPid
    Just dst <- use $ stActorDst . at aid
    case dst of
      Left  _      -> sendAck
      Right aidDst -> do
          d <- use $ stActorRecvAddr . at aidDst
          case d of
            Nothing      -> doPanic "Data sent to unconnected actor"
            Just Nothing -> doPanic "Data sent to terminated actor"
            Just (Just (trueDst,trueId))
              | dstID == trueId -> sendAck
              | otherwise       -> liftP $ send pid (trueDst,trueId)
  where
    -- Send confirmation to the actor and remove it from registry
    sendAck = do
        liftP $ send pid AckSend
        freeResouces pid
        Just st <- use $ stChildren . at aid
        case st of
          Completed _ -> panic "Actor terminated normally twice?"
          Failed      -> panic "Failed process terminated normally?"
          Running (RunInfo nDone nFails) -> do
              dropPID pid aid
                ( do stChildren . at aid .= Just (Completed (nDone + 1))
                     mch <- actorDestinationAddr aid
                     case mch of
                       Nothing                -> panic "Unconnected actor terminated normally"
                       Just (RcvReduce chans) -> liftP $ forM_ chans $ \(_,chN) -> sendChan chN (nDone + 1)
                       Just _                 -> return ()
                )
                ( stChildren . at aid .= Just (Running $ RunInfo (nDone+1) nFails)
                )


-- Perform action on actor. If no actor is associated with PID then do
-- nothing
withAID :: ProcessId -> (AID -> Controller ()) -> Controller ()
withAID pid action = do
    maid <- use $ stPid2Aid . at pid
    T.forM_ maid action

-- Remove PID from mapping
dropPID
    :: ProcessId
    -> AID
    -> Controller ()            -- ^ Call if last process from actor is done
    -> Controller ()            -- ^ Call if actor is still working
    -> Controller ()
dropPID pid aid actionDone actionGoing = do
    Just pids <- use $ stAid2Pid . at aid
    let  pids' = Set.delete pid pids
    stPid2Aid . at pid .= Nothing
    case Set.null pids' of
      True -> do
          stAid2Pid       . at aid .= Nothing
          stActorRecvAddr . at aid .= Just Nothing
          actionDone
      False -> do
          stAid2Pid  . at aid .= Just pids'
          actionGoing



----------------------------------------------------------------
-- Handle restarts
----------------------------------------------------------------


{-
-- Handle restart of a process
handleProcessRestart
    :: ProcessId                -- Old PID
    -> Match' (SomeRecvEnd,SomeSendEnd,[SendPort Int])
    -> Closure (Process ())     -- Closure to restart
    -> Message                  -- Initial parameters
    -> Controller ()
handleProcessRestart oldPID mtch clos p0 = do
    -- Get older resources
    Just cad <- use $ stUsedResources . at oldPID
    -- Get connections for the processes
    --
    -- FIXME: Here we (wrongly!) assume that connections are already
    --        established. Doing thing right way would be too
    --        difficult at the moment
    --
    -- FIXME: Also we don't take into account actors which receive
    --        data from parent process
    --
    -- Restart process
    (pid,_) <- liftP $ spawnSupervised (nodeId $ vcadNode cad) clos
    liftP $ forward p0 pid
    taggedMessage "INFO" $ printf "%s died, respawned as %s" (show oldPID) (show pid)
    -- Record updated information about actor
    stUsedResources . at oldPID .= Nothing
    stUsedResources . at pid    .= Just cad
    -- Children state
    x <- use $ stChildren . at oldPID
    stChildren . at pid .= x
    -- Connection state
    Just src <- use $ stConnUpstream   . at (SingleActor oldPID)
    Just dst <- use $ stConnDownstream . at (SingleActor oldPID)
    stConnUpstream   . at (SingleActor oldPID) .= Nothing
    stConnDownstream . at (SingleActor oldPID) .= Nothing
    stConnUpstream   . at (SingleActor pid)    .= Just src
    stConnDownstream . at (SingleActor pid)    .= Just dst
    -- Update restart state
    stRestartable . at oldPID .= Nothing
    stRestartable . at pid    .= Just (mtch,clos,p0)
    -- Obtain communication ends
    --
    -- FIXME: Here we can run into situation when we need to respawn
    --        another process while we're waiting for shells so we can
    --        potentially confuse shells
    (r,s,chN) <- lift $ handleRecieve messageHandlers [mtch]
    liftIO $ print $ "Restarting " ++ show oldPID ++ " --> " ++ show pid ++ " | " ++ show chN
    -- Record and connect everything
    case src of
      (aid,ss) -> do
          stConnDownstream . at aid .= Just (Left (SingleActor pid, r))
          liftP $ doConnectActorsExistentially ss r
          -- We also need to update info about channel to send
          case aid of
            ActorGroup gid -> do
                Just g <- use $ stGroups . at gid
                g' <- case g of
                  GrUnconnected{} -> fatal "It should be connected"
                  GrConnected ty (nR,_) _ pids -> return $
                      GrConnected ty (nR,0) chN pids
                  GrFailed -> fatal "We should react to failure by now"
                stGroups . at gid .= Just g'
            SingleActor _   -> return ()
    case dst of
      Left (aid,rr) -> do
          stConnUpstream . at aid .= Just (SingleActor pid, s)
          liftP $ doConnectActorsExistentially s rr
      Right rr ->
          liftP $ doConnectActorsExistentially s rr
-}




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


-- Increment number of completed tasks for group of many-rank
-- processes.
--
-- FIXME: we will increase number of completed tasks when process exit
--        normally so we will have too many completed tasks
handleDone :: (ProcessId,DoneTask) -> Controller ()
handleDone (pid,_) =
    handlePidEvent pid
        (fatal "Shell: unknown process")
        (\_ -> fatal "Shell: must be group")
        (\g _ -> case g of
           GrConnected ty (nR,nD) ch acps ->
               return $ Just $ GrConnected ty (nR,nD+1) ch acps
           _ -> fatal "Invalid shell for group is received"
        )
-}

-- Some process timed out
handleTimeout :: Timeout -> Controller ()
handleTimeout (Timeout aid) = terminateActor aid
