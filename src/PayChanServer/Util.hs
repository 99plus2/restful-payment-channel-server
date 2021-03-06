{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds, FlexibleContexts, LambdaCase, TypeOperators #-}

module PayChanServer.Util
(
   module PayChanServer.Util
 , module Common.Util
 , module Data.Bitcoin.PaymentChannel.Util
 , module Data.Bitcoin.PaymentChannel
)
where

import           Prelude hiding (userError)
import           Common.Types
import           Common.Util

import qualified PayChanServer.Config.Types as Conf
import           PayChanServer.Types

import           BlockchainAPI.Types (toFundingTxInfo, TxInfo(..))
import           ChanStore.Lib.Settlement (expiresEarlierThan)

import           Data.Bitcoin.PaymentChannel.Util
import           Data.Bitcoin.PaymentChannel

import           Text.Printf (printf)

import qualified Network.Haskoin.Constants as HCC
import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Transaction as HT
import           Crypto.Secp256k1 (secKey)
import           Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)

import           Test.GenData (deriveMockFundingInfo)
import           Data.Maybe (fromJust)



dummyKey :: SendPubKey
dummyKey = fromJust $
    MkSendPubKey . HC.derivePubKey . HC.makePrvKey <$> secKey dummy32ByteBS

dummyTxId :: HT.TxHash
dummyTxId = HT.TxHash . HC.hash256 $ dummy32ByteBS

dummy32ByteBS :: ByteString
dummy32ByteBS = "12345678901234567890123456789012"

getServerPubKey :: AppPC RecvPubKey
getServerPubKey = view Conf.pubKey

-- | Return 'TxInfo' if sufficiently confirmed
guardIsConfirmed :: Conf.BtcConf -> TxInfo -> AppPC TxInfo
guardIsConfirmed minConf' txInfo@(TxInfo txConfs _) =
    if txConfs >= minConf then
        return txInfo
    else
        userError' $ printf "Insufficient confirmation count for funding transaction: %d (need %d)" txConfs minConf
    where minConf = fromIntegral (Conf.getVal minConf')

---- Bitcoin ----
checkExpirationTime :: BitcoinLockTime -> AppPC BitcoinLockTime
checkExpirationTime lockTime = do
    minDurationHours <- Conf.minDuration <$> view Conf.chanConf
    case lockTime of
        LockTimeBlockHeight _ ->
            userError' "Block index/number as channel expiration date is unsupported"
        LockTimeDate _ -> do
            now <- liftIO getCurrentTime
            let offsetSecs = fromIntegral $ minDurationHours * 3600
            if expiresEarlierThan (offsetSecs `addUTCTime` now) lockTime then
                    userError' $ "Insufficient time until expiration date." ++
                        " Minimum channel duration: " ++ show minDurationHours ++ " hours"
                else
                    return lockTime

-- httpLocationSetActiveChannel :: String -> AppPC ()


--- Funding ---
blockchainGetConfirmedTxInfo :: ChannelParameters -> AppPC FundingTxInfo
blockchainGetConfirmedTxInfo cp = do
    debug        <- view Conf.areWeDebugging
    minConf      <- Conf.btcMinConf <$> view Conf.chanConf
    if (HCC.getNetworkName HCC.getNetwork == "testnet") && debug then
            -- | Deterministically derives a mock TxInfo from ChannelParameters,
            -- which matches that of the test data generated by Test.GenData.
            return $ deriveMockFundingInfo cp
        else
            toFundingTxInfo <$> blockchainAddressCheckEverything minConf (getFundingAddress cp)

blockchainAddressCheckEverything :: Conf.BtcConf -> HC.Address -> AppPC TxInfo
blockchainAddressCheckEverything minConf addr = do
    listUnspentFunc <- view Conf.listUnspent
    liftIO (listUnspentFunc addr) >>=
        either internalError return >>=
        \txiList -> case txiList of
            (txi1:_)    -> guardIsConfirmed minConf txi1    -- Pick first TxInfo
            []          -> userError' $
                    "No transactions paying to " ++ cs (HC.addrToBase58 addr) ++
                    ". Maybe wait a little?"



--- Funding ---



