module  PayChanServer.Types where

import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, BitcoinAmount,
                                                    Payment, BitcoinLockTime, FundingTxInfo)
-- import           Data.Bitcoin.PaymentChannel.Util (BitcoinLockTime)
import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Transaction as HT

import           PayChanServer.Config.Types (OpenConfig)
import           ChanStore.Lib.Types (ConnManager)
import qualified Data.ByteString as BS
import           BlockchainAPI.Types (TxInfo)



type Vout = Integer     -- Output index

data StdConfig = StdConfig {
    serverChanMap   :: ConnManager,
    chanId          :: HT.OutPoint,
    chanPayment     :: Payment
}

data OpenHandlerConf = OpenHandlerConf {
    ocOpenPrice     :: BitcoinAmount
   ,ocServerPubKey  :: HC.PubKey
   ,ocDBConn        :: ConnManager
   ,ocFundingInfo   :: FundingTxInfo
   ,ocBasePath      :: BS.ByteString
   ,ocClientPubKey  :: HC.PubKey
   ,ocClientChange  :: HC.Address
   ,ocExpTime       :: BitcoinLockTime
   ,ocInitPayment   :: Payment
}


data ChanPayConfig = PayConfig
    StdConfig (Maybe HC.Address)

data ServerSettleConfig = ServerSettleConfig {
    confSettleTxFee       :: BitcoinAmount,
    confSettlePeriod      :: Int
}

data SigningSettleConfig = SigningSettleConfig {
    confSettlePrivKey     :: HC.PrvKey,
    confSettleRecvAddr    :: HC.Address
}

