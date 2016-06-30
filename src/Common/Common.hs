{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Common.Common where

import           Common.Types

import           Data.Bitcoin.PaymentChannel
import           Data.Bitcoin.PaymentChannel.Types (Payment, ChannelParameters(..), b64Encode)


import           Control.Monad (mzero)
import           Control.Monad.IO.Class (liftIO)

import           Control.Lens ((^.))
import           Network.Wreq (get, asJSON, responseBody, Response)

import qualified Crypto.Secp256k1 as Secp
import           Data.Aeson.Encode.Pretty (encodePretty)
import           Data.Aeson.Types (Parser, parseMaybe, parseEither)
import           Data.Aeson
    (Result(..), Value(Number, Object, String), FromJSON, ToJSON, parseJSON, toJSON,
    fromJSON, withScientific, eitherDecodeStrict, encode, decode, (.=), (.:), object)
import Data.Maybe (fromJust)
import Data.Scientific (Scientific, toBoundedInteger, scientific, coefficient)
import Data.ByteString.Lazy (toStrict)
import Data.Time.Clock (getCurrentTime)
import           Data.Bitcoin.PaymentChannel.Util
import qualified Network.Haskoin.Transaction as HT
import qualified Network.Haskoin.Crypto as HC
import qualified Network.Haskoin.Util as HU
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Base16 as B16
import Data.Word (Word8, Word32, Word64)
import Data.List (filter)
import Data.Maybe (listToMaybe)
import Data.EitherR (fmapL)
import Data.String.Conversions (cs)
import Text.Printf (printf)
import qualified Data.Binary as Bin



-- |Types that can be encoded to fit in a URI
class PathParamEncode a where
    pathParamEncode :: a -> BS.ByteString

instance PathParamEncode HC.PubKey where
    pathParamEncode = HU.encodeHex . cs . Bin.encode

instance PathParamEncode HT.TxHash where
    pathParamEncode = HT.txHashToHex

instance PathParamEncode BitcoinLockTime where
    pathParamEncode = cs . encode

instance PathParamEncode Integer where
    pathParamEncode = cs . show

instance PathParamEncode HC.Address where
    pathParamEncode = HC.addrToBase58

instance PathParamEncode Payment where
    pathParamEncode = b64Encode

----

----
-- |Types that can be decoded from a URI component
class PathParamDecode a where
    pathParamDecode :: BS.ByteString -> Either String a

decodeHex bs = maybe (Left "invalid hex string") Right (HU.decodeHex bs)

instance PathParamDecode HC.PubKey where
    pathParamDecode bs =
        decodeHex bs >>=
        fmapL ("failed to decode public key: " ++) . HU.decodeToEither

instance PathParamDecode HT.TxHash where
    pathParamDecode bs =
        maybe (Left $ "failed to decode transaction hash: " ++ cs bs)
            Right (HT.hexToTxHash bs)

instance PathParamDecode BitcoinLockTime where
    pathParamDecode bs = maybe
        (Left "expiration time parse failure") Right (decode . cs $ bs)

instance PathParamDecode HC.Address where
    pathParamDecode bs = maybe
        (Left $ "Bitcoin address parse failure: " ++ show bs) Right (HC.base58ToAddr bs)

instance PathParamDecode Payment where
    pathParamDecode bs =
        case fromJSON . String . cs $ bs of
            Error e -> Left $ "payment parse failure: " ++ e
            Success p -> Right p

instance PathParamDecode Integer where
    pathParamDecode bs = maybe
        (Left "failed to decode funding tx vout") Right (decode . cs $ bs)

instance PathParamDecode Bool where
    pathParamDecode bs =
        case bs of
            "true" -> Right True
            "false" -> Right False
            _       -> Left "boolean must be either \"true\" or \"false\""
----


----URLs----
channelRootURL :: Bool -> BS.ByteString -> BS.ByteString -> String
channelRootURL isSecure hostname basePath =
    printf "%s://%s%s"
        (if isSecure then "https" else "http" :: String)
        (cs hostname :: String)
        (cs basePath :: String)

fundingInfoURL :: Bool -> String -> BS.ByteString -> HC.PubKey -> BitcoinLockTime ->  String
fundingInfoURL isSecure host basePath sendPK expTime =
    channelRootURL isSecure (cs host) basePath ++ "/fundingInfo" ++
    printf "?client_pubkey=%s&exp_time=%d"
        (cs $ pathParamEncode sendPK :: String)
        (toWord32 expTime)

-- /channels/new" -- ?client_pubkey&exp_time
channelOpenURL :: Bool -> String -> BS.ByteString -> HC.PubKey -> BitcoinLockTime -> String
channelOpenURL isSecure host basePath sendPK expTime =
    channelRootURL isSecure (cs host) basePath ++ channelOpenPath sendPK expTime

channelOpenPath :: HC.PubKey -> BitcoinLockTime -> String
channelOpenPath sendPK expTime = "/channels/new" ++
    printf "?client_pubkey=%s&exp_time=%s"
        (cs $ pathParamEncode sendPK :: String)
        (cs $ pathParamEncode expTime :: String)

mkOpenQueryParams :: HC.Address -> Payment -> String
mkOpenQueryParams chgAddr payment =
    printf "&change_address=%s&payment=%s"
        (cs $ pathParamEncode chgAddr :: String)
        (cs $ pathParamEncode payment :: String)

mkOpenPath :: HC.PubKey -> BitcoinLockTime -> HC.Address -> Payment -> String
mkOpenPath sendPK expTime chgAddr payment =
    channelOpenPath sendPK expTime ++ mkOpenQueryParams chgAddr payment

-- https://localhost/channels/f583e0b.../1
activeChannelURL :: Bool -> BS.ByteString -> BS.ByteString -> HT.TxHash -> Integer -> String
activeChannelURL isSecure host basePath txid vout =
    channelRootURL isSecure (cs host) basePath ++ activeChannelPath txid vout

activeChannelPath :: HT.TxHash -> Integer -> String
activeChannelPath txid vout  = "/channels/" ++
    cs (pathParamEncode txid) ++ "/" ++
    cs (pathParamEncode vout)

-- ?payment=AAf8s...(&change_address=2Nuz3s...)
mkPaymentQueryParams :: Payment -> Maybe HC.Address -> String
mkPaymentQueryParams payment maybeAddr =
    printf "?payment=%s"
        (cs $ pathParamEncode payment :: String) ++
    maybe "" (\addr -> "&change_address=" ++ (cs . pathParamEncode $ addr)) maybeAddr

mkPaymentURL :: Bool -> String -> BS.ByteString -> HT.TxHash -> Integer -> Payment -> String
mkPaymentURL isSecure host basePath txid vout payment  =
    activeChannelURL isSecure (cs host) basePath txid vout ++ mkPaymentQueryParams payment Nothing

----URLs-----


getFundingAddress' :: HC.PubKey -> HC.PubKey -> BitcoinLockTime -> HC.Address
getFundingAddress' sendPK recvPK blt =
    getFundingAddress $ CChannelParameters sendPK recvPK blt

toString :: HC.Address -> String
toString = C.unpack . HC.addrToBase58










-----

newtype Satoshi = Satoshi Integer deriving (Eq, Num, Ord, Enum, Real, Integral)
instance Bounded Satoshi where
    minBound = Satoshi 0
    maxBound = Satoshi $ round $ 21e6 * 1e8 -- Will work fine for a Word32, too.

instance ToJSON BitcoinLockTime where
    toJSON blt = Number $ scientific
        (fromIntegral $ toWord32 blt) 0

instance FromJSON BitcoinLockTime where
    parseJSON = withScientific "BitcoinLockTime" $
        fmap (parseBitcoinLocktime . fromIntegral) . parseJSONInt

parseJSONInt :: Scientific -> Parser Integer
parseJSONInt = fmap fromIntegral . parseJSONWord

parseJSONWord :: Scientific -> Parser Word64
parseJSONWord s =
    case toBoundedInteger s of
        Just w -> return w
        Nothing -> fail $ "failed to decode JSON number to Word64. data: " ++ show s

-----

toJSONNum :: Integral a => a -> Value
toJSONNum i = Number $ scientific (toInteger i) 0

fromHexString :: String -> BS.ByteString
fromHexString hexStr =
    case (B16.decode . C.pack) hexStr of
        (bs,e) ->
            if BS.length e /= 0 then BS.empty else bs
