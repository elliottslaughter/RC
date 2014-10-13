-- |
-- Common moulde for DNA
module DNA (
      -- * DNA monad
      DNA
    , MonadIO(..)
    , liftP
    , getNodes
      -- * Promises
    , Promise
    , await
    , Group
    , gather
      -- * Scattering data
    , Scatter
    , same
    , scatter
      -- * Spawning of actors
    , Actor
    , actor
    , eval
    , forkLocal
    , forkRemote
    , forkGroup
    , forkGroupFailout
      -- * Running program
    , dnaRun  
    ) where

import Control.Monad.IO.Class

import DNA.Logging
import DNA.Run
import DNA.DNA