{-# LANGUAGE DataKinds #-}

module Kernel.Degrid where

import Data.Int
import qualified Data.Map as Map

import Flow.Builder
import Flow.Halide
import Flow.Kernel
import Flow

import Kernel.Data

-- For FFI
import Data.Vector.HFixed.Class ()
import Flow.Halide.Types ()

-- | Trivial kernel for distributing the grid. This is simply about
-- returning the grid unchanged. *Seriously* something dna-flow should
-- learn to to automatically at some point.
distributeGrid :: DDom -> DDom -> LMDom -> GridPar -> Flow FullUVGrid -> Kernel FullUVGrid
distributeGrid ddom0 ddom1 (ldom, mdom) gp =
  mappingKernel "distribute grid" ((RegionRepr ddom0 $ halrWrite $ fullUVGRepr gp) :. Z)
                                  (RegionRepr ddom1 $ RegionRepr ldom $ RegionRepr mdom $ fullUVGRepr gp) $
    \[uvg] _ -> return $ head $ Map.elems uvg

type ForeignDegridder = HalideBind Double (HalideBind Int32 (HalideFun '[GCFsRepr, FullUVGRepr, VisRepr] VisRepr))
type DegridKernel = GridPar -> GCFPar    -- ^ Configuration
                 -> UVDom -> WDom        -- ^ u/v/w visibility domains
                 -> Flow GCFs -> Flow FullUVGrid -> Flow Vis
                 -> Kernel Vis

-- | Make degridder kernel binding
mkDslDegridKernel :: String -> ForeignDegridder -> DegridKernel
mkDslDegridKernel kn fd gp gcfp uvdom wdom =
  halideKernel3 kn (gcfsRepr wdom gcfp)
                   (fullUVGRepr gp)
                   (visRepr uvdom wdom)
                   (visRepr uvdom wdom) $
  fd `halideBind` gridScale gp
     `halideBind` fromIntegral (gridHeight gp)

foreign import ccall unsafe kern_degrid      :: ForeignDegridder
foreign import ccall unsafe kern_degrid_gpu1 :: ForeignDegridder

degridKernel, degridKernelGPU :: DegridKernel
degridKernel    = mkDslDegridKernel "degridKernel"    kern_degrid
degridKernelGPU = mkDslDegridKernel "degridKernelGPU" kern_degrid_gpu1

selectDegridKernel :: Int -> (DegridKernel, [ProfileHint])
selectDegridKernel n
  | n == 0 = (degridKernel, [floatHint, memHint])
  | otherwise = (degridKernelGPU, [cudaHint])
