{-# LANGUAGE  OverloadedStrings #-}

module Test.GenData where

import Common.Common    (channelOpenURL,mkOpenQueryParams,mkPaymentURL, pathParamDecode)
import           Data.Bitcoin.PaymentChannel (channelWithInitialPaymentOf, sendPayment)
import           Data.Bitcoin.PaymentChannel.Util (BitcoinLockTime(..), toWord32, parseBitcoinLocktime,
                                                   getFundingAddress)
import           Data.Bitcoin.PaymentChannel.Types
    (Payment, ChannelParameters(..), FundingTxInfo(..))
import qualified Network.Haskoin.Transaction as HT
import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Constants as HCC
import qualified Data.Binary as Bin
import qualified Data.ByteString as BS
import           Data.Aeson         (object, ToJSON, toJSON, (.=), encode,
                                     Value(Object), parseJSON, FromJSON, (.:))
import Control.Monad (mzero)
import Data.Maybe (isJust, fromJust)
import Data.Word (Word32)
import Data.String.Conversions (cs)
import qualified Data.Text as T
import System.Entropy (getEntropy)
import Crypto.Secp256k1 (secKey)
import Data.Time.Clock.POSIX (getPOSIXTime)
-- import Server.Config (pubKeyServer, fundsDestAddr, openPrice)
import BlockchainAPI.Types (TxInfo(..), OutInfo(..))

mockChangeAddress = "mmA2XECa7bVERzQKkyy1pNBQ3PC4HnxTC5"
nUM_PAYMENTS = 100 :: Int
cHAN_DURATION = 3600 * 24 * 7 :: Integer



genData :: T.Text -> Int -> String -> IO PaySessionData
genData endpoint numPayments pubKeyServerStr = do
    pubKeyServer <- either (const $ fail "failed to parse server pubkey") return
        (pathParamDecode $ cs pubKeyServerStr)
    -- Generate fresh private key
    privSeed <- getEntropy 32
    prvKey <- maybe (fail "couldn't derive secret key from seed") return $
            fmap HC.makePrvKey (secKey privSeed)
    expTime <- fmap round getPOSIXTime
    let sess = genChannelSession endpoint numPayments prvKey pubKeyServer
            (parseBitcoinLocktime $ fromIntegral $ expTime + cHAN_DURATION)

    return $ getSessionData sess



data ChannelSession = ChannelSession {
    csEndPoint    :: T.Text,
    csParams      :: ChannelParameters,
    csFundAddr    :: HC.Address,
    csInitPayment :: Payment,
    csPayments    :: [Payment]
}

-- | Generate payment of value 1 satoshi
iterateFunc (p,s) = sendPayment s 1

genChannelSession :: T.Text -> Int -> HC.PrvKey -> HC.PubKey -> BitcoinLockTime -> ChannelSession
genChannelSession endPoint numPayments privClient pubServer expTime =
    let
        cp = CChannelParameters (HC.derivePubKey privClient) pubServer expTime
        fundInfo = deriveMockFundingInfo cp
        (initPay,initState) = channelWithInitialPaymentOf cp fundInfo
                (`HC.signMsg` privClient) mockChangeAddress 100000
        payStateList = tail $ iterate iterateFunc (initPay,initState)
        payList = map fst payStateList
    in
        ChannelSession endPoint cp (getFundingAddress cp) initPay (take numPayments payList)
--------

data PaySessionData = PaySessionData {
    openURL     :: T.Text,
    payURLList  :: [T.Text],
    closeURL    :: T.Text
}

instance ToJSON PaySessionData where
    toJSON (PaySessionData openURL payURLs closeURL) =
        object [
            "open_url"      .= openURL,
            "payment_urls"  .= payURLs,
             "close_url"    .= closeURL
         ]

instance FromJSON PaySessionData where
    parseJSON (Object v) = PaySessionData <$>
                v .: "open_url" <*> v .: "payment_urls" <*> v .: "close_url"
    parseJSON _ = mzero


getSessionData :: ChannelSession -> PaySessionData
getSessionData (ChannelSession endPoint cp fundAddr initPay payList) =
    let
        (CFundingTxInfo txid vout val) = deriveMockFundingInfo cp
        chanId = HT.OutPoint txid (fromIntegral vout)
        openURL = channelOpenURL False (cs endPoint) "/v1" (cpSenderPubKey cp)
                (cpLockTime cp) ++ mkOpenQueryParams mockChangeAddress initPay
        payURLs = map (cs . mkPaymentURL False (cs endPoint) "/v1" chanId) payList
    in
        PaySessionData
            (cs openURL)
            payURLs
            (last payURLs)



convertMockFundingInfo :: FundingTxInfo -> TxInfo
convertMockFundingInfo (CFundingTxInfo txid vout val)  =
    TxInfo txid 27 (OutInfo "" (fromIntegral val) (fromIntegral vout))

deriveMockFundingInfo :: ChannelParameters -> FundingTxInfo
deriveMockFundingInfo (CChannelParameters sendPK recvPK expTime) =
    CFundingTxInfo
        (HT.TxHash $ HC.hash256 $ cs . Bin.encode $ sendPK)
        (toWord32 expTime `mod` 7)
        12345678900000

