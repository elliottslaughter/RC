{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TypeOperators,
             FlexibleContexts #-}

module Main where

import Control.Monad

import Flow

import Kernel.Binning
import Kernel.Data
import Kernel.Facet
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

createImage :: Flow Image
createImage = flow "create image"
facetSum :: Flow Image -> Flow Image -> Flow Image
facetSum = flow "facet sum"

-- | Compound gridder actor
gridder :: Flow Vis -> Flow GCFs -> Flow Image
gridder vis gcfs = idft (grid vis gcfs createGrid)

-- | Facetted compound gridder actor
facetGridder :: Flow Vis -> Flow GCFs -> Flow Image
facetGridder vis gcfs = facetSum (gridder vis gcfs) createImage

-- ----------------------------------------------------------------------------
-- ---                               Strategy                               ---
-- ----------------------------------------------------------------------------

gridderStrat :: Config -> Strategy ()
gridderStrat cfg = do
  let gpar = cfgGrid cfg
      gcfpar = cfgGCF cfg

  -- Make point domain for visibilities
  dom <- makeRangeDomain 0 (cfgPoints cfg)

  -- Create ranged domains for image coordinates
  ldoms <- makeRangeDomain 0 (gridImageWidth gpar)
  mdoms <- makeRangeDomain 0 (gridImageHeight gpar)
  ldom <- split ldoms (gridFacets gpar)
  mdom <- split mdoms (gridFacets gpar)

  -- Create ranged domains for grid coordinates
  let tiles = 2 -- per dimension
  udoms <- makeRangeDomain 0 (gridWidth gpar)
  vdoms <- makeRangeDomain 0 (gridHeight gpar)
  vdom <- split vdoms tiles
  udom <- split udoms tiles

  -- Create data flow for tag, bind it to FFT plans
  tag <- bindNew $ fftCreatePlans gpar

  -- Create data flow for visibilities, read in
  let vis = flow "vis" tag
  bind vis $ oskarReader dom (cfgInput cfg) 0 0

  -- Data flows we want to calculate
  let gcfs = gcf vis
      gridded = grid vis gcfs createGrid
      facets = gridder vis gcfs
      result = facetGridder vis gcfs
  distribute ldom ParSchedule $ distribute mdom ParSchedule $ do
    let rkern :: IsKernelDef kf => kf -> kf
        rkern = regionKernel ldom . regionKernel mdom

    -- Rotate visibilities (TODO: These coordinates are known to be wrong!)
    let inLong = 72.1 / 180 * pi
        inLat = 42.6 / 180 * pi
        outLong = 72.1 / 180 * pi
        outLat = 42.6 / 180 * pi
    rebind vis (rotateKernel gpar inLong inLat outLong outLat False ldom mdom dom)

    -- Create w-binned domain, split
    let low_w = -25000
        high_w = 25000
        bins = 2
    wdoms <- makeBinDomain (rkern $ binSizer gpar dom udom vdom low_w high_w bins vis) low_w high_w
    wdom <- split wdoms bins

    -- Load GCFs
    distribute wdom ParSchedule $
      bind gcfs (rkern $ gcfKernel gcfpar wdom)

    -- Bin visibilities (could distribute, but there's no benefit)
    rebind vis (rkern $ binner gpar dom udom vdom wdom)

    -- Bind kernel rules
    bindRule createGrid (rkern $ gridInit gcfpar udom vdom)
    bindRule grid (rkern $ gridKernel gpar gcfpar udoms vdoms wdom udom vdom)

    -- Run gridding distributed
    distribute vdom ParSchedule $ distribute udom ParSchedule $ do
      calculate gridded

    -- Compute the result by detiling & iFFT on result tiles
    bind createGrid (rkern $ gridInitDetile udoms vdoms)
    bind gridded (rkern $ gridDetiling gcfpar (udom, vdom) (udoms, vdoms) gridded createGrid)
    bindRule idft (rkern $ ifftKern gpar udoms vdoms tag)
    calculate facets

  -- Write out
  bindRule createImage $ imageInitDetile gpar
  bind result (imageDefacet gpar (ldom, mdom) facets createImage)
  void $ bindNew $ imageWriter gpar (cfgOutput cfg) result

main :: IO ()
main = do

  let gpar = GridPar { gridWidth = 2048
                     , gridHeight = 2048
                     , gridPitch = 2048
                     , gridTheta = 0.10
                     , gridFacets = 3
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