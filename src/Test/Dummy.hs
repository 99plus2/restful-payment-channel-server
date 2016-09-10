{-# LANGUAGE  OverloadedStrings #-}

module Test.Dummy
(
    getAddr
)

where

import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Constants as HCC


getAddr :: IO HC.Address
getAddr =
    let
        dummyAddrTestnet = "2N414xMNQaiaHCT5D7JamPz7hJEc9RG7469"
        dummyAddrLivenet = "1DCczXkxD3i2r8jHJfzRmnXdvpX5P5K78Q"
    in
        if HCC.getNetworkName HCC.getNetwork == "testnet" then
                return dummyAddrTestnet
            else
                return dummyAddrLivenet