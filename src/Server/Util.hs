{-# LANGUAGE OverloadedStrings #-}

module Server.Util where

import           Prelude hiding (userError)

import           Common.Common
import           Common.Types

import           BlockchainAPI.Impl.BlockrIo (txIDFromAddr, fundingOutInfoFromTxId)
import           BlockchainAPI.Types (txConfs, toFundingTxInfo,
                                TxInfo(..), OutInfo(..))

import           Snap
import           Snap.Iteratee (Enumerator, enumBuilder)

import           Data.Bitcoin.PaymentChannel.Types (PaymentChannel(..), ReceiverPaymentChannel,
                                                    ChannelParameters(..), PayChanError(..), FundingTxInfo
                                                    ,getChannelState, BitcoinAmount, Payment)
import           Data.Bitcoin.PaymentChannel.Util (setSenderChangeAddress)

import qualified Network.Haskoin.Constants as HCC
import           Control.Monad.IO.Class
import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Transaction as HT
import           Data.Aeson (FromJSON, ToJSON, parseJSON, toJSON,
                            decode, encode)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as C
import Blaze.ByteString.Builder.ByteString (fromLazyByteString)
import Data.Int (Int64)
import Text.Printf (printf)
import Data.String.Conversions (cs)
import Data.Aeson.Encode.Pretty (encodePretty)
import           Data.Monoid ((<>))
import qualified Data.Binary as Bin (Binary, encode, decodeOrFail)

import           Control.Lens (use)


import           Server.Config.Types (App, pubKey, fundingMinConf)


import           BlockchainAPI.Impl.ChainSo (chainSoAddressInfo, toEither)

import Test.GenData (deriveMockFundingInfo, convertMockFundingInfo)



getAppRootURL :: MonadSnap m => BS.ByteString -> m String
getAppRootURL basePath = do
    serverName <- getsRequest rqServerName
    serverPort <- getsRequest rqServerPort
--     let finalHostname = if serverPort == 80 then serverName else
--             serverName <> ":" <> cs (show serverPort)
    isSecure <- getsRequest rqIsSecure
    return $ channelRootURL isSecure serverName basePath

httpLocationSetActiveChannel :: MonadSnap m => BS.ByteString -> HT.OutPoint -> m ()
httpLocationSetActiveChannel basePath chanId = do
    chanRootURL <- getAppRootURL basePath
    modifyResponse $ setHeader "Location" (cs $ chanRootURL ++ activeChannelPath chanId)


fundingAddressFromParams :: MonadSnap m => HC.PubKey -> m HC.Address
fundingAddressFromParams pubKey =
    flip getFundingAddress' pubKey <$>
        getQueryArg "client_pubkey" <*>
        getQueryArg "exp_time"


---- Blockchain API ----
txInfoFromAddr :: MonadSnap m => HC.Address -> m TxInfo
txInfoFromAddr fundAddr = do
    maybeTxId <- liftIO $ txIDFromAddr (toString fundAddr)
    txId <- case maybeTxId of
        Nothing ->  userError $
            "Can't find any transactions paying to funding address " ++ cs (encode fundAddr)
        Just txid -> return txid
    eitherFundOut <- liftIO $ fundingOutInfoFromTxId (toString fundAddr) txId
    -- The API has just provided us with a txid above, if it can't find said txid
    -- something is wrong with the API, so we return an internal error in this case.
    either (const $ internalError ("Can't find funding transaction: " ++ show txId)) return eitherFundOut

-- | Return (hash,idx) if sufficiently confirmed
guardIsConfirmed :: MonadSnap m => Integer -> TxInfo -> m TxInfo
guardIsConfirmed minConf txInfo@(TxInfo _ txConfs (OutInfo _ _ _)) =
    if txConfs >= minConf then
        return txInfo
    else
        userError $ printf "Insufficient confirmation count for funding transaction: %d (need %d)" txConfs minConf
---- Blockchain API ----

channelIDFromPathArgs :: MonadSnap m => m HT.OutPoint
channelIDFromPathArgs =
    HT.OutPoint <$>
       getPathArg "funding_txid" <*>
       getPathArg "funding_vout"

-- TODO: move to Common
--- Get parameters with built-in error handling
failOnError :: MonadSnap m => String -> Either String a -> m a
failOnError msg = either (userError . (msg ++)) return

failOnNothingWith :: MonadSnap m => String -> Maybe a -> m a
failOnNothingWith s = maybe (userError s) return

handleQueryDecodeFail :: MonadSnap m => BS.ByteString -> Either String a -> m a
handleQueryDecodeFail bs = failOnError ("failed to decode query arg \"" ++ cs bs ++ "\": ")

getPathArg :: (MonadSnap m, URLParamDecode a) => BS.ByteString -> m a
getPathArg bs = failOnError (cs bs ++ ": failed to decode path arg: ") . pathParamDecode =<<
    failOnNothingWith ("Missing " ++ C.unpack bs ++ " path parameter") =<<
        getParam bs

getQueryArg :: (MonadSnap m, URLParamDecode a) => BS.ByteString -> m a
getQueryArg bs = handleQueryDecodeFail bs . pathParamDecode =<<
    failOnNothingWith ("Missing " ++ C.unpack bs ++ " query parameter") =<<
        getQueryParam bs

getOptionalQueryArg :: (MonadSnap m, URLParamDecode a) => BS.ByteString -> m (Maybe a)
getOptionalQueryArg bs = do
    maybeParam <- getQueryParam bs
    case maybeParam of
        Nothing -> return Nothing
        Just pBS -> fmap Just . handleQueryDecodeFail bs . pathParamDecode $ pBS
--- Get parameters with built-in error handling

---ERROR---
userError :: MonadSnap m => String -> m a
userError = errorWithDescription 400

internalError :: MonadSnap m => String -> m a
internalError = errorWithDescription 500

errorWithDescription :: MonadSnap m => Int -> String -> m a
errorWithDescription code errStr = do
    modifyResponse $ setResponseStatus code (C.pack errStr)
    finishWith =<< getResponse
---ERROR---


encodeJSON :: ToJSON a => a -> BL.ByteString
encodeJSON json = encodePretty json

overwriteResponseBody :: MonadSnap m => BL.ByteString -> m ()
overwriteResponseBody bs =
    getResponse >>=
    putResponse . setResponseBody (enumBuilder $ fromLazyByteString bs)

writeJSON :: (MonadSnap m, ToJSON a) => a -> m ()
writeJSON json = do
    modifyResponse $ setContentType "application/json"
    overwriteResponseBody $ encodeJSON json
    writeBS "\n"

writeResponseBody :: (MonadSnap m, Bin.Binary a) => a -> m ()
writeResponseBody obj = do
    modifyResponse $ setContentType "application/octet-stream"
    overwriteResponseBody $ Bin.encode obj

reqBoundedData :: (MonadSnap m, Bin.Binary a) => Int64 -> m (Either String a)
reqBoundedData n = fmap decodeEither (readRequestBody n)

decodeFromBody :: (MonadSnap m, Bin.Binary a) => Int64 -> m a
decodeFromBody n = either
    (userError . ("Failed to decode object from body: " ++))
    return
        =<< reqBoundedData n

decodeEither :: Bin.Binary a => BL.ByteString -> Either String a
decodeEither bs = case Bin.decodeOrFail bs of
       Left (_,_,e)    -> Left e
       Right (_,_,val) -> Right val


--- Util ---
proceedIfExhausted :: MonadSnap m => (ChannelStatus,BitcoinAmount) -> m BitcoinAmount
proceedIfExhausted (ChannelOpen,_)          = finishWith =<< getResponse
proceedIfExhausted (ChannelClosed,valRecvd) = return valRecvd

applyCORS' :: MonadSnap m => m ()
applyCORS' = do
    modifyResponse $ setHeader "Access-Control-Allow-Origin"    "*"
    modifyResponse $ setHeader "Access-Control-Allow-Methods"   "GET,POST,PUT,DELETE"
    modifyResponse $ setHeader "Access-Control-Allow-Headers"   "Origin,Accept,Content-Type"
    modifyResponse $ setHeader "Access-Control-Expose-Headers"  "Location"

writePaymentResult :: MonadSnap m =>
    (BitcoinAmount, ReceiverPaymentChannel)
    -> m (ChannelStatus,BitcoinAmount)
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
                paymentResultvalue_received = valRecvd,
                paymentResultsettlement_txid = Nothing
            }
            return (chanStatus,valRecvd)

maybeUpdateChangeAddress :: MonadSnap m =>
    Maybe HC.Address
    -> ReceiverPaymentChannel
    -> m ReceiverPaymentChannel
maybeUpdateChangeAddress maybeAddr state =
    maybe (return state) updateAddressAndLog maybeAddr
        where updateAddressAndLog addr = do
                liftIO . putStrLn $ "Updating client change address to " ++ toString addr
                return $ setSenderChangeAddress state addr
--- Util ---


--- Funding ---
tEST_blockchainGetFundingInfo :: Handler App App FundingTxInfo
tEST_blockchainGetFundingInfo = fmap toFundingTxInfo $ do
    pubKeyServer <- use pubKey
    minConf <- use fundingMinConf
    testArgTrue <- fmap (== Just True) $ getOptionalQueryArg "test"

    if (HCC.getNetworkName HCC.getNetwork == "testnet") && testArgTrue then
            test_GetDerivedFundingInfo pubKeyServer
        else
            fundingAddressFromParams pubKeyServer >>=
                blockchainAddressCheckEverything minConf

blockchainAddressCheckEverything :: MonadSnap m => Int -> HC.Address -> m TxInfo
blockchainAddressCheckEverything minConf addr =
    (liftIO . chainSoAddressInfo . cs . HC.addrToBase58) addr >>=
        either internalError return . toEither >>=
        maybe
            (userError $ "No transactions paying to " ++ cs (HC.addrToBase58 addr) ++
                ". Maybe wait a little?")
            return >>=
        guardIsConfirmed (fromIntegral minConf)

-- | Deterministically derives a mock TxInfo from ChannelParameters,
-- which matches that of the test data generated by Test.GenData.
test_GetDerivedFundingInfo :: MonadSnap m => HC.PubKey -> m TxInfo
test_GetDerivedFundingInfo pubKeyServer = do
    cp <- flip CChannelParameters pubKeyServer <$>
            getQueryArg "client_pubkey" <*>
            getQueryArg "exp_time"
    return $ convertMockFundingInfo . deriveMockFundingInfo $ cp
--- Funding ---




-- reqBoundedJSON :: (MonadSnap m, FromJSON a) => Int64 -> m (Either String a)
-- reqBoundedJSON n = fmap eitherDecode (readRequestBody n)
--
-- getHeaderOrFail :: MonadSnap m => CI BS.ByteString -> m BS.ByteString
-- getHeaderOrFail h = do
--     r <- getRequest
--     maybe (userError $ cs (original h) ++ " header not present") return (getHeader h r)
--
-- headerGetPayment :: MonadSnap m => m Payment
-- headerGetPayment = do
--     pBS <- getHeaderOrFail "Payment-Payload"
--     case fromJSON . String . cs $ pBS of
--         Error e -> userError $ "failed to decode payment payload: " ++ e
--         Success p -> return p
--
-- bodyJSONGetPayment :: MonadSnap m => m Payment
-- bodyJSONGetPayment =
--     reqBoundedJSON 1024 >>=
--     either (userError . ("Failed to parse Payment: " ++)) (return . paymentpayment_data)



-- logFundingInfo :: MonadSnap m => m ()
-- logFundingInfo  = do
--     pk <- getQueryArg "client_pubkey"
--     expTime <- getQueryArg "exp_time"
--     liftIO . putStrLn $ printf
--         "Got fundingInfo request: pubkey=%s exp=%s"
--             (show (pk :: HC.PubKey))
--             (show (expTime :: BitcoinLockTime))