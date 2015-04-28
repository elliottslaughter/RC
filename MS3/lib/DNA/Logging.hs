{-# LANGUAGE BangPatterns, CPP #-}
-- | Logging.hs
--
-- Logging and profiling facilities. Log messages are written to GHC's
-- eventlog in the following format:
--
-- > TAG [ATTR]* message
--
-- The tag is a sequence of alphanumeric characters, usually in all
-- caps. The tag can be:
--
--  *  MSG: for simple log messages
--  *  FATAL: log messages reporting errors
--  *  SYNC: for synchronising time between nodes
--  *  START x/END x: sample of a performance metric (for profiling)
--
-- Attributes can be used to add (possibly optional) extra data to the
-- message. They are enclosed in square brackets and must precede the
-- message. Possible attributes are
--
--  * [pid=PID]: for the Cloud Haskell process ID. For messages
--    concerning the whole program, this may not be set.
--
--  * [SAMPLER:METRIC=VAL/TIME]: records the value of a performance
--    metric. When a time is given, it is the time that the counter
--    has been running.
--
--  * [hint:METRIC=VAL]: A performance hint by the program, such as
--    expected number of floating point operations.
--
-- Copyright (C) 2014-2015 Braam Research, LLC.
module DNA.Logging
    ( LoggerOpt(..)
    , initLogging

    , taggedMessage
    , eventMessage
    , synchronizationPoint
    , logDuration
    , logProfile
    , processAttributes

    , ProfileHint(..)
    , floatHint, ioHint, haskellHint, cudaHint
    ) where

import Control.Applicative
import Control.Distributed.Process (getSelfPid)
import Control.Exception           (evaluate)
import Control.Monad               (when,liftM)
import Control.Monad.IO.Class

import Data.Time
import Data.Maybe         (fromMaybe)
import Data.IORef

import GHC.Stats

import Debug.Trace        (traceEventIO)

#ifdef USE_CUDA
import Profiling.CUDA.Activity
import Profiling.CUDA.Metrics
#endif
import Profiling.Linux.Perf.Stat

import System.IO.Unsafe   (unsafePerformIO)
import System.Locale      (defaultTimeLocale)
import System.Mem         (performGC)

import DNA.Types

----------------------------------------------------------------
-- Modes of operation
----------------------------------------------------------------

-- | Modes of operation for the logger. Most additional attributes
-- cost performance, therefore default state is to run without any of
-- these modifiers.
data LoggerOpt = LoggerOpt
  { logOptVerbose ::  Int
    -- | The higher, the more additional information we output about
    -- what we are doing.
  , logOptMeasure :: String
    -- | Gather detailed statistics about the given group of
    -- performance metrics, at the possible expense of performance.
  }
  deriving (Show)

data LoggerState =
  LoggerState { loggerOpt :: LoggerOpt
              , loggerPerfCounters :: PerfStatGroup
              , loggerPerfEnabled :: IORef Int
#ifdef USE_CUDA
              , loggerCuptiEnabled :: IORef Int
#endif
              }

-- | Global logger state. This is a hack - it would be better if we
-- could put this somewhere into the DNA monad. On the other hand, the
-- profiling we do is a decidely global affair, so this makes a
-- certain amount of sense.
loggerStateVar :: IORef LoggerState
loggerStateVar = unsafePerformIO $ newIORef $ error "loggerStateVar not initialised!"

-- | Initialise logging facilities. This must be called once at
-- program start, before the first messages are being created.
initLogging :: LoggerOpt -> IO ()
initLogging opt = do

  -- Initialise various profiling sub-modules
  counters <- perfInit
#ifdef USE_CUDA
  cudaInit opt
#endif

  -- Set logger state
  perfEnabled <- newIORef 0
#ifdef USE_CUDA
  cuptiEnabled <- newIORef 0
#endif
  let state = LoggerState { loggerOpt          = opt
                          , loggerPerfCounters = counters
                          , loggerPerfEnabled  = perfEnabled
#ifdef USE_CUDA
                          , loggerCuptiEnabled = cuptiEnabled
#endif
                          }
  writeIORef loggerStateVar state

-- | Helper for activating a profiling module on-demand
enableProfileMod :: (LoggerState -> IORef Int) -> IO () -> IO ()
enableProfileMod loggerEnabled enable = do
  enabledVar <- loggerEnabled <$> readIORef loggerStateVar
  enabled <- atomicModifyIORef' enabledVar (\x -> (x+1,x))
  when (enabled == 0) enable

-- | Helper for deactivating a profiling model based on demand
disableProfileMod :: (LoggerState -> IORef Int) -> IO () -> IO ()
disableProfileMod loggerEnabled disable = do
  enabledVar <- loggerEnabled <$> readIORef loggerStateVar
  enabled <- atomicModifyIORef' enabledVar (\x -> (x-1,x))
  when (enabled == 1) disable

----------------------------------------------------------------
-- Message data types for logger
----------------------------------------------------------------

type Attr = (String, String)

-- | Generate the specified eventlog message
message :: MonadIO m
        => String -- ^ Message tag
        -> [Attr] -- ^ Message attributes
        -> String -- ^ Message body
        -> m ()
message tag attrs msg = do
    let formatAttr (attr, val) = ' ':'[':attr ++ '=': val ++ "]"
    liftIO $ traceEventIO $ concat (tag : map formatAttr attrs) ++ ' ':msg

-- | Output a custom-tag process message into the eventlog.
taggedMessage :: MonadProcess m
              => String         -- ^ Message tag
              -> String         -- ^ Message
              -> m ()
taggedMessage tag msg = do
    attrs <- processAttributes
    message tag attrs msg

-- | Put a global message into eventlog.
eventMessage :: MonadIO m => String -> m ()
eventMessage = message "MSG" []

-- | Put a message at the given verbosity level

-- | Synchronize timings - put into eventlog an event with current wall time.
synchronizationPoint :: MonadIO m => String -> m ()
synchronizationPoint msg = liftIO $ do
    utcTime <- getCurrentTime
    -- we are formatting time to number of seconds in POSIX epoch and
    -- fractional part in picoseconds.
    let timeString    = formatTime defaultTimeLocale "%s.%q" utcTime
        humanReadable = formatTime defaultTimeLocale "%F %X" utcTime
    message "SYNC" [("time", timeString)] msg
    message "MSG" [] $ "started at " ++ humanReadable

----------------------------------------------------------------
-- Profiling basics
----------------------------------------------------------------

data SamplePoint = StartSample | EndSample

-- | Put measurements about execution time of monadic action into
--   eventlog. Result of action is evaluated to WHNF.
measurement :: MonadIO m
               => (SamplePoint -> m [Attr])
                           -- ^ Measurements, might add extra attributes
               -> String   -- ^ Message
               -> [Attr]   -- ^ Attributes
               -> m a      -- ^ DNA action to profile
               -> m a
measurement sample msg attrs dna = do
    -- Get start sample
    sample0 <- sample StartSample
    message "START" (attrs ++ sample0) msg
    -- Perform action
    r <- liftIO . evaluate =<< dna
    -- Get end sample, return
    sample1 <- sample EndSample
    message "END" (attrs ++ sample1) msg
    return r

-- | Put measurements about execution time of monadic action into
--   eventlog. Result of action is evaluated to WHNF.
logDuration :: MonadProcess m => String -> m a -> m a
logDuration msg dna = do
    attrs <- processAttributes
    let sample _ = return [] -- measurement is implicit from START/END timestamp
    measurement sample msg attrs dna

----------------------------------------------------------------
-- Profiling
----------------------------------------------------------------

-- | A program annotation providing additional information about how
-- much work we expect the program to be doing in a certain phase. The
-- purpose of this hint is that we can set-up measurements to match
-- these numbers to the program's real performance.
--
-- Note that this is just a hint - a best effort should be made to
-- give a realistic estimate. As a rule of thumb, it is better to use
-- a more conservative estimate, as this will generally result in
-- lower performance estimates (in profiling, false positives are
-- better than false negatives).
data ProfileHint
    = FloatHint { hintFloatOps :: !Int -- ^ Number of single-precision operations
                , hintDoubleOps :: !Int -- ^ Number of double-precision operations
                }
      -- ^ Estimate for how much floating point operations the code is doing
    | IOHint { hintReadBytes :: !Int
             , hintWriteBytes :: !Int
             }
      -- ^ Estimate for how much data the program is reading or
      -- writing from/to external sources.
    | HaskellHint { hintAllocation :: !Int
                  }
      -- ^ Rough estimate for how much Haskell work we are doing.
    | CUDAHint { hintCopyBytesHost :: !Int
               , hintCopyBytesDevice :: !Int
               , hintCudaFloatOps :: !Int
               , hintCudaDoubleOps :: !Int
               }
      -- ^ CUDA statistics. The values are hints about how much data
      -- transfers we expect to be targetting the device and the host
      -- respectively. The FLOP hints will only be checked if logging
      -- is running in FLOP mode (uses instrumentation, which will
      -- reduce overall performance!).

-- | Default @FloatHint@.
floatHint :: ProfileHint
floatHint = FloatHint 0 0

-- | Default @IOHint@.
ioHint :: ProfileHint
ioHint = IOHint 0 0

-- | Default @HaskellHint@.
haskellHint :: ProfileHint
haskellHint = HaskellHint 0

-- | Default @CUDAHint@.
cudaHint :: ProfileHint
cudaHint = CUDAHint 0 0 0 0

-- | Main profiling function. The concrete information output to the
-- event log depends on the hints about the code's actions.
--
-- Generally, the more hints we have about the code's actions, the
-- better. However, also note that more hints generally means that we
-- are going to safe more information, so keep in mind that every hint
-- means a certain (constant) profiling overhead.
logProfile :: String           -- ^ Message. Will be used in profile view
                               -- to identify costs, so short and
                               -- recognisable names are preferred.
           -> [ProfileHint]    -- ^ Hints about the code's complexity.
           -> [Attr]           -- ^ Extra attributes to add to profile messages
           -> IO a             -- ^ The code to profile
           -> IO a
logProfile msg hints attrs = measurement (liftIO . sample) msg attrs
    where sample pt = concat `liftM` mapM (hintToSample pt) hints

-- | Generate identification attributes
processAttributes :: MonadProcess m => m [Attr]
processAttributes = do
    pid <- liftP getSelfPid
    return [("pid", show pid)]

-- | Takes a sample according to the given hint
hintToSample :: SamplePoint -> ProfileHint -> IO [Attr]
hintToSample pt fh@FloatHint{}
    = consHint pt "hint:float-ops" (hintFloatOps fh)
    . consHint pt "hint:double-ops" (hintDoubleOps fh)
    <$> floatCounterAttrs pt
hintToSample pt ioh@IOHint{}
    = consHint pt "hint:read-bytes" (hintReadBytes ioh)
    . consHint pt "hint:write-bytes" (hintWriteBytes ioh)
    <$> ioAttrs
hintToSample pt hh@HaskellHint{}
    = consHint pt "hint:haskell-alloc" (hintAllocation hh)
    <$> haskellAttrs
hintToSample pt ch@CUDAHint{}
    = consHint pt "hint:memcpy-bytes-host" (hintCopyBytesHost ch)
    . consHint pt "hint:memcpy-bytes-device" (hintCopyBytesDevice ch)
    . consHint pt "hint:gpu-float-ops" (hintCudaFloatOps ch)
    . consHint pt "hint:gpu-double-ops" (hintCudaDoubleOps ch)
    <$> cudaAttrs

-- | Prepend an attribute if this is the start point, and it is non-zero
consHint :: (Eq a, Num a, Show a)
           => SamplePoint -> String -> a -> [Attr] -> [Attr]
consHint EndSample   _ _ = id
consHint _           _ 0 = id
consHint StartSample n v = ((n, show v):)

-- | Prepend an attribute if it is non-zero
consAttrNZ :: (Eq a, Num a, Show a)
           => String -> a -> [Attr] -> [Attr]
consAttrNZ _ 0 = id
consAttrNZ n v = ((n, show v):)

-- | As @consAttrNZ@, but with reference time
consAttrNZT :: (Eq a, Num a, Show a)
           => String -> a -> a -> [Attr] -> [Attr]
consAttrNZT _ 0 _ = id
consAttrNZT n v t = ((n, show v ++ "/" ++ show t):)

----------------------------------------------------------------
-- perf_events sampling
----------------------------------------------------------------

-- | Do perf_event initialisation
perfInit :: IO PerfStatGroup
perfInit = perfEventOpen $ map snd floatCounterDescs

-- | The floating point counters, with associated names
floatCounterDescs :: [(String, PerfStatDesc)]
floatCounterDescs
  = [ ("cpu-cycles",        PerfDesc $ PERF_TYPE_HARDWARE PERF_COUNT_HW_CPU_CYCLES)
    , ("cpu-instructions",  PerfDesc $ PERF_TYPE_HARDWARE PERF_COUNT_HW_INSTRUCTIONS)
    , ("x87-ops",           PfmDesc "FP_COMP_OPS_EXE:X87")
    , ("scalar-float-ops",  PfmDesc "FP_COMP_OPS_EXE:SSE_FP_SCALAR_SINGLE")
    , ("scalar-double-ops", PfmDesc "FP_COMP_OPS_EXE:SSE_SCALAR_DOUBLE")
    , ("sse-float-ops",     PfmDesc "FP_COMP_OPS_EXE:SSE_PACKED_SINGLE")
    , ("sse-double-ops",    PfmDesc "FP_COMP_OPS_EXE:SSE_FP_PACKED_DOUBLE")
    , ("avx-float-ops",     PfmDesc "SIMD_FP_256:PACKED_SINGLE")
    , ("avx-double-ops",    PfmDesc "SIMD_FP_256:PACKED_DOUBLE")
    ]

-- | Generate message attributes from current floating point counter values
floatCounterAttrs :: SamplePoint -> IO [Attr]
floatCounterAttrs pt = do

    -- Enable perf_events if required
    counters <- loggerPerfCounters <$> readIORef loggerStateVar
    case pt of
      StartSample -> enableProfileMod loggerPerfEnabled $ perfEventEnable counters
      EndSample   -> disableProfileMod loggerPerfEnabled $ perfEventDisable counters

    -- Get counters from perf_event
    vals <- perfEventRead counters
    -- Generate attributes
    let fmtName (name, _) = "perf:" ++ name
        fmtVal stat = show (psValue stat) ++ "/" ++ show (psTimeRunning stat)
    return $ zip (map fmtName floatCounterDescs) (map fmtVal vals)

----------------------------------------------------------------
-- I/O data sampling
----------------------------------------------------------------

-- | Generate message attributes for procces I/O statistics
ioAttrs :: IO [Attr]
ioAttrs = do

    -- Read /proc/self/io - not the full story by any means, especially
    -- when consindering mmap I/O (TODO!), but it's easy.
    ios <- map (break (==':')) . lines <$> readFile "/proc/self/io"
    let io name = drop 2 $ fromMaybe "" $ lookup name ios
    return [ ("proc:read-bytes", io "read_bytes")
           , ("proc:write-bytes", io "write_bytes")
           ]

----------------------------------------------------------------
-- Haskell RTS sampling
----------------------------------------------------------------

-- | Generate message attributes for procces I/O statistics
haskellAttrs :: IO [Attr]
haskellAttrs = do

    -- This might be slightly controversial: This forces a GC so we get
    -- statistics about the *true* memory residency.
    performGC

    -- Now get statistics
    available <- getGCStatsEnabled
    if not available then return [] else do
        stats <- getGCStats
        return [ ("rts:haskell-alloc",   show $ bytesAllocated stats)
               , ("rts:gc-bytes-copied", show $ bytesCopied stats)
               , ("rts:mut-time",        show $ mutatorCpuSeconds stats)
               , ("rts:gc-time",         show $ gcCpuSeconds stats)
               , ("rts:heap-size",       show $ currentBytesUsed stats)
               ]

----------------------------------------------------------------
-- CUDA statistics sampling
----------------------------------------------------------------

#ifdef USE_CUDA

-- | CUPTI metrics to use depending on configuration. Returns a table
-- relating metrics to output attribute names.
cudaMetricNames :: LoggerOpt -> [(String, String)]
cudaMetricNames opt = case logOptMeasure opt of
  "fp-inst" -> [ ("cuda:gpu-double-instrs", "inst_fp_32")
               , ("cuda:gpu-float-instrs", "inst_fp_64")
               ]
  "float-ops" -> [ ("cuda:gpu-float-ops", "flop_count_sp")
                 , ("cuda:gpu-float-ops-add", "flop_count_sp_add")
                 , ("cuda:gpu-float-ops-mul", "flop_count_sp_mul")
                 , ("cuda:gpu-float-ops-fma", "flop_count_sp_fma")
                 ]
  "double-ops" -> [ ("cuda:gpu-double-ops", "flop_count_dp")
                  , ("cuda:gpu-double-ops-add", "flop_count_dp_add")
                  , ("cuda:gpu-double-ops-mul", "flop_count_dp_mul")
                  , ("cuda:gpu-double-ops-fma", "flop_count_dp_fma")
                  ]
  _other -> [ ("cuda:gpu-instructions", "inst_executed") ]

cudaInit :: LoggerOpt -> IO ()
cudaInit opt = do

  when (logOptMeasure opt `elem` ["help", "list"]) $
    putStrLn "Supported metric groups: fp-inst, float-ops, double-ops"

  cuptiMetricsInit $ map snd $ cudaMetricNames opt

cudaAttrs :: SamplePoint -> IO [Attr]
cudaAttrs pt = do

    -- Enable CUPTI if required
    case pt of
      StartSample -> enableProfileMod loggerCuptiEnabled $
                     cuptiEnable >> cuptiMetricsEnable
      EndSample   -> disableProfileMod loggerCuptiEnabled $
                     cuptiDisable >> cuptiMetricsDisable

    -- Flush, so statistics are current
    cuptiFlush

    -- Then read stats
    memsetTime <- cuptiGetMemsetTime
    kernelTime <- cuptiGetKernelTime
    overheadTime <- cuptiGetOverheadTime
    memsetBytes <- cuptiGetMemsetBytes
    memcpyTimeH <- cuptiGetMemcpyTimeTo CUptiHost
    memcpyTimeD <- (+) <$> cuptiGetMemcpyTimeTo CUptiDevice
                       <*> cuptiGetMemcpyTimeTo CUptiArray
    memcpyBytesH <- cuptiGetMemcpyBytesTo CUptiHost
    memcpyBytesD <- (+) <$> cuptiGetMemcpyBytesTo CUptiDevice
                        <*> cuptiGetMemcpyBytesTo CUptiArray

    -- Read metrics
    state <- readIORef loggerStateVar
    metrics <- cuptiGetMetrics
    let metricNames = map fst $ cudaMetricNames $ loggerOpt state
        formatMetric m = show m ++ "/" ++ show kernelTime
        metricAttrs = zipWith (,) metricNames (map formatMetric metrics)

    -- Generate attributes
    return $ consAttrNZ "cuda:kernel-time" kernelTime
           $ consAttrNZ "cuda:overhead-time" overheadTime
           $ consAttrNZT "cuda:memset-bytes" memsetBytes memsetTime
           $ consAttrNZT "cuda:memcpy-bytes-host" memcpyBytesH memcpyTimeH
           $ consAttrNZT "cuda:memcpy-bytes-device" memcpyBytesD memcpyTimeD
           $ metricAttrs

#else
cudaAttrs :: IO [Attr]
cudaAttrs = return []
#endif

