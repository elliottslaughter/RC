{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
-- | High level dataflow for imaging program
module Main where

import Control.Monad

import DNA
import DNA.Channel.File

import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe      (fromJust,isNothing)
import Data.Time.Clock

import Config
import Data
import Kernel
import Oskar
import Scheduling
import Vector

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
    grid <- kernel "grid" (gridkGridHints gridk gpar vis gcfSet) $ liftIO $ do
      grid <- gridkCreateGrid gridk gpar gcfpar
      gridkGrid gridk vis gcfSet grid

    -- Transform uv-grid into an (possibly dirty) image
    kernel "ifft" [] $ liftIO $ do
      dftIKernel dftk grid

-- | Compound degridding actor.
degridderActor :: GridKernel -> DFTKernel
             -> Actor (Image, Vis, GCFSet) Vis
degridderActor gridk dftk = actor $ \(model,vis,gcfSet) -> do

    -- Transform image into a uv-grid
    grid <- kernel "fft" [] $ liftIO $ do
      dftKernel dftk model

    -- Degrid to obtain new visibilitities for the positions in "vis"
    kernel "degrid" (gridkDegridHints gridk (imgPar model) vis gcfSet) $ liftIO $
      gridkDegrid gridk grid gcfSet vis

imagingActor :: Config -> Actor DataSet Image
imagingActor cfg = actor $ \dataSet -> do

    -- Initialise our kernels
    (gridk, gcfk, dftk, cleank) <- kernel "kernel init" [] $ liftIO $ do
      gcfk <- initKernel gcfKernels (cfgGCFKernel cfg)
      gridk <- initKernel gridKernels (cfgGridKernel cfg)
      dftk <- initKernel dftKernels (cfgDFTKernel cfg)
      cleank <- initKernel cleanKernels (cfgCleanKernel cfg)
      return (gridk, gcfk, dftk, cleank)

    -- Read input data from Oskar
    (vis0, psfVis0) <-  kernel "read visibilities" [] $ liftIO $ do
      vis0 <- readOskar (fromJust $ dsData dataSet) "data.vis"
                        (dsChannel dataSet) (dsPolar dataSet)
      psfVis0 <- constVis 1 vis0
      return (vis0, psfVis0)

    -- Run GCF kernel to generate GCFs
    gcfSet0 <- kernel "GCF" [] $ liftIO $
      gcfKernel gcfk (cfgGridPar cfg) (cfgGCFPar cfg) vis0

    -- Let kernels prepare for processing GCF and visibilities
    -- (transfer buffers, do binning, plan FFTs etc.)
    let prepHints = gridkPrepareHints gridk (cfgGridPar cfg) vis0 gcfSet0
    (vis1, gcfSet') <- kernel "prepare" prepHints $ liftIO $
      gridkPrepare gridk (cfgGridPar cfg) vis0 gcfSet0
    (psfVis1, gcfSet1) <- kernel "prepare" prepHints $ liftIO $
      gridkPrepare gridk (cfgGridPar cfg) psfVis0 gcfSet'
    kernel "prepare" prepHints $ liftIO $
      dftPrepare dftk (cfgGridPar cfg)

    -- Calculate PSF
    let gridAct = gridderActor (cfgGridPar cfg) (cfgGCFPar cfg) gridk dftk
        degridAct = degridderActor gridk dftk
    psf <- eval gridAct (psfVis1,gcfSet1)

    -- Free PSF vis
    kernel "psf cleanup" [] $ liftIO $ freeVis psfVis1

    -- Major cleaning loop. We always do the number of configured
    -- iterations.
    let majorLoop i vis = do
         -- Generate the dirty image from the visibilities
         dirtyImage <- eval gridAct (vis,gcfSet1)

         -- Clean the image
         (residual, model) <- kernel "clean" [] $ liftIO $
           cleanKernel cleank (cfgCleanPar cfg) dirtyImage psf

         -- Done with the loop?
         if i >= cfgMajorLoops cfg then do
           kernel "clean cleanup vis" [] $ liftIO $ freeVis vis
           return residual

         else do
           -- We continue - residual isn't needed any more
           kernel "free" [] $ liftIO $ freeVector (imgData residual)
           -- De-grid the model
           vis' <- eval degridAct (model,vis,gcfSet1)
           -- Loop
           majorLoop (i+1) vis'

    -- Run above loop. The residual of the last iteration is the
    -- result of this actor
    res <- majorLoop 1 vis1

    kernel "imaging cleanup" [] $ liftIO $ do
      -- Give kernels a chance to free their data
      dftClean dftk
      -- Free GCFs & PSF
      freeGCFSet gcfSet1
      freeImage psf
      -- Transfer result into memory, done
      memImage res

----------------------------------------------------------------
-- High level dataflow
----------------------------------------------------------------

-- | Actor which generate N clean images for given frequency channel
workerActor :: Actor (Config, DataSet) (GridPar, FileChan Image)
workerActor = actor $ \(cfg, dataSet) -> do

    -- Create input file channel & transfer data
    oskarChan <- createFileChan Local "oskar"
    unboundKernel "transfer" [] $ liftIO $
        transferFileChan (fromJust $ dsData dataSet) oskarChan "data.vis"
    let dataSet' = dataSet{ dsData = Just oskarChan }

    -- Initialise image sum
    img0 <- kernel "init image" [] $ liftIO $ constImage (cfgGridPar cfg) 0
    let loop i img | i >= dsRepeats dataSet  = return img
                   | otherwise = do
           -- Generate image, sum up
           img' <- eval (imagingActor cfg) dataSet'
           img'' <- unboundKernel "addImage" [] $ liftIO $ do
             putStrLn $ "addImage " ++ show i
             addImage img img'
           loop (i+1) img''

    -- Run the loop
    img <- loop 0 img0

    -- Delete oskar data
    unboundKernel "clear oskar data" [] $ liftIO $
        deleteFileChan oskarChan

    -- Allocate file channel for output
    outChan <- createFileChan Remote "image"
    kernel "write image" [] $ liftIO $ do
        writeImage img outChan "data.img"
        putStrLn "image written"
        freeImage img
    return (cfgGridPar cfg, outChan)

-- | Actor which collects images in tree-like fashion
imageCollector :: TreeCollector (GridPar, FileChan Image)
imageCollector = treeCollector collect start finish
  where start = return Nothing
        collect mimg (gridp, imgCh) = liftIO $ do
          img' <- readImage gridp imgCh "data.img"
          img'' <- case mimg of
            Nothing -> return img'
            Just (img, chan) -> do
              deleteFileChan chan
              addImage img img'
          return $ Just (img'', imgCh)
        finish (Just (img, ch)) = liftIO $ do
          writeImage img ch "data.img"
          return (imgPar img, ch)
        finish Nothing = fail "No images to reduce!"

-- | A measure for the complexity of processing a data set.
type Weight = Rational

-- | Actor to estimate the cost of doing a single repeat on the given
-- data set using our configuration. This basically means running the
-- whole imaging pipeline once, measuring the performance it takes.
--
-- TODO: Warmup? Determine mean derivation?
estimateActor :: Actor (Config, DataSet) (DataSet, Weight)
estimateActor = actor $ \(cfg, dataSet) -> do

    -- Create input file channel & transfer data
    oskarChan <- createFileChan Local "oskar"
    unboundKernel "transfer" [] $ liftIO $
        transferFileChan (fromJust $ dsData dataSet) oskarChan "data.vis"

    -- Generate image, measuring time
    let dataSet' = dataSet{ dsData = Just oskarChan }
    start <- unboundKernel "estimate start" [] $ liftIO getCurrentTime
    void $ eval (imagingActor cfg) dataSet'
    end <- unboundKernel "estimate end" [] $ liftIO getCurrentTime

    -- Delete oskar data
    unboundKernel "clear oskar data" [] $ liftIO $
        deleteFileChan oskarChan

    -- Return time taken
    return (dataSet, toRational $ end `diffUTCTime` start)

remotable
  [ 'workerActor
  , 'imageCollector
  , 'estimateActor
  ]

-- | The main program actor. Schedules the given data sets
-- appropriately to the available nodes.
mainActor :: Actor (Config, [DataSet]) (FileChan Image)
mainActor = actor $ \(cfg, dataSets) -> do

    -- Check that we actually have enough nodes. The local node counts.
    let setCount = length dataSets
    avail <- availableNodes
    when (setCount > avail + 1) $
        fail $ "Not enough nodes: Require " ++ show setCount ++ " to run data sets!"

    -- Allocate estimation nodes
    --
    -- DSL: This construct tells to spawn actor for every item in a
    --      list. Essentially it's distributed map.
    estimateWorkers <- startGroup (N (setCount-1)) (NNodes 1) $ do
        useLocal
        return $(mkStaticClosure 'estimateActor)
    distributeWork dataSets (const (map ((,) cfg))) estimateWorkers

    -- Run estimation, collect weighted data sets
    grp <- delayGroup estimateWorkers
    weightedDataSets <- gather grp (flip (:)) []
    logMessage "Weight Table:"
    forM_ weightedDataSets $ \(ds, w) ->
      logMessage $ show (fromRational w :: Float) ++ " - " ++ show (dsName ds)

    -- Schedule work
    let schedule = balancer (avail+1) (map (fromRational . snd) weightedDataSets)
        splitData low high dataSet =
            let atRatio r = floor $ r * fromIntegral (dsRepeats dataSet)
            in dataSet { dsRepeats = atRatio high - atRatio low }
        dist = distributer splitData schedule (map fst weightedDataSets)
    logMessage ("Schedule: " ++ show schedule)
    forM_ (zip [1..] dist) $ \(i,ds) ->
       logMessage (show (i :: Int) ++ ": " ++ show (dsRepeats ds) ++ " x " ++ show (dsName ds))

    -- Now start worker actors
    waitForResources estimateWorkers
    workers <- startGroup (N avail) (NNodes 1) $ do
        useLocal
        return $(mkStaticClosure 'workerActor)
    distributeWork
        (map fst weightedDataSets)
        (\_ _ -> map ((,) cfg) dist)
        workers

    -- Spawn tree collector
    leaves <- startCollectorTreeGroup (N 0) $ do
        useLocal
        return $(mkStaticClosure 'imageCollector)
    -- Top level collector
    topLevel <- startCollectorTree $ do
        useLocal
        return $(mkStaticClosure 'imageCollector)
    connect workers leaves
    connect leaves  topLevel
    fmap snd . await =<< delay Local topLevel

main :: IO ()
main = dnaRun rtable $ do

    -- We expect configuration in our working directory
    (dataSets, config) <- unboundKernel "configure" [] $ liftIO $ do
        !dataSets <- fmap decode' $ LBS.readFile "data.cfg" :: IO (Maybe [DataSet])
        !config   <- fmap decode' $ LBS.readFile "imaging.cfg" :: IO (Maybe Config)
        return (dataSets, config)

    -- Make sure parsing of configuration files worked
    when (isNothing config) $
        fail "Failed to parse configuration file 'imaging.cfg'. Make sure it exists and matches program version!"
    when (isNothing dataSets) $
        fail "Failed to parse dataset file 'data.cfg'. Make sure it exists and matches program version!"

    -- Create Oskar file channels
    dataSets' <- forM (fromJust dataSets) $ \ds -> do
        chan <- createFileChan Remote "oskar"
        (polars, freqs) <- unboundKernel "import oskar" [] $ liftIO $ do
            importToFileChan chan "data.vis" (dsFile ds)
            readOskarHeader chan "data.vis"
        when (dsPolar ds `notElem` polars || dsChannel ds `notElem` freqs) $ do
            fail $ "Data set " ++ dsName ds ++ " does not exist in the visibilities file!"
        return ds { dsData = Just chan }

    -- Execute main actor
    chan <- eval mainActor (fromJust config, dataSets')

    unboundKernel "export image" [] $ liftIO $ do
        -- Copy result image to working directory
        exportFromFileChan chan "data.img" "output.img"
        -- Clean file channels
        forM_ dataSets' $ deleteFileChan . fromJust . dsData
        deleteFileChan chan
  where
    rtable = __remoteTable
