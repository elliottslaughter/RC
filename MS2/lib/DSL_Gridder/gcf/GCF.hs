{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE
       TypeOperators
     , CPP
     , TypeFamilies
     , TypeSynonymInstances
     , FlexibleInstances
     , BangPatterns
     #-}

module Main where

import Data.List                             as P
import Prelude                               as P
import Data.Array.Accelerate                 as A
import Data.Array.Accelerate.Data.Complex    as A
import Data.Array.Accelerate.Math.FFT        as FFT
import Data.Array.Accelerate.Math.DFT.Centre as FFT
import Data.Array.Accelerate.IO              as A
-- import Data.Array.Accelerate.Interpreter     as A
import Data.Array.Accelerate.CUDA            as A

import Foreign.Ptr (castPtr)
import Foreign.Storable (Storable(..))
import qualified Data.Vector.Storable as VS

type CxDouble = Complex Double

mgrid :: Double -> Double -> Int -> [Double]
mgrid lo hi n =
  let
    diff = (hi - lo) / P.fromIntegral (n - 1)
    (half, r) = n `divMod` 2
    mid = if r > 0 then [(hi + lo) / 2.0] else []
  in P.take half (P.iterate (+ diff) lo) P.++ mid P.++ P.reverse (P.take half (P.iterate (\v -> v - diff) hi))

waf_full :: Int -> Int -> Acc (Scalar Double) -> Acc (Scalar Double) -> Acc (Array DIM2 CxDouble)
waf_full n over t2a wa = centre2D $ fft2D' Inverse no no (centre2D cpp0)
  where
    no = n * over
    cpp0 = permute (+) def mapndx cp
    cp = A.map (\y -> exp $ A.constant ((0:+2) * (pi:+0) :: CxDouble) * (lift $ y :+ 0)) ph
    --
    padw = A.constant (n * (over - 1) `div` 2)
    -- Z :. nr :. nc = unlift (shape cp) :: Z :. Exp Int :. Exp Int
    -- def = A.generate (index2 (nr + padw + padw) (nc + padw + padw)) (\_ -> A.constant $ 0.0 :+ 0.0)
    ne = A.constant n
    def = A.generate (index2 (ne + padw + padw) (ne + padw + padw)) (\_ -> A.constant $ 0.0 :+ 0.0)
    mapndx ndx = let i2 = unindex2 ndx
                 in index2 (A.fst i2 + padw) (A.snd i2 + padw)
    --
    ph = A.map (\y -> the wa * (1-sqrt(1-y))) r2
    --
    r2 = let
        (a, t) = ucsN
        l f x y = (f x, f y)
        (av, tv) = l (A.map (* the t2a)) (use a) (use t)
        (av2, tv2) = l (A.map (^(2::Int))) av tv
      in A.zipWith (+) av2 tv2
    --
    ucsN = let
        grid = mgrid (-1.0) 1.0 n
        a = P.replicate n grid
        t = P.transpose a
        cvt arr = fromList (Z :. n :. n) (concat arr)
      in (cvt t, cvt a)

wextract :: Acc (Array DIM2 CxDouble) -> Acc (Scalar Int) -> Acc (Scalar Int) -> Int -> Int -> Acc (Array DIM2 CxDouble)
wextract arr ia ja over supp = exmid
  where
    exmid = backpermute (lift $ Z :. diam :. diam) mapex xnorm
    diam = 2 * supp + 1
    mapex ndx =
      let i2 = unindex2 ndx
      in index2 (A.fst i2 + outnr `div` 2 - suppex) (A.snd i2 + outnc `div` 2 - suppex)
    xnorm = A.map (* invsx) x
    invsx = lift (1.0 / sx :+ 0.0)
    sx = the (A.sum $ A.map real x)
    suppex = A.constant supp
    x = backpermute outshape mapndx arr
    outshape = lift $ Z :. outnr :. outnc
    i = the ia
    j = the ja
    outnr = (nr - i) `div` overex
    outnc = (nc - j) `div` overex
    overex = A.constant over
    mapndx ndx =
      let i2 = unindex2 ndx
      in index2 (A.fst i2 * overex + i) (A.snd i2 * overex + j)
    Z :. nr :. nc = unlift (shape arr) :: Z :. Exp Int :. Exp Int

{-
#define W 3
-- Unlike in Bojan's code we add w-dimension right here.

wkernaf_with :: (Exp CxDouble -> Exp CxDouble) -> Int -> Int -> Int -> Acc (Scalar Double) -> Acc (Scalar Double) -> Acc (Array DIM5 CxDouble)
wkernaf_with fun n over supp t2a wdiffa =
  let
    wf = waf_full n over t2a
    ws = P.take W $ P.iterate (+ (the wdiffa)) (A.constant 0.0)
    resshape = Z :. (W :: Int) :. over :. over :. supp :. supp
    emb = unit . constant
    nullvec :: Acc (Vector CxDouble)
    nullvec = use $ fromList (Z :. 0) []
  in reshape (lift resshape) $
       foldr (A.++) nullvec [A.map fun $ flatten $ wextract (wf $ unit w) (emb i) (emb j) over supp | w <- ws, i <- [0..over-1], j <- [0..over-1]]

wkernaf, wkernaf_conj :: Int -> Int -> Int -> Acc (Scalar Double) -> Acc (Scalar Double) -> Acc (Array DIM5 CxDouble)
wkernaf = wkernaf_with id
wkernaf_conj = wkernaf_with conjugate
 -}

wkernaf0, wkernaf_conj0 :: Int -> Int -> Int -> Acc (Scalar Double) -> Acc (Scalar (Int, Int, Double)) -> Acc (Array DIM2 CxDouble)
wkernaf0 n supp over t2a arg =
  let
    (overx, overy, w) = unlift (the arg)
    wf = waf_full n over t2a
  in
    wextract (wf $ unit w) (unit overx) (unit overy) over supp
wkernaf_conj0 n supp over t2a arg = A.map conjugate $ wkernaf0 n supp over t2a arg

-- Quick and dirty storable for Complex
instance Storable CxDouble where
  sizeOf _ = 16
  alignment _ = 16
  peek p = do
    re <- peek (castPtr p)
    im <- peekByteOff p 8
    return (re :+ im)
  poke p (re :+ im) = do
    poke (castPtr p) re
    pokeByteOff p 8 im

-- Why on earth accelerate has complex computations,
-- but no facilities to export complex vectors (only pair of double vectors)???
toFlatVector :: Shape sh => Array sh CxDouble -> VS.Vector CxDouble
toFlatVector a =
  let ((_, res), ims) = toVectors a
  in VS.zipWith (:+) res ims

main :: IO ()
main =
  -- Only to test the speed
  let !res = VS.concat $ P.map toFlatVector $ stream (wkernaf_conj0 256 8 16 (unit 0.02239)) [ fromList Z [(i, j, w)] | w <- [10.0 .. 42.0], i <- [0..7], j <- [0..7] ]
  in return ()
