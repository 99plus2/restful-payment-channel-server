module ChanStore.Lib.Types
(
ChanState(..),
CreateResult(..),UpdateResult(..),CloseResult(..),
MapItemResult(..),
MaybeChanState(..),
Key,
ChannelMap(..)
)

where


import           Data.DiskMap (DiskMap, SyncAction,
                            CreateResult(..),
                            Serializable(..), ToFileName(..), Hashable(..), MapItemResult(..))

import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, PaymentChannelState,
                                                    Payment, SendPubKey)
import           Data.Bitcoin.PaymentChannel.Util (deserEither)
import qualified Network.Haskoin.Transaction as HT
import qualified Data.Serialize as Bin
import qualified Data.Serialize.Get as BinGet
import Data.String.Conversions (cs)
import           Control.Concurrent (ThreadId)


data ChannelMap = ChannelMap
    (DiskMap Key ChanState)
    (Maybe (SyncAction,ThreadId))   -- Used when deferred sync is enabled

type Key = SendPubKey

data CloseResult  = Closed | DoesntExist deriving (Show, Eq)
data UpdateResult = WasUpdated | WasNotUpdated deriving (Show, Eq)

-- |Holds state for payment channel
data ChanState =
    ReadyForPayment         ReceiverPaymentChannel
  | ChannelSettled          HT.TxHash Payment ReceiverPaymentChannel    -- Save the old channel state in the map for now. We can always purge it later to save space.
  | SettlementInProgress    ReceiverPaymentChannel
      deriving Show


-- Needed for Binary instance non-overlap
newtype MaybeChanState = MaybeChanState { getMaybe :: Maybe ChanState }






instance Bin.Serialize CreateResult where
    put Created = Bin.putWord8 1
    put AlreadyExists = Bin.putWord8 2
    get = Bin.getWord8 >>= \w -> case w of
            1 -> return Created
            2 -> return AlreadyExists
            _ -> fail "unknown byte"

instance Bin.Serialize UpdateResult where
    put WasUpdated = Bin.putWord8 1
    put WasNotUpdated = Bin.putWord8 2
    get = Bin.getWord8 >>= \w -> case w of
            1 -> return WasUpdated
            2 -> return WasNotUpdated
            _ -> fail "unknown byte"

instance Bin.Serialize CloseResult where
    put Closed = Bin.putWord8 1
    put DoesntExist = Bin.putWord8 2
    get = Bin.getWord8 >>= \w -> case w of
            1 -> return Closed
            2 -> return DoesntExist
            _ -> fail "unknown byte"



instance ToFileName SendPubKey

instance Hashable SendPubKey where
    hashWithSalt salt sendPK =
        salt `hashWithSalt` serialize sendPK

instance Serializable SendPubKey where
    serialize   = Bin.encode
    deserialize = deserEither . cs

instance Serializable ChanState where
    serialize   = Bin.encode
    deserialize = deserEither . cs

instance Bin.Serialize ChanState where
    put (ReadyForPayment s) =
        Bin.putWord8 0x02 >>
        Bin.put s
    put (ChannelSettled txid payment s) =
        Bin.putWord8 0x03 >>
        Bin.put txid >> Bin.put payment >> Bin.put s
    put (SettlementInProgress s) =
        Bin.putWord8 0x04 >>
        Bin.put s

    get = Bin.getWord8 >>=
        (\byte -> case byte of
            0x02    -> ReadyForPayment   <$> Bin.get
            0x03    -> ChannelSettled   <$> Bin.get <*> Bin.get <*> Bin.get
            0x04    -> SettlementInProgress <$> Bin.get
            n       -> fail $ "unknown start byte: " ++ show n)

instance Bin.Serialize MaybeChanState where
    put (MaybeChanState (Just chs)) = Bin.putWord8 0x01 >> Bin.put chs
    put (MaybeChanState Nothing)    = Bin.putWord8 0x00

    get = BinGet.getWord8 >>= \w -> case w of
        0x01 -> MaybeChanState . Just <$> Bin.get
        0x00 -> return (MaybeChanState Nothing)
        n    -> fail $ "unknown start byte: " ++ show n





