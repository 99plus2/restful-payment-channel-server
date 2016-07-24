{-# LANGUAGE OverloadedStrings #-}

module Server.Init where


import           Server.App  (mainRoutes)

import           Server.Config
import           Server.Config.Types
import           Server.Types (OpenConfig(..), ServerSettleConfig(..))

import           Common.Common (pathParamEncode)
import           Data.String.Conversions (cs)

import           Server.ChanStore.Types (ConnManager)
-- import           Server.ChanStore.Settlement (settleChannelEither)
import           SigningService.Interface (settleChannel)
import           Server.DB (trySigningRequest)

import qualified Network.Haskoin.Crypto as HC
import           Snap (SnapletInit, makeSnaplet, addRoutes)

import           Control.Monad.IO.Class (liftIO)
import qualified System.Posix.Signals as Sig
import           Control.Concurrent (ThreadId)
import           Control.Concurrent (throwTo)
import qualified Control.Exception as E

appInit :: Config -> ConnManager -> SnapletInit App App
appInit cfg chanOpenMap = makeSnaplet "PayChanServer" "RESTful Bitcoin payment channel server" Nothing $ do

    bitcoinNetwork <- liftIO (configLookupOrFail cfg "bitcoin.network")
    liftIO $ setBitcoinNetwork bitcoinNetwork

    cfgSettleConfig@(ServerSettleConfig _ _ settleFee _) <- liftIO $ getServerSettleConfig cfg

    (OpenConfig minConf basePrice addSettleFee) <- OpenConfig <$>
            liftIO (configLookupOrFail cfg "open.fundingTxMinConf") <*>
            liftIO (configLookupOrFail cfg "open.basePrice") <*>
            liftIO (configLookupOrFail cfg "open.priceAddSettlementFee")

    signingServiceConn <- liftIO $ getSigningServiceConn cfg
    let signSettleFunc = trySigningRequest . settleChannel signingServiceConn

    bitcoindRPCConf <- liftIO $ getBitcoindConf cfg
    let pushTxFunc = bitcoindNetworkSumbitTx bitcoindRPCConf

    let confPubKey = HC.derivePubKey $ confSettlePrivKey cfgSettleConfig
    let confOpenPrice = if addSettleFee then basePrice + settleFee else basePrice

    liftIO . putStrLn $ "Server PubKey: " ++ cs (pathParamEncode confPubKey)

    let basePathVersion = "/v1"
    addRoutes $ mainRoutes basePathVersion

    return $ App chanOpenMap cfgSettleConfig
                 confPubKey confOpenPrice minConf
                 basePathVersion settleChanFunc pushTxFunc

installHandlerKillThreadOnSig :: Sig.Signal -> ThreadId -> IO Sig.Handler
installHandlerKillThreadOnSig sig tid =
    Sig.installHandler
          sig
          (Sig.CatchInfo $ \ci -> do
              putStrLn ("Caught signal: " ++
                  show (Sig.siginfoSignal ci) ++
                  ". Killing main thread...")
              throwTo tid E.UserInterrupt)
          Nothing --(Just Sig.fullSignalSet)
