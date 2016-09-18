{-# LANGUAGE  ScopedTypeVariables #-}

module  PayChanServer.DB where

import           Common.Util
import           PayChanServer.Types
import           PayChanServer.Util
import qualified PayChanServer.Config.Types as Conf

import qualified ChanStore.Interface as DBConn
import qualified ChanStore.Lib.Types as DB

import qualified Network.Haskoin.Transaction as HT
import           Control.Exception (try, throwIO)
import           Control.Concurrent (threadDelay)
import           Network.HTTP.Client (HttpException (FailedConnectionException, FailedConnectionException2))
import           Data.EitherR (fmapL)
import           System.IO (hFlush, stdout)
import           Text.Printf (printf)


-- |Keep trying to connect (only used during startup).
--  If we fail to get a result because host is offline:
--   log about it, then keep trying every 'delaySecs'
--   seconds until we get a result.
initWaitConnect :: String -> IO a -> IO a
initWaitConnect serviceName ioa = do
    let delaySecs = 0.1
    let isFailedConnectOrThrow e =
            case e of
                FailedConnectionException  host port     -> return (host,port)
                FailedConnectionException2 host port _ _ -> return (host,port)
                _ -> throwIO e
    -- Keep trying to connect
    let loopGet getter = do
            eitherError <- getter
            case eitherError of
                Left (e :: HttpException) -> do
                        isFailedConnectOrThrow e
                        threadDelay (fromIntegral $ round $ delaySecs * 1e6)
                        loopGet getter
                Right res -> return res
    let logNoConnection (host,port) = putStr $ printf
             "%s offline (%s:%d). Waiting for %s to come online... "
             serviceName host port serviceName
    let tryAsEither = try ioa
    tryAsEither >>= either  -- <- First try to connect
        -- If there's no connection: log; make it print everything to stdout; wait in loop
        (\e -> isFailedConnectOrThrow e >>= logNoConnection >> hFlush stdout >> loopGet tryAsEither)
        return

tryDBRequest :: IO a -> AppPC a
tryDBRequest ioa = liftIO (tryHTTPRequestOfType "Database" ioa) >>=
                       either internalError return

trySigningRequest :: IO a -> AppPC a
trySigningRequest ioa =
    liftIO (tryHTTPRequestOfType "Signing service" ioa) >>=
        either internalError return

tryHTTPRequestOfType :: String -> IO a -> IO (Either String a)
tryHTTPRequestOfType descr ioa =
    fmapL (\e -> descr ++ " error: " ++ show (e :: HttpException)) <$> try ioa


getChannelStateOr404 :: DBConn.Interface -> DB.Key -> AppPC DBConn.ChanState
getChannelStateOr404 chanMap key =
    tryDBRequest (DBConn.chanGet chanMap key) >>=
    \res -> case res of
        Nothing ->
            errorWithDescription 404 "No such channel"
        Just cs -> return cs

getChannelStateForPayment :: DBConn.Interface -> DB.Key -> AppPC ReceiverPaymentChannel
getChannelStateForPayment chanMap key =
    getChannelStateForSettlement chanMap key >>=
    -- When the channel has changed from ReadyForPayment to
    --  SettlementInProgress, the "/pay" resource is gone
    either (const $ errorWithDescription 404 "No such payment resource") return

-- |Return either open ChanState or settlement txid and most recent payment in case
--      the channel is closed
getChannelStateForSettlement :: DBConn.Interface -> DB.Key -> AppPC (Either (HT.TxHash,Payment) ReceiverPaymentChannel)
getChannelStateForSettlement chanMap key =
    getChannelStateOr404 chanMap key >>=
    \chanState -> case chanState of
        (DBConn.ReadyForPayment rpc) ->
            return $ Right rpc
        (DBConn.SettlementInProgress _) ->
            errorWithDescription 410 "Channel is being closed"
        (DBConn.ChannelSettled txid paym _) ->
            return $ Left (txid,paym)

