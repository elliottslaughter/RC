-- |CmdLine.hs
--
-- Command-line options parsing, using optparser-applicative.
--
-- Copyright (C) 2014 Braa Research, LLC.
module DNA.CmdOpts (
      Options(..)
    , MasterOptions(..)
    , CommonOpts(..)
    , dnaParseCommandLineOpts
    , dnaParseCommandLineAndRun
    ) where

import Control.Concurrent
import Control.Distributed.Process
import Options.Applicative
import System.Environment (getProgName)

import DNA.SimpleLocalNetWithoutDiscovery
import DNA.Channel.File



-- | Command line options for a program.
data Options
    = Master  CommonOpts      MasterOptions   [String]
    | Slave   CommonOpts      [String]
    deriving (Show)

-- | Options common between slave and master.
data CommonOpts = CommonOpts
    { commonOptsCADFileName         :: Maybe String
    , commonOptsHost                :: String
    , commonOptsPort                :: String
    }
    deriving (Show)

-- | Master-specific options
data MasterOptions = MasterOptions
    { masterOptsCrash               :: Bool
    , masterOptsFilename            :: String
    }
    deriving (Show)


-- | Parse options.
optionsParser :: String -> ParserInfo Options
optionsParser name =
    info (helper <*> (subparser (master <> slave)))
         (  fullDesc
         <> progDesc "run a distributed dot product program as master or slave on IP:PORT binding"
         <> header (name++" Cloud Haskell implementation")
         )
  where
    master = command "master"
           $ info (Master <$> commonOptions <*> masterOptions <*> restParser)
                  (fullDesc <> progDesc "run as master on IP:PORT")
    slave = command "slave"
          $ info (Slave <$> commonOptions <*> restParser)
                 (fullDesc <> progDesc "run as slave on IP:PORT"))
    masterOptions = MasterOptions <$> crashOpt <*> filenameOpt
    commonOptions = CommonOpts <$> cadFile <*> ip <*> port
    cadFile = optional $ strOption ( metavar "CAD"
                                  <> long "cad"
                                  <> help "Filename of cluster architecture description file.")
    filenameOpt   = strOption ( metavar "FILE"
                             <> long "filename"
                             <> short 'f'
                             <> help "Filename to read data from."
                             <> value "float_file.txt"
                              )
    crashOpt      = switch ( long "crash"
                          <> short 'c'
                          <> help "make one node to crash.")
    ip            = strOption ( metavar "IP"
                             <> long "ip"
                             <> short 'i'
                             <> help "IP address"
                              )
    port          = strOption (metavar "PORT" <> long "port" <> short 'p' <> help "port for binnding")
    restParser    = many (argument str (metavar "ARGS"))


-- | An interface to parse command line options. Returns options
--   parsed as data type @Options@.
dnaParseCommandLineOpts :: IO Options
dnaParseCommandLineOpts =
    progName <- getProgName
    execParser $ optionsParser progName


-- | Parse command line option and start program
dnaParseCommandLineAndRun :: RemoteTable -> (MasterOptions -> Backend -> [NodeId] -> Process ()) -> IO ()
dnaParseCommandLineAndRun remoteTable master = do
    options <- dnaParseCommandLineOpts
    case options of
        Master (CommonOpts cadFile ip port) masterOptions _ -> do
            backend <- initializeBackend cadFile ip port remoteTable
            startMaster backend (master masterOptions backend)
            liftIO $ threadDelay 100
        Slave (CommonOpts cadFile ip port) _ -> do
            backend <- initializeBackend cadFile ip port remoteTable
            startSlave backend
