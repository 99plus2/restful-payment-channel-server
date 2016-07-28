{-# LANGUAGE FlexibleInstances #-}

module ChanStore.Lib.ChanMap where


import           DiskMap (newDiskMap, addItem, getItem,
                            CreateResult,
                            mapGetItem,
                            getItemCount,
                            getFilteredKeys)

import           ChanStore.Lib.Types hiding (CreateResult(..), UpdateResult(..), CloseResult(..))
import           Data.Bitcoin.PaymentChannel.Types
import           Data.Bitcoin.PaymentChannel.Util (unsafeUpdateRecvState)
import           Control.Concurrent.STM (STM, atomically)

isSettled :: ChanState -> Bool
isSettled (ChannelSettled _ _ _) = True
isSettled _ = False

isOpen :: ChanState -> Bool
isOpen (ReadyForPayment _) = True
isOpen _ = False

newChanMap :: FilePath -> IO ChannelMap
newChanMap = newDiskMap

getChanState :: ChannelMap -> Key -> IO (Maybe ChanState)
getChanState = getItem

addChanState :: ChannelMap -> Key -> ReceiverPaymentChannel -> IO CreateResult
addChanState chanMap key chanState =
    addItem chanMap key (ReadyForPayment chanState)

updateChanState :: ChannelMap -> Key -> Payment -> IO (MapItemResult Key ChanState)
updateChanState chanMap key payment =
    let
        updateIfOpen (ReadyForPayment rpc) =
            Just $ ReadyForPayment (unsafeUpdateRecvState rpc payment)
        updateIfOpen _ =
            Nothing
    in
        mapGetItem chanMap updateIfOpen key

mapLen = getItemCount

openChannelCount :: ChannelMap -> IO Int
openChannelCount chanMap = atomically $
    length <$> getFilteredKeys chanMap isOpen