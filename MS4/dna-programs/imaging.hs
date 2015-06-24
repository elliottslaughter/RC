{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | High level dataflow for imaging program
module Main where

import Control.Distributed.Process (Closure)

import DNA
import DNA.Channel.File

import Data.Binary   (Binary)
import Data.Typeable (Typeable)
import GHC.Generics  (Generic)

import Data
import Kernel
import Scheduling
import Vector

----------------------------------------------------------------
-- Data types
----------------------------------------------------------------

data OskarData

-- | A data set, consisting of an Oskar file name and the frequency
-- channel & polarisation we are interested in.
newtype DataSet = DataSet
  { dsData :: FileChan OskarData -- ^ Oskar data to read
  , dsChannel :: Int   -- ^ Frequency channel to process
  , dsPolar :: Polar   -- ^ Polarisation to process
  , dsRepeats :: Int   -- ^ Number of times we should process this
                       -- data set to simulate a larger workload
  }
  deriving (Show,Binary,Typeable)

-- | Main run configuration. This contains all parameters we need for
-- runnin the imaging pipeline.
newtype Config = Config
  { cfgDataSets :: [DataSet] -- ^ Data sets to process
  , cfgGridPar :: GridPar    -- ^ Grid parameters to use. Must be compatible with used kernels!
  , cfgGCFPar :: GCFPar      -- ^ GCF parameters to use.

  , cfgGCFKernel :: String   -- ^ The GCF kernel to use
  , cfgGridKernel :: String  -- ^ The gridding kernel to use
  , cfgDFTKernel :: String   -- ^ The fourier transformation kernel to use
  , cfgCleanKernel :: String -- ^ The cleaning kernel to use

  , cfgMinorLoops :: Int     -- ^ Maximum number of minor loop iterations
  , cfgMajorLoops :: Int     -- ^ Maximum number of major loop iterations
  , cfgCleanGain :: Double   -- ^ Cleaning strength (?)
  , cfgCleanThreshold :: Double -- ^ Residual threshold at which we should stop cleanining
  }
  deriving (Show,Binary,Typeable)


scheduleFreqCh
    :: Int                      -- ^ Number of nodes to use
    -> [(FreqCh,Int)]           -- ^ List of pairs (freq. ch., N of iterations)
    -> DNA [(FreqCh,Int)]
scheduleFreqCh nNodes input = do
    -- Get full execution time for each channel
    times <- forM input $ \(freqCh, n) -> do
        t <- getExecutionTimeForFreqCh freqCh
        return (t * n)
    -- 
    let nodes = balancer nNodes times
        split tot bins = zipWith (+) (replicate bins base) (replicate rest 1 ++ repeat 0)
          where (base,rest) = tot `divMod` bins
    return $ zip nodes input >>= (\(bins,(freqCh, n)) -> (,) freqCh <$> split n bins)




----------------------------------------------------------------
-- Actors
----------------------------------------------------------------

-- Magic function which only used here to avoid problems with TH It
-- pretends to create closure out of functions and allows to type
-- check code but not run it.
closure :: a -> Closure a
closure = undefined


----------------------------------------------------------------
-- Imaging dataflow
--
-- It's implicitly assumed that all dataflow for generating single
-- image is confined to single computer.
----------------------------------------------------------------


-- | Compound gridding actor.
gridderActor :: GridPar -> GCFPar -> GridKernel -> DFTKernel
             -> Actor (Vis, GCFSet) Image
gridderActor gpar gcfpar gridk dftk = actor $ \(vis,gcfSet) -> do

    -- Grid visibilities to a fresh uv-grid
    grid <- kernel "grid" [] $ liftIO $ do
      grid <- gridkCreateGrid gridk gpar gcfpar
      gridkGrid gridk vis gcfSet grid

    -- Transform uv-grid into an (possibly dirty) image
    kernel "ifft" $ liftIO $ do
      dftIKernel dftk grid

-- | Compound degridding actor.
degridderActor :: GridKernel -> DFTKernel
             -> Actor (Image, Vis, GCFSet) Vis
degridderActor gridk dftk = actor $ \(model,vis,gcfSet) -> do

    -- Transform image into a uv-grid
    grid <- kernel "fft" $ liftIO $ do
      dftKernel dftk model

    -- Degrid to obtain new visibilitities for the positions in "vis"
    kernel "degrid" [] $ liftIO $ do
      gridkDegrid gridk vis gcfSet grid vis

imagingActor :: Config -> Actor DataSet Image
imagingActor cfg = actor $ \dataSet -> do

    -- Copy data set locally
    oskarChan <- createFileChan Local "oskar"
    (gcfk, gridk, dftk, cleank, vis0, psfVis, gcfSet) <- unboundKernel "setup" [] $ liftIO $ do
      transferFileChan (dsData dataSet) oskarChan "data"

      -- Initialise our kernels
      gcfk <- initKernel gcfKernels (cfgGCFKernel cfg)
      gridk <- initKernel gridKernels (cfgGridKernel cfg)
      dftk <- initKernel dftKernels (cfgDFTKernel cfg)
      cleank <- initKernel cleanKernels (cfgCleanKernel cfg)

      -- Read input data from Oskar
      let readOskarData :: FileChan OskarData -> Int -> Polar -> IO Vis
          readOskarData = undefined
      vis <- readOskarData oskarChan (dsChannel dataSet) (dsPolar dataSet)
      psfVis <- constVis 1 vis

      -- Run GCF kernel to generate GCFs
      gcfSet <- gcfKernel gcfk (cfgGridPar cfg) (cfgGCFPar cfg)
                               (visMinW vis) (visMaxW vis)

      -- Let grid kernel prepare for processing GCF and visibilities
      -- (transfer buffers, do binning etc.)
      vis' <- gridkPrepareVis gridk vis
      psfVis' <- gridkPrepareVis gridk psfVis
      gcfSet' <- gridkPrepareGCF gridk gcfSet

      -- Calculate PSF using the positions from Oskar data
      return (gcfk, gridk, dftk, cleank,
              vis', psfVis', gcfSet')

    -- Calculate PSF
    let gridAct = gridderActor (cfgGridPar cfg) (cfgGCFPar cfg) gridk dftk
        degridAct = degridderActor gridk dftk
    psf <- eval gridAct (psfVis,gcfSet)

    -- Major cleaning loop. We always do the number of configured
    -- iterations.
    let majorLoop i vis = do
         -- Generate the dirty image from the visibilities
         dirtyImage <- eval gridAct (vis,gcfSet)

         -- Clean the image
         (residual, model) <- kernel "clean" [] $ liftIO $
           cleanKernel cleank (cfgMinorLoops cfg) (cfgCleanGain cfg) (cfgCleanThreshold cfg)
                       dirtyImage psf

         -- Done with the loop?
         if i >= cfgMajorLoops cfg then return residual else do

           -- We continue - residual isn't needed any more
           kernel "free" [] $ liftIO $ freeVector (imgData residual)
           -- De-grid the model
           mvis <- eval degridAct (model,vis,gcfSet)
           -- Loop
           vis' <- subtractVis vis mvis
           majorLoop (i+1) vis'

    -- Run above loop. The residual of the last iteration is the
    -- result of this actor
    res <- majorLoop 1 vis0

    -- Cleanup? Eventually kernels will probably want to do something
    -- here...

    return res

----------------------------------------------------------------
-- High level dataflow
----------------------------------------------------------------

-- | Actor which generate N clean images for given frequency channel
workerActor :: Config -> Actor DataSet (FileChan Image)
workerActor cfg = actor $ \dataSet -> do

    -- Initialise image sum
    img0 <- constImage 0
    let loop i img | i >= dsRepeats dataSet  = return img
                   | otherwise = do
           -- Generate image, sum up
           img' <- eval (imagingActor cfg) dataSet
           unboundKernel "addImage" [] $ liftIO $
             addImage img img'

    -- Run the loop
    img <- loop 0 img0

    -- Allocate file channel for output
    outChan <- createFileChan Remote "image"
    writeImage img outChan "data"
    return outChan

-- | Actor which collects images in tree-like fashion
imageCollector :: TreeCollector Image
imageCollector = undefined

mainActor :: Config -> Actor [DataSet] Image
mainActor cfg = actor $ \input -> do
    -- Start worker actors
    workers <- startGroup (Frac 1) (NNodes 1) $ do
        useLocal
        return (closure workerActor)
    -- Obtain estimates using some secret technique
    estimates <- undefined "Not implemented and unsure how to store it"
    distributeWork input (scheduleFreqCh estimates) workers
    -- Spawn tree collector
    --
    -- This is attempt to encapsulate tree-like reduction in single
    -- actor. In hierarchical DDP tree-like reduction was defined by
    -- spawning actors in tree.
    collector <- startCollectorTree undefined undefined $ do
        useLocal
        return (closure imageCollector)
    connect workers collector
    await =<< delay Remote collector

main :: IO ()
main = do
  return ()
