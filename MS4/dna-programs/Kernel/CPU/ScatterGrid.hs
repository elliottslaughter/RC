module Kernel.CPU.ScatterGrid
  ( prepare
  , createGrid
  , phaseRotate
  , grid
  , degrid
  , trivHints
  ) where

import Data.Word
import Data.Complex
import Foreign.C
import Foreign.Ptr
import Foreign.Marshal.Array
import Text.Printf

import Data
import Vector

import DNA ( ProfileHint, floatHint )

type PUVW = Ptr UVW
type PCD = Ptr (Complex Double)

type CPUGridderType =
     -- Use Double instead of CDouble to reduce clutter
     Double   -- scale
  -> Double   -- wstep
  -> CInt      -- # of baselines
  -> Ptr CInt  -- baselines supports vector
  -> PCD       -- grid
  -> Ptr PCD   -- GCF layers pointer
  -> Ptr PUVW  -- baselines' uvw data
  -> Ptr PCD   -- baselines' vis data
  -> CInt      -- length of baselines vectors
  -> CInt      -- grid pitch
  -> CInt      -- grid size
  -> Ptr CInt  -- GCF supports vector
  -> IO Word64

{-
foreign import ccall "& gridKernelCPUHalfGCF" gridKernelCPUHalfGCF_ptr :: FunPtr CPUGridderType
foreign import ccall "& gridKernelCPUFullGCF" gridKernelCPUFullGCF_ptr :: FunPtr CPUGridderType

foreign import ccall "dynamic" mkCPUGridderFun :: FunPtr CPUGridderType -> CPUGridderType
-}

foreign import ccall gridKernelCPUFullGCF :: CPUGridderType
foreign import ccall deGridKernelCPUFullGCF :: CPUGridderType

foreign import ccall "normalizeCPU" normalize :: PCD -> CInt -> CInt -> IO ()

-- trivial
-- we make all additional things (pregridding and rotation) inside the gridder
prepare :: GridPar -> Vis -> GCFSet -> IO (Vis, GCFSet)
prepare gp v gs
  | gridHeight gp /= gridWidth gp = error "Assume CPU grid is square!"
  | otherwise = return (v, gs)

-- Need no zero data
createGrid :: GridPar -> GCFPar -> IO UVGrid
createGrid gp _ = fmap (UVGrid gp 0) $ allocCVector (gridFullSize gp)

gridWrapper :: CPUGridderType -> Vis -> GCFSet -> UVGrid -> IO ()
-- This massive nested pattern matches are not quite flexible, but I think a burden
--   to adapt them if data types change is small, thus we stick to this more concise code ATM.
gridWrapper gfun (Vis vmin vmax tsteps bls (CVector _ uwpptr) (CVector _ ampptr) _ _) (GCFSet gcfp _ (CVector tsiz table)) (UVGrid gp _ (CVector _ gptr)) =
    withArray supps $ \suppp -> 
      withArray uvws $ \uvwp -> 
        withArray amps $ \ampp -> do
          withArray gcfSupps $ \gcfsp -> do
            nops <- gfun scale wstep (fi $ length bls) suppp gptr (advancePtr table $ tsiz `div` 2) uvwp ampp (fi tsteps) (fi grWidth) (fi $ gridPitch gp) (advancePtr gcfsp maxWPlane)
            putStrLn (printf "%llu ops for (%f,%f) dataset" nops vmin vmax)
  where
    fi = fromIntegral
    grWidth = gridWidth gp
    scale = gridTheta gp
    wstep = gcfpStepW gcfp
    size i = min (gcfpMaxSize gcfp) (gcfpMinSize gcfp + gcfpGrowth gcfp * abs i)
    supps = map (fi . size . baselineMinWPlane wstep) bls
    uvws = map (advancePtr uwpptr . vblOffset) bls
    amps = map (advancePtr ampptr . vblOffset) bls
    maxWPlane = tsiz `div` 2
    gcfSupps = map (fi . size) [-maxWPlane .. maxWPlane]
gridWrapper _ _ _ _ = error "Wrong Vis or GCF or Grid location for CPU."

foreign import ccall rotateCPU :: PUVW -> PCD -> CInt -> Double -> IO ()

phaseRotate :: GridPar -> Vis -> IO Vis
phaseRotate gp vis = rotateCPU uvwp visp (fromIntegral n) scale >> return vis
  where
    CVector n uvwp = visPositions vis
    CVector _ visp = visData vis
    scale = gridTheta gp

grid :: Vis -> GCFSet -> UVGrid -> IO UVGrid
grid vis gcfset uvg = do
    gridWrapper gridKernelCPUFullGCF vis gcfset uvg
    normalize gptr (fi $ gridHeight gp) (fi $ gridPitch gp)
    return uvg
  where
    CVector _ gptr = uvgData uvg
    fi = fromIntegral
    gp = uvgPar uvg

-- What about the normalization here?
degrid :: UVGrid -> GCFSet -> Vis -> IO Vis
degrid uvg gcfset vis = do
  gridWrapper deGridKernelCPUFullGCF vis gcfset uvg
  freeVector (uvgData uvg)
  return vis

trivHints :: GridPar -> Vis -> GCFSet -> [ProfileHint]
trivHints _ _ _ = [floatHint]
