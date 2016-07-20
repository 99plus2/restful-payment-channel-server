{-# LANGUAGE OverloadedStrings #-}

module ChanStoreServer where

import           Prelude hiding (userError)

import           Server.ChanStore
import           Server.ChanStore.Types
import           Server.ChanStore.ChanStore
import           Server.Main (wrapArg)
import           Server.Config (Config, loadConfig, configLookupOrFail, getSettleConfig,
                                getBitcoindConf, setBitcoinNetwork, getLevelDBFilePath)
import           Server.Util (reqBoundedData, writeBinary,
                              internalError, userError, getPathArg, getQueryArg, getOptionalQueryArg,
                              errorWithDescription)

import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, PaymentChannel(..), Payment)

import qualified Network.Haskoin.Transaction as HT

import           Snap -- (serveSnaplet)
import           Snap.Http.Server -- (defaultConfig, httpServe)
import           Control.Applicative ((<|>))

import           Control.Monad (unless)
import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Control.Monad.Catch (bracket, finally, try)
import           Control.Concurrent.STM (STM, atomically)
import qualified Control.Exception as E


main :: IO ()
main = wrapArg $ \cfg _ -> do
    configLookupOrFail cfg "bitcoin.network" >>= setBitcoinNetwork
    port <- configLookupOrFail cfg "network.port"
    let conf = setPort (fromIntegral (port :: Word)) defaultConfig
    bracket
        (init_chanMap =<< configLookupOrFail cfg "storage.stateDir")
        (const $ return ())
        (\map -> httpServe conf $ site map)


site :: ChannelMap -> Snap ()
site map =
    route [ ("/channels/"
             ,      method POST   $ create map)

          , ("/channels/by_id/:funding_outpoint"
             ,      method GET    ( get map   )
                <|> method PUT    ( update map)
                <|> method DELETE ( settle map) )

            -- management/settlement interface
          , ("/channels/expiring_before/:exp_time"
             ,      method GET    ( getAll map ))]

create :: ChannelMap -> Snap ()
create map = do
    eitherState <- reqBoundedData 256
    case eitherState of
        Right newChanState ->
            let key = getChannelID newChanState in
                liftIO (try $ addChanState map key newChanState) >>=
                    either errorOnException (const $ return ())
        Left e -> userError e

get :: ChannelMap -> Snap ()
get map = do
    outPoint <- getPathArg "funding_outpoint"
    maybeItem <- liftIO $ getChanState map outPoint
    case maybeItem of
        Nothing -> errorWithDescription 404 "No such channel"
        Just item -> writeBinary item

update :: ChannelMap -> Snap ()
update map = do
    outPoint <- getPathArg "funding_outpoint"
    eitherPayment <- reqBoundedData 80
    case eitherPayment of
        Right payment -> updateWithPayment map outPoint payment
        Left e -> userError e

settle :: ChannelMap -> Snap ()
settle map = do
    outPoint    <- getPathArg  "funding_outpoint"
    settleTxId  <- getQueryArg "settlement_txid"
    itemExisted  <- liftIO $ deleteChanState map outPoint settleTxId
    unless itemExisted $
        errorWithDescription 404 "No such channel"

getAll :: ChannelMap -> Snap ()
getAll m = do
    expirationDate <- getPathArg "exp_time"
--     maybeMarkAsSettling <- getOptionalQueryArg "begin_settlement"
    let filterFunc = \chan ->
            if isOpen chan then
                    expiresBefore expirationDate (csState chan)
                else
                    False
    liftIO (getFilteredChanStates m filterFunc) >>= writeBinary

updateWithPayment :: MonadSnap m => ChannelMap -> HT.OutPoint -> Payment -> m ()
updateWithPayment  map chanId payment = do
    success <- liftIO $ updateChanState map chanId payment
    unless success $
        userError "Not an open channel"

errorOnException :: MonadSnap m => E.IOException -> m ()
errorOnException = internalError . show
