{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TypeOperators, 
             FlexibleContexts #-}

module Main where

import Control.Monad

import Flow

import Kernel.Data
import Kernel.FFT
import Kernel.Gridder
import Kernel.IO

-- ----------------------------------------------------------------------------
-- ---                             Functional                               ---
-- ----------------------------------------------------------------------------

-- Abstract kernel signatures.
createGrid :: Flow UVGrid
createGrid = flow "create grid"
grid :: Flow Vis -> Flow GCFs -> Flow UVGrid -> Flow UVGrid
grid = flow "grid"
idft :: Flow UVGrid -> Flow Image
idft = flow "idft"
gcf :: Flow Vis -> Flow GCFs
gcf = flow "gcf"

-- | Compound gridder actor
gridder :: Flow Vis -> Flow GCFs -> Flow Image
gridder vis gcfs = idft (grid vis gcfs createGrid)

-- ----------------------------------------------------------------------------
-- ---                               Strategy                               ---
-- ----------------------------------------------------------------------------

gridderStrat :: Config -> Strategy ()
gridderStrat cfg = do

  -- Make point domain for visibilities
  dom <- makeRangeDomain 0 (cfgPoints cfg)

  -- Create data flow for tag, bind it to FFT plans
  let gpar = cfgGrid cfg
      gcfpar = cfgGCF cfg
  tag <- bindNew $ fftCreatePlans gpar

  -- Create data flow for visibilities, read in
  let vis = flow "vis" tag
  bind vis $ oskarReader dom (cfgInput cfg) 0 0

  -- Create binned domain, bin
  let low_w = -25000
      high_w = 25000
      bins = 10
      result = gridder vis (gcf vis)
  binsDom <- makeBinDomain (wBinSizer dom low_w high_w bins vis) low_w high_w
  split binsDom bins $ \binDom -> do
    rebind vis $ wBinner dom binDom
    bindRule gcf (gcfKernel gcfpar binDom tag)
    calculate $ gcf vis

    -- Bind kernel rules
    bindRule createGrid (gridInit gpar)
    bindRule grid (gridKernel gpar gcfpar binDom)
    bindRule idft (ifftKern gpar tag)

    -- Compute the result
    calculate result

  -- Write out
  void $ bindNew $ imageWriter gpar (cfgOutput cfg) result

main :: IO ()
main = do

  let gpar = GridPar { gridWidth = 8192
                     , gridHeight = 8192
                     , gridPitch = 8196
                     , gridTheta = 0.10
                     }
      gcfpar = GCFPar { gcfSize = 16
                      , gcfOver = 8
                      , gcfFile = "gcf0.dat"
                      }
      config = Config
        { cfgInput  = "test_p00_s00_f00.vis"
        , cfgPoints = 32131 * 200
        , cfgOutput = "out.img"
        , cfgGrid   = gpar
        , cfgGCF    = gcfpar
        }

  dumpSteps $ gridderStrat config
  execStrategy $ gridderStrat config
