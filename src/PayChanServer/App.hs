{-# LANGUAGE OverloadedStrings #-}

module  PayChanServer.App where


import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, BitcoinAmount)

import           PayChanServer.Util (getPathArg, getQueryArg, getOptionalQueryArg, getAppRootURL,
                              channelIDFromPathArgs, writePaymentResult, proceedIfExhausted,
                              blockchainGetFundingInfo,
                              applyCORS')
import           PayChanServer.Config
import           PayChanServer.Config.Types
import           PayChanServer.Types ( ChanOpenConfig(..),ChanPayConfig(..),
                                StdConfig(..), ServerSettleConfig(..))
import           PayChanServer.Handlers

import           Control.Applicative ((<|>))
import           Control.Lens (use)

import qualified Data.ByteString as BS
import           Snap
import           Data.Monoid ((<>))

type Debug = Bool

mainRoutes :: Debug -> BS.ByteString -> [(BS.ByteString, Handler App App ())]
mainRoutes debug basePath' =
    let
        -- Testing: Bypass Blockchain lookup/submit in case we're debugging
        handleChannelSettlement = settlementHandler debug
        handleChannelOpen       = newChannelHandler debug
    in
        [
         (basePath' <> "/fundingInfo" -- ?client_pubkey&exp_time
           ,   method GET    fundingInfoHandler)

       , (basePath' <> "/channels/new" -- ?client_pubkey&exp_time&change_address
           ,   method POST (handleChannelOpen >>= writePaymentResult >>=
                               proceedIfExhausted >>= handleChannelSettlement)
               <|> method OPTIONS applyCORS') --CORS

       , (basePath' <> "/channels/:funding_txid/:funding_vout"
           ,   method PUT    (paymentHandler >>= writePaymentResult >>=
                               proceedIfExhausted >>= handleChannelSettlement)
           <|> method DELETE (handleChannelSettlement 0)
           <|> method OPTIONS applyCORS') --CORS
        ] :: [(BS.ByteString, Handler App App ())]


fundingInfoHandler :: Handler App App ()
fundingInfoHandler =
    mkFundingInfo <$>
    use openPrice <*>
    use fundingMinConf <*>
    use settlePeriod <*>
    use pubKey <*>
    getQueryArg "client_pubkey" <*>
    getQueryArg "exp_time" <*>
    (use basePath >>= getAppRootURL)
        >>= writeFundingInfoResp

newChannelHandler :: Debug -> Handler App App (BitcoinAmount, ReceiverPaymentChannel)
newChannelHandler debug = applyCORS' >>
    ChanOpenConfig <$>
        use openPrice <*>
        use pubKey <*>
        use dbConn <*>
        blockchainGetFundingInfo debug <*>
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
            use dbConn <*>
            channelIDFromPathArgs <*>
            getQueryArg "payment") <*>
        getOptionalQueryArg "change_address"
    >>= chanPay

settlementHandler :: Debug -> BitcoinAmount -> Handler App App ()
settlementHandler debug valueReceived = do
    applyCORS'

    settleChanFunc <- use settleChanFunc
    stdConf <- StdConfig <$>
            use dbConn <*>
            channelIDFromPathArgs <*>
            getQueryArg "payment"
    chanSettle debug stdConf settleChanFunc valueReceived

