{-|
Module      : SettlementService.Interface
Description : Publish settlement transactions when given payment channel states
Copyright   : (c) Rune K. Svendsen, 2016
License     : PublicDomain
Maintainer  : runesvend@gmail.com
Stability   : experimental
Portability : POSIX

A service that runs somewhere safe, although reachable from the outside, which keeps the
 server private key, and produces a settlement transaction for each ReceiverPaymentChannel
 it receives. This service is configured with the private key whose public
 counterpart is advertized by PayChanServer, as well as a funds destination address,
 and will only produce settlement transactions paying to this pre-defined address.

This file describes the server interface (currently comprising 'settleChannel' only).
-}


module SettlementService.Interface
(
    settleChannel
)
where

import           SettlementService.Spec (SettleChan(..))
import           Server.ChanStore.Types (ConnManager)
import           Server.ChanStore.RequestRunner (runRequest)

import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel)
-- import qualified Network.Haskoin.Transaction as HT

-- |Publish settlement transaction by POSTing a list of states to the endpoint /settle_channel
settleChannel :: ConnManager -> [ReceiverPaymentChannel] -> IO ()
settleChannel conn rpc = runRequest conn $ SettleChan rpc
