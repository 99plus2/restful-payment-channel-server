{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ChanStore.Main where

import           Prelude hiding (userError)

import           ChanStore.Lib.Types
import           ChanStore.Init (init_chanMap, destroy_chanMap)
import           ChanStore.Lib.ChanMap
import           ChanStore.Lib.Settlement (beginSettlingExpiringChannels, beginSettlingChannel,
                                                       finishSettlingChannel)
import           PayChanServer.Main (wrapArg)
import           PayChanServer.Config.Util (Config, loadConfig, configLookupOrFail,
                                            setBitcoinNetwork, getServerDBConf)
import           Common.Util (decodeFromBody, writeBinary,
                              internalError, userError, getPathArg, getQueryArg, getOptionalQueryArg,
                              errorWithDescription)
import           PayChanServer.Init (installHandlerKillThreadOnSig)
import           Common.URLParam (pathParamEncode)
import           Control.Concurrent (myThreadId)
import qualified System.Posix.Signals as Sig

import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, PaymentChannel(..), Payment)

import           Snap -- (serveSnaplet)
import           Control.Applicative ((<|>))

import           Data.String.Conversions (cs)
import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Control.Monad.Catch (bracket, finally, try)
import qualified Control.Exception as E


main :: IO ()
main = wrapArg $ \cfg _ -> do
    configLookupOrFail cfg "bitcoin.network" >>= setBitcoinNetwork
    port <- configLookupOrFail cfg "network.port"
    let conf = setPort (fromIntegral (port :: Word)) defaultConfig
    mainThread <- myThreadId
    _ <- installHandlerKillThreadOnSig Sig.sigTERM mainThread

    bracket
        (getServerDBConf cfg >>= init_chanMap)  -- 1. first do this
        destroy_chanMap                         -- 3. at the end always do this
        (\map -> httpServe conf $ site map)     -- 2. in the meantime do this


site :: ChannelMap -> Snap ()
site map =
    route [
            -- store/db
            ("/store/by_id/"
             ,      method POST   $ create map >>= writeBinary)

          , ("/store/by_id/:funding_outpoint"
             ,      method GET    ( get map    >>= writeBinary)
                <|> method PUT    ( update map >>= writeBinary) )

            -- expiring channels management/settlement interface
          , ("/settlement/begin/by_exp/:expiring_before"
             ,      method PUT    ( settleByExp map >>= writeBinary ))
          , ("/settlement/begin/by_id/:funding_outpoint"
             ,      method PUT    ( settleByKey map >>= writeBinary ))
          , ("/settlement/begin/by_value/:min_value"
             ,      method PUT    ( settleByVal map >>= writeBinary ))

          , ("/settlement/finish/by_id/:funding_outpoint"
             ,      method POST   ( settleFin map >>= writeBinary ))]

create :: ChannelMap -> Snap CreateResult
create map = do
    newChanState <- decodeFromBody 1024
    let key = getChannelID newChanState
    tryDBRequest $ addChanState map key newChanState


get :: ChannelMap -> Snap ChanState
get map = do
    outPoint <- getPathArg "funding_outpoint"
    maybeItem <- liftIO $ getChanState map outPoint
    case maybeItem of
        Nothing -> errorWithDescription 404 "No such channel"
        Just item -> return item

update :: ChannelMap -> Snap UpdateResult
update map = do
    outPoint <- getPathArg "funding_outpoint"
    payment <- decodeFromBody 128
    liftIO (updateChanState map outPoint payment) >>=
        (\exists -> case exists of
                ItemUpdated _ _  -> return WasUpdated
                NotUpdated       -> return WasNotUpdated
                NoSuchItem       -> errorWithDescription 404 "No such channel"
        )

settleByKey :: ChannelMap -> Snap ReceiverPaymentChannel
settleByKey m = do
    key <- getPathArg "funding_outpoint"
    liftIO $ beginSettlingChannel m key

settleByExp :: ChannelMap -> Snap [ReceiverPaymentChannel]
settleByExp m = do
    settlementTimeCutoff <- getPathArg "expiring_before"
    liftIO $ beginSettlingExpiringChannels m settlementTimeCutoff

settleByVal :: ChannelMap -> Snap [ReceiverPaymentChannel]
settleByVal m = do
    minValue <- getPathArg "min_value"
    liftIO $ beginSettlingExpiringChannels m minValue

settleFin :: ChannelMap -> Snap ()
settleFin m = do
    key <- getPathArg "funding_outpoint"
    settleTxId <- decodeFromBody 32
    res <- tryDBRequest $ finishSettlingChannel m (key,settleTxId)
    case res of
        (ItemUpdated _ _) -> liftIO . putStrLn $
            "Settled channel " ++ cs (pathParamEncode key) ++
            " with settlement txid: " ++ cs (pathParamEncode settleTxId)
        NotUpdated -> userError $ "Channel isn't in the process of being settled." ++
                                  " Did you begin settlement first?" ++
                                  " Also, are you sure you have the right key?"
        NoSuchItem -> errorWithDescription 404 "No such channel"







---- Util --
tryDBRequest :: MonadSnap m => IO a -> m a
tryDBRequest ioa = either errorOnException return =<< liftIO (try ioa)

errorOnException :: MonadSnap m => E.IOException -> m a
errorOnException = internalError . show


