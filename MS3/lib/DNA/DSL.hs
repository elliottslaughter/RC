{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Description of DNA DSL as operational monad
module DNA.DSL (
      -- * Base DSL
      DNA(..)
    , DnaF(..)
    , Promise(..)
    , Group(..)
      -- ** Spawn monad
    , Spawn(..)
    , SpawnFlag(..)
    , runSpawn
    , useLocal
      -- * Actors
    , Actor(..)
    , actor
    , CollectActor(..)
    , collectActor
    , Mapper(..)
    , mapper
      -- * Smart constructors
    , rank
    , groupSize
    , kernel
      -- ** Actor spawning
    , eval
    , evalClosure
    , availableNodes
    , startActor
    , startCollector
    , startGroup
    , startGroupN
    , startCollectorGroup
    , startCollectorGroupMR
    , startMappers
      -- ** Dataflow building
    , delay
    , await
    , delayGroup
    , gather
    , gatherM
    , sendParam
    -- , broadcastParamSlice
    , broadcast
    , connect
    ) where

import Control.Applicative
import Control.Monad.Operational
import Control.Monad.IO.Class
import Control.Monad.Writer.Strict
import Control.Distributed.Process
import Control.Distributed.Process.Serializable
import Data.Typeable (Typeable)

import DNA.Types


----------------------------------------------------------------
-- Operations data type for DNA
----------------------------------------------------------------

newtype DNA a = DNA (Program DnaF a)
                deriving (Functor,Applicative,Monad)

instance MonadIO DNA where
    liftIO = kernel

-- | GADT which describe operations supported by DNA DSL
data DnaF a where
    -- | Execute foreign kernel
    Kernel
      :: IO a
      -> DnaF a
    DnaRank :: DnaF Int
    DnaGroupSize :: DnaF Int

    AvailNodes :: DnaF Int

    -- | Evaluate actor's closure
    EvalClosure
      :: (Typeable a, Typeable b)
      => a
      -> Closure (Actor a b)
      -> DnaF b
    -- | Spawn single process
    SpawnActor
      :: (Serializable a, Serializable b)
      => Res
      -> Spawn (Closure (Actor a b))
      -> DnaF (Shell (Val a) (Val b))
    SpawnCollector
      :: (Serializable a, Serializable b)
      => Res
      -> Spawn (Closure (CollectActor a b))
      -> DnaF (Shell (Grp a) (Val b))
    SpawnGroup
      :: (Serializable a, Serializable b)
      => Res
      -> ResGroup
      -> Spawn (Closure (Actor a b))
      -> DnaF (Shell (Scatter a) (Grp b))
    SpawnGroupN
      :: (Serializable a, Serializable b)
      => Res
      -> ResGroup
      -> Int
      -> Spawn (Closure (Actor a b))
      -> DnaF (Shell (Val a) (Grp b))
    SpawnCollectorGroup
      :: (Serializable a, Serializable b)
      => Res
      -> ResGroup   
      -> Spawn (Closure (CollectActor a b))
      -> DnaF (Shell (Grp a) (Grp b))
    SpawnCollectorGroupMR
      :: (Serializable a, Serializable b)
      => Res
      -> ResGroup
      -> Spawn (Closure (CollectActor a b))
      -> DnaF (Shell (MR a) (Grp b))
    SpawnMappers
      :: (Serializable a, Serializable b)
      => Res
      -> ResGroup
      -> Spawn (Closure (Mapper a b))
      -> DnaF (Shell (Scatter a) (MR b))

    -- | Connect running actors
    Connect
      :: Serializable b
      => Shell a (tag b)
      -> Shell (tag b) c
      -> DnaF ()
    -- | Send parameter to the actor
    SendParam
      :: Serializable a
      => a
      -> Shell (Val a) b
      -> DnaF ()

    -- | Delay actor returning single value
    Delay 
      :: Serializable b
      => Shell a (Val b)
      -> DnaF (Promise b)
    DelayGroup
      :: Serializable b
      => Shell a (Grp b)
      -> DnaF (Group b)
    Await
      :: Serializable a
      => Promise a
      -> DnaF a
    GatherM
      :: Serializable a
      => Group a
      -> (b -> a -> IO b)
      -> b
      -> DnaF b

-- | Spawn monad. It's used to carry all additional parameters for
--   process spawning
newtype Spawn a = Spawn (Writer [SpawnFlag] a)
                  deriving (Functor,Applicative,Monad)

-- | Flags for spawn
data SpawnFlag
    = UseLocal
    deriving (Show,Eq,Typeable)

runSpawn :: Spawn a -> (a,[SpawnFlag])
runSpawn (Spawn m) = runWriter m

useLocal :: Spawn ()
useLocal = Spawn $ tell [UseLocal]

newtype Promise a = Promise (ReceivePort a)

data Group a = Group (ReceivePort a) (ReceivePort Int)


----------------------------------------------------------------
-- Data types for actors
----------------------------------------------------------------

-- | Actor which receive messages of type @a@ and produce result of
--   type @b@. It's phantom-typed and could only be constructed by
--   'actor' which ensures that types are indeed correct.
data Actor a b where
    Actor :: (Serializable a, Serializable b) => (a -> DNA b) -> Actor a b
    deriving (Typeable)

-- | Smart constructor for actors. Here we receive parameters and
--   output channel for an actor
actor :: (Serializable a, Serializable b)
      => (a -> DNA b)
      -> Actor a b
actor = Actor

-- | Actor which collects multiple inputs from other actors
data CollectActor a b where
    CollectActor :: (Serializable a, Serializable b)
                 => (s -> a -> IO s)
                 -> IO s
                 -> (s -> IO b)
                 -> CollectActor a b
    deriving (Typeable)

-- | Smart constructor for collector actors.
collectActor
    :: (Serializable a, Serializable b, Serializable s)
    => (s -> a -> IO s)
    -> IO s
    -> (s -> IO b)
    -> CollectActor a b
collectActor = CollectActor


-- | Mapper actor. Essentially unfoldr
data Mapper a b where
    Mapper :: (Serializable a, Serializable b, Serializable s)
           => (a -> IO s)
           -> (s -> IO (Maybe (s,b)))
           -> (Int -> b -> Int)
           -> Mapper a b
    deriving (Typeable)

mapper :: (Serializable a, Serializable b, Serializable s)
       => (a -> IO s)
       -> (s -> IO (Maybe (s, b)))
       -> (Int -> b -> Int)
       -> Mapper a b
mapper = Mapper



----------------------------------------------------------------
-- Smart constructors
----------------------------------------------------------------

rank :: DNA Int
rank = DNA $ singleton DnaRank

groupSize :: DNA Int
groupSize = DNA $ singleton DnaGroupSize

kernel :: IO a -> DNA a
kernel = DNA . singleton . Kernel

delay :: Serializable b => Location -> Shell a (Val b) -> DNA (Promise b)
delay _ = DNA . singleton . Delay

await :: Serializable a => Promise a -> DNA a
await = DNA . singleton . Await

delayGroup :: Serializable b => Shell a (Grp b) -> DNA (Group b)
delayGroup = DNA . singleton . DelayGroup

gatherM
    :: Serializable a
    => Group a
    -> (b -> a -> IO b)
    -> b
    -> DNA b
gatherM g f b = DNA $ singleton $ GatherM g f b

gather 
    :: Serializable a
    => Group a
    -> (b -> a -> b)
    -> b
    -> DNA b
gather g f = gatherM g (\b a -> return $ f b a)

sendParam :: Serializable a => a -> Shell (Val a) b -> DNA ()
sendParam a sh = DNA $ singleton $ SendParam a sh

connect :: (Serializable b)
        => Shell a (tag b) -> Shell (tag b) c -> DNA ()
connect a b = DNA $ singleton $ Connect a b

-- | Broadcast same parameter to all actors in group
broadcast :: Shell (Scatter a) b -> Shell (Val a) b
broadcast (Shell a r s) = Shell a (RecvBroadcast r) s

availableNodes :: DNA Int
availableNodes = DNA $ singleton AvailNodes

-- | Evaluate actor without forking off enother thread
eval :: (Serializable a, Serializable b)
     => Actor a b
     -> a
     -> DNA b
eval (Actor act) = act

-- | Evaluate actor without forking off enother thread
evalClosure :: (Typeable a, Typeable b)
            => Closure (Actor a b)
            -> a
            -> DNA b
evalClosure clos a = DNA $ singleton $ EvalClosure a clos
    
startActor
    :: (Serializable a, Serializable b)
    => Res
    -> Spawn (Closure (Actor a b))
    -> DNA (Shell (Val a) (Val b))
startActor r a =
    DNA $ singleton $ SpawnActor r a


-- | Start single collector actor
startCollector :: (Serializable a, Serializable b)
               => Res
               -> Spawn (Closure (CollectActor a b))
               -> DNA (Shell (Grp a) (Val b))
startCollector res child =
    DNA $ singleton $ SpawnCollector res child

    -- (shellS,shellR) <- liftP newChan
    -- let clos = $(mkStaticClosure 'runCollectActor) `closureApply` child
    -- sendACP $ ReqSpawnShell clos shellS res
    -- msg <- unwrapMessage =<< liftP (receiveChan shellR)
    -- case msg of
    --   Nothing -> error "Bad shell message"
    --   Just  s -> return s


-- | Start group of processes
startGroup :: (Serializable a, Serializable b)
           => Res
           -> ResGroup   
           -> Spawn (Closure (Actor a b))
           -> DNA (Shell (Scatter a) (Grp b))
startGroup res resG child =
    DNA $ singleton $ SpawnGroup res resG child
    -- (shellS,shellR) <- liftP newChan
    -- let clos = $(mkStaticClosure 'runActor) `closureApply` child
    -- sendACP $ ReqSpawnGroup clos shellS res groupTy
    -- (gid,mbox) <- liftP (receiveChan shellR)
    -- msgs <- mapM unwrapMessage mbox
    -- case sequence msgs of
    --   Nothing -> error "Bad shell message"
    --   Just  s -> return $ assembleShellGroup gid s

-- | Start group of processes where we have more tasks then processes.
startGroupN
    :: (Serializable a, Serializable b)
    => Res         -- ^ Resources for actors
    -> ResGroup    -- ^
    -> Int
    -> Spawn (Closure (Actor a b))
    -> DNA (Shell (Val a) (Grp b))
startGroupN res resG nTasks child =
    DNA $ singleton $ SpawnGroupN res resG nTasks child

    -- (shellS,shellR) <- liftP newChan
    -- let clos = $(mkStaticClosure 'runActorManyRanks) `closureApply` child
    -- sendACP $ ReqSpawnGroupN clos shellS res nTasks groupTy
    -- (gid,mbox) <- liftP (receiveChan shellR)
    -- msgs <- mapM unwrapMessage mbox
    -- case sequence msgs of
    --   Nothing -> error "Bad shell message"
    --   Just  s -> return $ broadcast $ assembleShellGroup gid s

-- | Start group of collector processes
startCollectorGroup
    :: (Serializable a, Serializable b)
    => Res
    -> ResGroup   
    -> Spawn (Closure (CollectActor a b))
    -> DNA (Shell (Grp a) (Grp b))
startCollectorGroup res resG child =
    DNA $ singleton $ SpawnCollectorGroup res resG child

    -- (shellS,shellR) <- liftP newChan
    -- let clos = $(mkStaticClosure 'runCollectActor) `closureApply` child
    -- sendACP $ ReqSpawnGroup clos shellS res groupTy
    -- (gid,mbox) <- liftP (receiveChan shellR)
    -- msgs <- mapM unwrapMessage mbox
    -- case sequence msgs of
    --   Nothing -> error "Bad shell message"
    --   Just  s -> return $ assembleShellGroupCollect gid s

-- | Start group of collector processes
startCollectorGroupMR
    :: (Serializable a, Serializable b)
    => Res
    -> ResGroup
    -> Spawn (Closure (CollectActor a b))
    -> DNA (Shell (MR a) (Grp b))
startCollectorGroupMR res resG child =
    DNA $ singleton $ SpawnCollectorGroupMR res resG child

    -- (shellS,shellR) <- liftP newChan
    -- let clos = $(mkStaticClosure 'runCollectActorMR) `closureApply` child
    -- sendACP $ ReqSpawnGroup clos shellS res groupTy
    -- (gid,mbox) <- liftP (receiveChan shellR)
    -- msgs <- mapM unwrapMessage mbox
    -- case sequence msgs of
    --   Nothing -> error "Bad shell message"
    --   Just  s -> return $ assembleShellGroupCollectMR gid s

-- | Start group of mapper processes
startMappers
    :: (Serializable a, Serializable b)
    => Res
    -> ResGroup
    -> Spawn (Closure (Mapper a b))
    -> DNA (Shell (Scatter a) (MR b))
startMappers res resG child =
    DNA $ singleton $ SpawnMappers res resG child
    -- (shellS,shellR) <- liftP newChan
    -- let clos = $(mkStaticClosure 'runMapperActor) `closureApply` child
    -- sendACP $ ReqSpawnGroup clos shellS res groupTy
    -- (gid,mbox) <- liftP (receiveChan shellR)
    -- msgs <- mapM unwrapMessage mbox
    -- case sequence msgs of
    --   Nothing -> error "Bad shell message"
    --   Just  s -> return $ assembleShellMapper gid s