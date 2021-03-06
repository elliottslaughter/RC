{-# LANGUAGE OverloadedStrings, CPP #-}

module Kernel.Config where

import Control.Applicative
import Data.Yaml
import Data.List
import Data.Ord  ( comparing )
import Text.Read ( readMaybe )

import Flow ( Schedule(..) )

data Config = Config
  { cfgInput    :: [OskarInput] -- ^ Input Oskar files
  , cfgPoints   :: Int      -- ^ Number of points to read from Oskar file
  , cfgNodes    :: Int      -- ^ Number of data sets to process in parallel
  , cfgLoops    :: Int      -- ^ Number of major loops to run
  , cfgLong     :: Double   -- ^ Phase centre longitude
  , cfgLat      :: Double   -- ^ Phase centre latitude
  , cfgOutput   :: FilePath -- ^ File name for the output image
  , cfgGrid     :: GridPar
  , cfgGCF      :: GCFPar
  , cfgClean    :: CleanPar
  , cfgStrategy :: StrategyPar
  }
instance FromJSON Config where
  parseJSON (Object v)
    = Config <$> v .: "input"
             <*> v .: "points"
             <*> v .: "nodes"
             <*> (v .: "loops" <|> return (cfgLoops defaultConfig))
             <*> (v .: "long" <|> return (cfgLong defaultConfig))
             <*> (v .: "lat" <|> return (cfgLat defaultConfig))
             <*> v .: "output"
             <*> (v .: "grid" <|> return (cfgGrid defaultConfig))
             <*> v .: "gcf"
             <*> (v .: "clean" <|> return (cfgClean defaultConfig))
             <*> (v .: "strategy" <|> return (cfgStrategy defaultConfig))
  parseJSON _ = mempty

data OskarInput = OskarInput
  { oskarFile   :: FilePath -- ^ Oskar file
  , oskarWeight :: Double   -- ^ Complexity
  , oskarRepeat :: Int      -- ^ Repeats
  }
instance FromJSON OskarInput where
  parseJSON (Object v)
    = OskarInput <$> v .: "file" <*> v .: "weight"
                 <*> (v .: "repeats" <|> return 1)
  parseJSON _ = mempty

data GridKernelType
  = GridKernelCPU
#ifdef USE_CUDA
  | GridKernelGPU
  | GridKernelNV
#endif
  deriving (Eq, Ord, Enum, Show)

data DegridKernelType
  = DegridKernelCPU
#ifdef USE_CUDA
  | DegridKernelGPU
#endif
  deriving (Eq, Ord, Enum, Show)

instance Read GridKernelType where
  readsPrec _ str = case lex str of
    ("cpu", rest):_ -> [(GridKernelCPU, rest)]
#ifdef USE_CUDA
    ("gpu", rest):_ -> [(GridKernelGPU, rest)]
    ("nv",  rest):_ -> [(GridKernelNV,  rest)]
#endif
    _other          -> []

instance Read DegridKernelType where
  readsPrec _ str
    | Just rest <- stripPrefix "cpu" str  = [(DegridKernelCPU, rest)]
#ifdef USE_CUDA
    | Just rest <- stripPrefix "gpu" str  = [(DegridKernelGPU, rest)]
#endif
    | otherwise = []

data GridPar = GridPar
  { gridWidth :: !Int  -- ^ Width of the uv-grid/image in pixels
  , gridHeight :: !Int -- ^ Neight of the uv-grid/image in pixels
  , gridPitch :: !Int  -- ^ Distance between rows in grid storage. Can
                       -- be larger than width if data is meant to be
                       -- padded.
  , gridTheta :: !Double  -- ^ Size of the field of view in radians

  , gridTiles  :: !Int -- ^ Number of tiles in U and V domains
  , gridFacets :: !Int -- ^ Number of facets in L and M domains
  , gridBins   :: !Int -- ^ Number of bins in W domain
  }
instance FromJSON GridPar where
  parseJSON (Object v)
    = GridPar <$> v .: "width" <*> v .: "height"
              <*> v .: "pitch"
              <*> v .: "theta"
              <*> (v .: "uv-tiles" <|> return 1)
              <*> (v .: "lm-facets" <|> return 1)
              <*> (v .: "w-bins" <|> return 1)
  parseJSON _ = mempty

data GCFFile = GCFFile
  { gcfFile :: FilePath
  , gcfSize :: Int
  , gcfW :: Double
  }
instance FromJSON GCFFile where
  parseJSON (Object v)
    = GCFFile <$> v .: "file" <*> v .: "size" <*> v .: "w"
  parseJSON _ = mempty
data GCFPar = GCFPar
  { gcfFiles :: [GCFFile]
  , gcfOver :: Int
  }
instance FromJSON GCFPar where
  parseJSON (Object v)
    = GCFPar <$> v .: "list" <*> v .: "over"
  parseJSON _ = mempty

gcfMaxSize :: GCFPar -> Int
gcfMaxSize = maximum . map gcfSize . gcfFiles

-- | Returns the GCF to use for the given w-range.
gcfGet :: GCFPar -> Double -> Double -> GCFFile
gcfGet gcfp w0 w1 = maximumBy (comparing gcfW) $
                    filter ((<= w) . gcfW) $
                    gcfFiles gcfp
  where w = max (abs w0) (abs w1)

data CleanPar = CleanPar
  { cleanGain      :: Double
  , cleanThreshold :: Double
  , cleanCycles    :: Int
  }
instance FromJSON CleanPar where
  parseJSON (Object v)
    = CleanPar <$> v .: "gain" <*> v .: "threshold"
               <*> v .: "cycles"
  parseJSON _ = mempty

data StrategyPar = StrategyPar
  { stratGridder   :: GridKernelType -- ^ Type of gridder: 0-CPU Halide, 1-GPU Halide, 2-GPU NVidia
  , stratDegridder :: DegridKernelType -- ^ Type of degridder: 0-CPU Halide, otherwise-GPU Halide
  , stratTileSched :: (Schedule, Schedule) -- ^ Strategy to use for U and V distribution
  , stratFacetSched :: (Schedule, Schedule) -- ^ Strategy to use for L and M distribution
  , stratUseFiles :: Bool
  }
instance FromJSON StrategyPar where
  parseJSON (Object v)
    = StrategyPar
        <$> (fmap (readMaybe =<<) $ v .:? "gridder_type")   .!= stratGridder defaultStrategyPar
        <*> (fmap (readMaybe =<<) $ v .:? "degridder_type") .!= stratDegridder defaultStrategyPar
        <*> (fmap (readMaybe =<<) $ v .:? "uv-tiles-sched") .!= stratTileSched defaultStrategyPar
        <*> (fmap (readMaybe =<<) $ v .:? "lm-facets-sched") .!= stratFacetSched defaultStrategyPar
        <*> v .:? "use_files" .!= stratUseFiles defaultStrategyPar
  parseJSON _ = mempty

defaultStrategyPar :: StrategyPar
defaultStrategyPar = StrategyPar
  { stratGridder    = GridKernelCPU
  , stratDegridder  = DegridKernelCPU
  , stratTileSched  = (SeqSchedule, SeqSchedule)
  , stratFacetSched = (SeqSchedule, SeqSchedule)
  , stratUseFiles   = False
  }

-- | Default configuration. Gets overridden by the actual
-- implementations where paramters actually matter.
defaultConfig :: Config
defaultConfig = Config
  { cfgInput    = []
  , cfgPoints   = 32131 * 200
  , cfgNodes    = 0
  , cfgLoops    = 1
  , cfgLong     = 72.1 / 180 * pi -- mostly arbitrary, and probably wrong in some way
  , cfgLat      = 42.6 / 180 * pi -- ditto
  , cfgOutput   = ""
  , cfgGrid     = GridPar 0 0 0 0 1 1 1
  , cfgGCF      = GCFPar [] 8
  , cfgClean    = CleanPar 0 0 0
  , cfgStrategy = defaultStrategyPar
  }

-- | Number of data sets we can run in parallel with the given number of nodes
cfgParallelism :: Config -> Int
cfgParallelism cfg =
  cfgNodes cfg `div` mbPar gridTiles (fst . stratTileSched)
               `div` mbPar gridTiles (snd . stratTileSched)
               `div` mbPar gridFacets (fst . stratFacetSched)
               `div` mbPar gridFacets (snd . stratFacetSched)
 where mbPar amount sched = case sched (cfgStrategy cfg) of
         ParSchedule -> amount (cfgGrid cfg)
         SeqSchedule -> 1

-- | Image dimensions for all facets together
gridImageWidth :: GridPar -> Int
gridImageWidth gp = gridWidth gp * gridFacets gp

gridImageHeight :: GridPar -> Int
gridImageHeight gp = gridHeight gp * gridFacets gp

-- | Grid scale: FoV size in radians of one facet
gridScale :: GridPar -> Double
gridScale gp = gridTheta gp / fromIntegral (gridFacets gp)

-- | Convert a grid position into an u/v coordinate
gridXY2UV :: GridPar -> Int -> Double
gridXY2UV gp z = fromIntegral (z - gridHeight gp `div` 2) / gridScale gp
