{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import Data.Typeable

import Flow
import Flow.Vector

import Foreign.C

import Data.Vector.HFixed.Class ()

-- Data tags
data Vec deriving Typeable
data Sum deriving Typeable

-- Abstract flow signatures
f, g :: Flow Vec
f = flow "f"
g = flow "g"
pp :: Flow Vec -> Flow Vec -> Flow Vec
pp = flow "product"
a :: Flow Vec -> Flow Sum
a = flow "sum"
ddp :: Flow Sum
ddp = a $ pp f g

-- Vector representation
type VecRepr = DynHalideRepr Float Vec
vecRepr :: DomainHandle Range -> VecRepr
vecRepr = DynHalideRepr
type SumRepr = HalideRepr Z Float Sum
sumRepr :: SumRepr
sumRepr = HalideRepr Z

-- Kernels

fKern :: DomainHandle Range -> Kernel Vec
fKern size = halideKernel0 "f" (vecRepr size) kern_generate_f
foreign import ccall unsafe kern_generate_f :: HalideFun '[] VecRepr

gKern :: DomainHandle Range -> Kernel Vec
gKern size = halideKernel0 "g" (vecRepr size) kern_generate_g
foreign import ccall unsafe kern_generate_g :: HalideFun '[] VecRepr

ppKern :: DomainHandle Range -> Flow Vec -> Flow Vec -> Kernel Vec
ppKern size = halideKernel2 "pp" (vecRepr size) (vecRepr size) (vecRepr size)
                            kern_dotp
foreign import ccall unsafe kern_dotp :: HalideFun '[ VecRepr, VecRepr ] VecRepr

aKern :: DomainHandle Range -> Flow Vec -> Kernel Sum
aKern size = halideKernel1 "a" (vecRepr size) sumRepr kern_sum
foreign import ccall unsafe kern_sum :: HalideFun '[ VecRepr ] SumRepr

printKern :: Flow Sum -> Kernel Sum
printKern = kernel "print" (sumRepr :. Z) sumRepr $ \case
  [(sv,_)]-> \_ -> do
    s <- peekVector (castVector sv :: Vector Float) 0
    putStrLn $ "Sum: " ++ show s
    return sv
  _other -> fail "printKern: Received wrong number of input buffers!"

-- | Dot product, non-distributed
dpStrat :: Int -> Strategy ()
dpStrat size = do

  -- Make vector domain
  dom <- makeRangeDomain 0 size

  -- Calculate ddp for the whole domain
  bind f (fKern dom)
  bind g (gKern dom)
  bindRule pp (ppKern dom)
  bindRule a (aKern dom)
  calculate ddp
  rebind ddp printKern

-- | Dot product, distributed
ddpStrat :: Int -> Strategy ()
ddpStrat size = do

  -- Make vector domain
  dom <- makeRangeDomain 0 size

  -- Calculate ddp for the whole domain
  split dom 10 $ \regs ->
    distribute regs SeqSchedule $ do
      bind f (fKern regs)
      bind g (gKern regs)
      bind (pp f g) (ppKern regs f g)
  bindRule a (aKern dom)
  calculate ddp
  rebind ddp printKern

main :: IO ()
main = do
  let size = 10000
  dumpSteps $ ddpStrat size
  execStrategy $ ddpStrat size
  putStrLn $ "Expected: " ++ show ((size-1)*size`div`20)
