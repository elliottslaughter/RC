{-# LANGUAGE GADTs #-}

module Kernel.IO where

import Control.Monad
import Foreign.C.Types ( CDouble(..) )
import Foreign.Storable
import qualified Data.Map as Map
import Data.Complex
import Data.Int        ( Int32 )

import OskarReader

import Flow.Builder
import Flow.Domain
import Flow.Vector
import Flow.Kernel
import Flow.Halide

import Kernel.Data

oskarReader :: Domain Bins -> Domain Range -> [OskarInput] -> Int -> Int
            -> Flow Index -> Kernel Vis
oskarReader ddom tdom files freq pol
  = mappingKernel "oskar reader" (indexRepr ddom :. Z)
                                 (RegionRepr ddom $ rawVisRepr tdom) $ \[ixs] [dreg,treg] -> do

  -- Get data set number. We only support reading one data set at a
  -- time currently - no pressing reason, but it makes the code
  -- simpler.
  file <- case Map.lookup [dreg] ixs of
    Just v  -> do ix <- peekVector (castVector v) 0 :: IO Int32
                  return (files !! fromIntegral ix)
    Nothing -> fail "oskarReader: Could not access index parameter!"

  -- Get visibility range
  let (domLow, domHigh) = regionRange treg

  taskData <- readOskarData $ oskarFile file
  when (freq > tdChannels taskData) $
    fail "Attempted to read non-existent frequency channel from Oskar data!"

  -- Get data
  let baselinePoints = tdTimes taskData
      totalPoints = baselinePoints * tdBaselines taskData

  -- Allocate buffer for visibilities depending on region. Make sure
  -- that region is in range and aligned.
  when (domLow < 0 || domHigh > totalPoints) $
    fail $ "oskarReader: region out of bounds: " ++ show domLow ++ "-" ++ show domHigh ++
           " (only have " ++ show totalPoints ++ " points)"
  when ((domLow `mod` baselinePoints) /= 0) $
    fail $ "oskarReader: region not baseline-aligned: " ++ show domLow ++ "-" ++ show domHigh

  -- Go through baselines and collect our data into on big array
  let dblsPerPoint = 5
  visVector <- allocCVector $ dblsPerPoint * (domHigh - domLow)
  let bl0 = domLow `div` baselinePoints
      bl1 = (domHigh - 1) `div` baselinePoints
      CVector _ visp = visVector
  forM_ [bl0..bl1] $ \bl -> do
     forM_ [0..baselinePoints-1] $ \p -> do
       let off = (bl - bl0) * baselinePoints * dblsPerPoint + p * dblsPerPoint
           getUVW uvw = do CDouble d <- peek (tdUVWPtr taskData bl p uvw); return d
       pokeElemOff visp (off + 0) =<< getUVW 0
       pokeElemOff visp (off + 1) =<< getUVW 1
       pokeElemOff visp (off + 2) =<< getUVW 2
       v <- peek (tdVisibilityPtr taskData bl p freq pol)
       pokeElemOff visp (off + 3) (realPart v)
       pokeElemOff visp (off + 4) (imagPart v)

  -- Free all data, done
  finalizeTaskData taskData
  return $ castVector visVector

gcfKernel :: GCFPar -> Domain Bins -> Kernel GCFs
gcfKernel gcfp wdom =
 mergingKernel "gcfs" Z (gcfsRepr wdom gcfp) $ \_ doms -> do

  -- Simply read it from the file
  let size = nOfElements (halrDim (gcfsRepr wdom gcfp) doms)
  v <- readCVector (gcfFile gcfp) size :: IO (Vector Double)
  return (castVector v)

imageWriter :: GridPar -> FilePath -> Flow Image -> Kernel ()
imageWriter gp = halideDump (imageRepr gp)

uvgWriter :: UVDom -> FilePath -> Flow UVGrid -> Kernel ()
uvgWriter uvdom = halideDump (uvgRepr uvdom)
