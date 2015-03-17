-- |
-- Common moulde for DNA
module DNA (
      -- * DNA monad
      DNA
    , rank
    , groupSize
    -- , logMessage
    , duration
       -- * Actors
    , Actor
    , actor
    , CollectActor
    , collectActor
    , Mapper
    , mapper
      -- ** Shell actors
    , Shell
    , Val
    , Grp
    , Scatter
    , eval
    , evalClosure
    , startActor
    , startCollector
    , startGroup
    , startGroupN
    , startCollectorGroup
    , startCollectorGroupMR
    , startMappers
      -- * CAD & Co
    -- , CAD
    , Location(..)
    , Res(..)
    , ResGroup(..)
    , useLocal
    -- , GrpFlag(..)
    -- , GroupType(..)
    -- , availableNodes
      -- * Connecting actors
    , sendParam
    -- , broadcastParamSlice
    , broadcast
    , connect
      -- ** Promises
    , Promise
    , Group
    , await
    , gather
    , delay
    , delayGroup
      -- * Start DNA program
    , dnaRun
      -- * Reexports
    , MonadIO(..)
    -- , MonadProcess(..)
    , remotable
    , mkStaticClosure
    ) where

import Control.Monad.IO.Class
import Control.Distributed.Process.Closure (mkStaticClosure,remotable)

import DNA.DSL
import DNA.Logging
import DNA.Types
import DNA.Run


-- -- | Put message into log file
-- logMessage :: String -> DNA ()
-- logMessage = taggedMessage "MSG"



-- import DNA.Run
-- import DNA.DNA
-- import DNA.Controller