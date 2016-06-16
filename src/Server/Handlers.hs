{-# LANGUAGE OverloadedStrings #-}

module Server.Handlers where

import           Prelude hiding (userError)

import           Server.Config (pubKeyServer, fundsDestAddr, openPrice, minConf, settlementPeriodHours)

import           Common.Common
import           Common.Types

import           Server.Util (writeJSON, ChanOpenConfig(..),ChanPayConfig(..),
                              ChanSettleConfig(..),userError,internalError,
                              errorWithDescription, fundingAddrFromParams,
                              getQueryArg,getOptionalQueryArg,
                              txInfoFromAddr, guardIsConfirmed)
import           BlockchainAPI.Impl.BlockrIo (txIDFromAddr, fundingOutInfoFromTxId)
import           BlockchainAPI.Impl.ChainSo (chainSoAddressInfo, toEither)
import           BlockchainAPI.Types (txConfs, toFundingTxInfo,
                                TxInfo(..), OutInfo(..))
import           Bitcoind (bitcoindNetworkSumbitTx)
import           Server.ChanStore (ChannelMap, ChanState(..))
import           DiskStore (addItem, getItem, updateStoredItem)

import           Control.Monad.IO.Class (liftIO)
import           Control.Monad (mzero, forM, unless, when)
import           Control.Applicative
import           Control.Concurrent (forkIO)
import           Control.Monad.State (gets)
import           Snap.Core
-- import           Snap.Util.FileServe
import           Snap.Http.Server
-- import           Snap.Extras.JSON (reqBoundedJSON, writeJSON)

import           Data.Bitcoin.PaymentChannel
import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, PaymentChannel(..), ChannelParameters(..), PayChanError(..)
                                                    ,getChannelState, BitcoinAmount, valueToMe,
                                                    channelValueLeft)
import           Data.Bitcoin.PaymentChannel.Util (getFundingAddress, setSenderChangeAddress,
                                                    BitcoinLockTime(..), fromDate)

import qualified Network.Haskoin.Constants as HCC
import Network.Wreq (get, post, asJSON, responseBody)
import Control.Lens ((^.))

import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Transaction as HT

import           Data.Aeson
    (Result(..), Value(Number, Object, String), FromJSON, ToJSON, parseJSON, toJSON,
    fromJSON, withScientific, eitherDecode, eitherDecodeStrict, decode, encode, (.=), (.:), object)

import Data.Maybe (isJust, isNothing, fromJust)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C
import Data.ByteString.Lazy (toStrict)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Int (Int64)
import Data.Word (Word8)
import Data.Text as T
import Text.Printf (printf)
import Data.EitherR (fmapL)
import Data.String.Conversions (cs)
import Test.GenData (deriveMockFundingInfo, convertMockFundingInfo)
import Data.EitherR (fmapL)


applyCORS' :: MonadSnap m => m ()
applyCORS' = do
    modifyResponse $ setHeader "Access-Control-Allow-Origin"    "*"
    modifyResponse $ setHeader "Access-Control-Allow-Methods"   "GET,POST,PUT,DELETE"
    modifyResponse $ setHeader "Access-Control-Allow-Headers"   "Origin,Accept,Content-Type"
    modifyResponse $ setHeader "Access-Control-Expose-Headers"  "Location"

--- /fundingInfo ---
type URL = String

writeFundingInfoResp :: MonadSnap m => (FundingInfo,URL) -> m ()
writeFundingInfoResp (fi, url) = do
    applyCORS'
    modifyResponse $ setHeader "Location" (cs url)
    writeJSON . toJSON $ fi
    writeBS "\n"

mkFundingInfo :: HC.PubKey -> HC.PubKey -> BitcoinLockTime -> (FundingInfo,URL)
mkFundingInfo recvPK sendPK lockTime  =
    (FundingInfo
        recvPK
        (getFundingAddress' sendPK recvPK lockTime)
        openPrice
        minConf
        settlementPeriodHours,
    cs $ channelOpenURL hOSTNAME sendPK lockTime)

logFundingInfo :: MonadSnap m => m ()
logFundingInfo  = do
    pk <- getQueryArg "client_pubkey"
    exp <- getQueryArg "exp_time"
    liftIO . putStrLn $ printf
        "Got fundingInfo request: pubkey=%s exp=%s"
            (show (pk :: HC.PubKey))
            (show (exp :: BitcoinLockTime))

--- /fundingInfo ---


----Settlement----
chanSettle :: MonadSnap m => ChanSettleConfig -> m ()
chanSettle (SettleConfig privKey recvAddr txFee chanMap hash vout payment) = do
    liftIO . putStrLn $ printf
        "Processing settlement request for channel %s/%d: "
            (cs $ HT.txHashToHex hash :: String) vout ++ show payment

    chanState <- getChannelStateOr404 chanMap hash

    let eitherTx = getSettlementBitcoinTx
            chanState (`HC.signMsg` privKey) recvAddr txFee
    tx <- case eitherTx of
        Left e -> internalError $ show e
        Right tx -> return tx

    eitherTxId <- liftIO $ bitcoindNetworkSumbitTx tx
    txid <- case eitherTxId of
        Left e -> internalError e
        Right txid -> return txid
    modifyResponse $ setResponseStatus 202 (C.pack "Channel closed")
---


----Payment----

chanPay :: MonadSnap m => ChanPayConfig -> m (BitcoinAmount, ReceiverPaymentChannel)
chanPay (PayConfig chanMap hash vout maybeNewAddr payment) = do
    existingChanState <- maybeUpdateChangeAddress maybeNewAddr =<<
            getChannelStateOr404 chanMap hash
    (valRecvd,newChanState) <- either
            (userError . show)
            return
            (recvPayment existingChanState payment)

    liftIO $ updateStoredItem chanMap hash (ReadyForPayment newChanState)

    modifyResponse $ setResponseStatus 200 (C.pack "Payment accepted")
    return (valRecvd,newChanState)

----Payment----


--- POST /channels/ ----
channelOpenHandler :: MonadSnap m =>
    HC.PubKey --TODO: move to config
    -> ChanOpenConfig
    -> m (BitcoinAmount, ReceiverPaymentChannel)
channelOpenHandler pubKeyServ
    (OpenConfig chanMap txInfo@(TxInfo txId _ (OutInfo _ chanVal idx)) sendPK sendChgAddr lockTime payment) = do
    liftIO . putStrLn $ "Processing channel open request... " ++
        show (sendPK, lockTime, txInfo, payment)

    confirmChannelDoesntExistOrAbort chanMap txId idx

    --New channel creation--
    (valRecvd,recvChanState) <- either (userError . show) return $
        channelFromInitialPayment
            (CChannelParameters sendPK pubKeyServ lockTime)
            (toFundingTxInfo txInfo) sendChgAddr payment
    liftIO $ addItem chanMap txId (ReadyForPayment recvChanState)
    modifyResponse $ setResponseStatus 201 (C.pack "Channel ready")
    --New channel creation--

    unless (channelIsExhausted recvChanState) $
        modifyResponse $ setHeader "Location" (cs $ activeChannelURL hOSTNAME txId idx)

    return (valRecvd,recvChanState)


exitIfChannelStillOpen :: MonadSnap m => ChannelStatus -> m ()
exitIfChannelStillOpen ChannelOpen = finishWith =<< getResponse
exitIfChannelStillOpen ChannelClosed = return ()


writePaymentResult :: MonadSnap m => (BitcoinAmount, ReceiverPaymentChannel) -> m ChannelStatus
writePaymentResult (valRecvd,recvChanState) =
    let chanStatus =
            if channelIsExhausted recvChanState then
                ChannelClosed else
                ChannelOpen
    in
        do
            writeJSON . toJSON $ PaymentResult {
                paymentResultchannel_status = chanStatus,
                paymentResultchannel_value_left = channelValueLeft recvChanState,
                paymentResultvalue_received = valRecvd
            }
            return chanStatus

testOr_blockchainGetFundingInfo :: MonadSnap m => m TxInfo
testOr_blockchainGetFundingInfo = do
    maybeArg <- getOptionalQueryArg "test"
    case maybeArg :: Maybe Bool of
        Just True -> test_GetDerivedFundingInfo
        _         ->
            fundingAddressFromParams >>=
            blockchainAddressCheckEverything

fundingAddressFromParams :: MonadSnap m => m HC.Address
fundingAddressFromParams =
    fundingAddrFromParams <$>
        getQueryArg "client_pubkey" <*>
        getQueryArg "exp_time"

blockchainAddressCheckEverything :: MonadSnap m => HC.Address -> m TxInfo
blockchainAddressCheckEverything  addr =
    (liftIO . chainSoAddressInfo . cs . HC.addrToBase58) addr >>=
        either internalError return . toEither >>=
        maybe (userError $ "No transactions paying to " ++ cs (HC.addrToBase58 addr)) return >>=
        guardIsConfirmed (fromIntegral minConf)

--     fundingAddrFromParams <$>
--         getQueryArg "client_pubkey" <*>
--         getQueryArg "exp_time"
--     >>= txInfoFromAddr >>= guardIsConfirmed (fromIntegral minConf)

-- | Deterministically derives a mock TxInfo from ChannelParameters,
-- which matches that of the test data generated by Test.GenData.
test_GetDerivedFundingInfo :: MonadSnap m => m TxInfo
test_GetDerivedFundingInfo = do
    cp <- flip CChannelParameters pubKeyServer <$>
            getQueryArg "client_pubkey" <*>
            getQueryArg "exp_time"
    return $ convertMockFundingInfo . deriveMockFundingInfo $ cp


--- POST /channels/ ---

confirmChannelDoesntExistOrAbort :: MonadSnap m => ChannelMap -> HT.TxHash -> Integer -> m ()
confirmChannelDoesntExistOrAbort chanMap hash idx = do
    maybeItem <- liftIO (getItem chanMap hash)
    unless (isNothing maybeItem) $ do
        modifyResponse $ setHeader "Location" (cs $ activeChannelURL hOSTNAME hash idx)
        errorWithDescription 409 "Channel already exists"


getChannelStateOr404 :: MonadSnap m => ChannelMap -> HT.TxHash -> m ReceiverPaymentChannel
getChannelStateOr404 chanMap hash =
    liftIO (getItem chanMap hash) >>=
    maybe
        (errorWithDescription 404 "No such channel")
        (return . csState)

maybeUpdateChangeAddress :: MonadSnap m =>
    Maybe HC.Address
    -> ReceiverPaymentChannel
    -> m ReceiverPaymentChannel
maybeUpdateChangeAddress maybeAddr state =
    maybe (return state) updateAddressAndLog maybeAddr
        where updateAddressAndLog addr = do
                liftIO . putStrLn $ "Updating client change address to " ++ toString addr
                return $ setSenderChangeAddress state addr
