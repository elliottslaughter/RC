{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable, DeriveFunctor #-}
module DNA.Types where

import Control.Distributed.Process
import Data.Binary   (Binary)
import Data.Typeable (Typeable)




-- | Cluster architecture description. Currently it's simply list of
--   nodes process can use.
newtype CAD = CAD [NodeId]
              deriving (Show,Eq,Typeable,Binary)

-- | Parameters for a subprocess. If process require more than one
--   parameter it's sent as tuple if it doesn't require parameters ()
--   is sent.
newtype Param a = Param a
                  deriving (Show,Eq,Typeable,Binary)