{-# LANGUAGE OverloadedStrings #-}

module  PayChanServer.Init where


import           PayChanServer.App  (mainRoutes)

import           PayChanServer.Util
import           PayChanServer.Config.Types
import           PayChanServer.Config.Util
import           PayChanServer.Types (ServerSettleConfig(..))
import           PayChanServer.Settlement (settleChannel)

import           PayChanServer.DB (tryDBRequest, waitConnect)
import           ChanStore.Interface  as DBConn
import           SigningService.Interface (getPubKey)

import           Common.Common (pathParamEncode)

import           Snap (SnapletInit, makeSnaplet, addRoutes)
import           Data.String.Conversions (cs)
import           Control.Monad          (when)
import           Control.Monad.IO.Class (liftIO)
import qualified System.Posix.Signals as Sig
import           Control.Concurrent (ThreadId)
import           Control.Concurrent (throwTo)
import qualified Control.Exception as E
import           Data.Maybe (isNothing)
import           Control.Exception (try)



appInit :: Config -> ConnManager -> SnapletInit App App
appInit cfg databaseConn = makeSnaplet "PayChanServer" "RESTful Bitcoin payment channel server" Nothing $ do
    -- Debug
    debug <- liftIO $ configDebugIsEnabled cfg
    when debug $ liftIO $
        putStrLn ("############# RUNNING IN DEBUG MODE #############") >>
        putStrLn ("## Fake funding accepted & settlement disabled ##") >>
        putStrLn ("#################################################")

    bitcoinNetwork <- liftIO (configLookupOrFail cfg "bitcoin.network")
    liftIO $ setBitcoinNetwork bitcoinNetwork

    (ServerSettleConfig settleFee settlePeriod) <- liftIO $ getServerSettleConfig cfg

    openConfig@(OpenConfig minConfOpen basePrice addSettleFee _) <- OpenConfig <$>
            liftIO (configLookupOrFail cfg "open.fundingTxMinConf") <*>
            liftIO (configLookupOrFail cfg "open.basePrice") <*>
            liftIO (configLookupOrFail cfg "open.priceAddSettlementFee") <*>
            liftIO (configLookupOrFail cfg "open.minDurationHours")
    let confOpenPrice = if addSettleFee then basePrice + settleFee else basePrice

    signingServiceConn <- liftIO $ getSigningServiceConn cfg
    bitcoindRPCConf <- liftIO $ getBitcoindConf cfg
    let settleChanFunc = settleChannel databaseConn signingServiceConn bitcoindRPCConf settleFee

    liftIO $ putStr $ "Testing database connection... "
    maybeRes <- liftIO . waitConnect "database" $ DBConn.chanGet databaseConn dummyKey
    liftIO $ putStrLn $ if isNothing maybeRes then "success." else "something is horribly broken"

    liftIO $ putStr "Contacting SigningService for public key... "
    pubKey <- liftIO . waitConnect "SigningService" $ getPubKey signingServiceConn
    liftIO $ putStrLn $ "success: " ++ cs (pathParamEncode pubKey)

    let basePathVersion = "/v1"
    addRoutes $ mainRoutes debug basePathVersion

    settlePeriod <- liftIO $ configLookupOrFail cfg "settlement.settlementPeriodHours"

    return $ App databaseConn pubKey
                 openConfig confOpenPrice settlePeriod
                 basePathVersion settleChanFunc


installHandlerKillThreadOnSig :: Sig.Signal -> ThreadId -> IO Sig.Handler
installHandlerKillThreadOnSig sig tid =
    Sig.installHandler
          sig
          (Sig.CatchInfo $ \ci -> do
              putStrLn ("Received signal: " ++
                  show (Sig.siginfoSignal ci) ++
                  ". Killing main thread...")
              throwTo tid E.UserInterrupt)
          Nothing --(Just Sig.fullSignalSet)
