{-# LANGUAGE OverloadedStrings #-}

module Server.App where


import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, BitcoinAmount)

import           Server.Util (getPathArg, getQueryArg, getOptionalQueryArg, getAppRootURL,
                              channelIDFromPathArgs, writePaymentResult, proceedIfExhausted,
                              tEST_blockchainGetFundingInfo,
                              applyCORS')
import           Server.Config
import           Server.Config.Types
import           Server.Types ( ChanOpenConfig(..),ChanPayConfig(..),
                                StdConfig(..), ChanSettleConfig(..))
import           Server.Handlers

import           Control.Applicative ((<|>))
import           Control.Lens (use)

import qualified Data.ByteString as BS
import           Snap
import           Data.Monoid ((<>))



mainRoutes :: BS.ByteString -> [(BS.ByteString, Handler App App ())]
mainRoutes basePath' =
        [
         (basePath' <> "/fundingInfo" -- ?client_pubkey&exp_time
           ,   method GET    fundingInfoHandler)

       , (basePath' <> "/channels/new" -- ?client_pubkey&exp_time&change_address
           ,   method POST (newChannelHandler >>= writePaymentResult >>=
                               proceedIfExhausted >>= settlementHandler)
               <|> method OPTIONS applyCORS') --CORS

       , (basePath' <> "/channels/:funding_txid/:funding_vout"
           ,   method PUT    (paymentHandler >>= writePaymentResult >>=
                               proceedIfExhausted >>= settlementHandler)
           <|> method DELETE (settlementHandler 0)
           <|> method OPTIONS applyCORS') --CORS
        ] :: [(BS.ByteString, Handler App App ())]



fundingInfoHandler :: Handler App App ()
fundingInfoHandler =
    mkFundingInfo <$>
    use openPrice <*>
    use fundingMinConf <*>
    fmap confSettlePeriod (use settleConfig) <*>
    use pubKey <*>
    getQueryArg "client_pubkey" <*>
    getQueryArg "exp_time" <*>
    (use basePath >>= getAppRootURL)
        >>= writeFundingInfoResp

newChannelHandler :: Handler App App (BitcoinAmount, ReceiverPaymentChannel)
newChannelHandler = applyCORS' >>
    ChanOpenConfig <$>
        use openPrice <*>
        use pubKey <*>
        use channelStateMap <*>
        tEST_blockchainGetFundingInfo <*>
        use basePath <*>
        getQueryArg "client_pubkey" <*>
        getQueryArg "change_address" <*>
        getQueryArg "exp_time" <*>
        getQueryArg "payment"
    >>= channelOpenHandler

paymentHandler :: Handler App App (BitcoinAmount, ReceiverPaymentChannel)
paymentHandler = applyCORS' >>
    PayConfig <$>
        (StdConfig <$>
            use channelStateMap <*>
            channelIDFromPathArgs <*>
            getQueryArg "payment") <*>
        getOptionalQueryArg "change_address"
    >>= chanPay

settlementHandler :: BitcoinAmount -> Handler App App ()
settlementHandler valueReceived = do
    applyCORS'

    settleChanFunc <- use settleChanFunc
    stdConf <- StdConfig <$>
            use channelStateMap <*>
            channelIDFromPathArgs <*>
            getQueryArg "payment"
    chanSettle stdConf settleChanFunc valueReceived

