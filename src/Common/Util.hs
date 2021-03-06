{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Common.Util
(
    module Common.Util,
    module Common.URLParam,
    liftIO,
    mzero,
    unless, when,
    (<>),
    cs,
    view,
    HexBinEncode(..),
    HexBinDecode(..),
    JSON.ToJSON(..),
    JSON.FromJSON(..),
    RecvPubKey(..)
)

where

import           Prelude hiding (userError)

import           Common.Types
import           Common.URLParam
import qualified RBPCP.Types as RBPCP

import           Data.String.Conversions (cs)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad (mzero)
import           Control.Lens.Getter (view)
import           Control.Monad (unless, when)
import           Data.Monoid ((<>))
import qualified Data.Aeson as JSON


-- New
import qualified Control.Monad.Error.Class as Except
import           Servant
import qualified Data.Serialize as Bin
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Network.Haskoin.Transaction as HT
import qualified Network.Haskoin.Script as HS
import qualified Network.Haskoin.Crypto as HC


class Bin.Serialize a => HexBinEncode a where
    hexEncode :: a -> BS.ByteString
    hexEncode = B16.encode . Bin.encode

class Bin.Serialize a => HexBinDecode a where
    hexDecode :: BS.ByteString -> Either String a
    hexDecode = Bin.decode . fst . B16.decode


instance HexBinEncode BS.ByteString where hexEncode = B16.encode
instance HexBinEncode RecvPubKey
instance HexBinEncode SendPubKey
instance HexBinEncode HS.Script
instance HexBinEncode HC.Signature
instance HexBinEncode HT.TxHash

instance HexBinDecode BS.ByteString where hexDecode = Right . fst . B16.decode
instance HexBinDecode RecvPubKey
instance HexBinDecode SendPubKey
instance HexBinDecode HS.Script
instance HexBinDecode HC.Signature
instance HexBinDecode HT.TxHash

--- HTTP error
userError' :: String -> AppM conf a
userError' = errorWithDescription 400

internalError :: String -> AppM conf a
internalError = errorWithDescription 400

onLeftThrow500 :: Either String a -> AppM conf a
onLeftThrow500   = either internalError return

errorWithDescription :: Int -> String -> AppM conf a
errorWithDescription code e =
    Except.throwError $
        mkServantError RBPCP.PaymentError code (cs e)

applicationError :: String -> AppM conf a
applicationError msg =
    Except.throwError $
        mkServantError RBPCP.ApplicationError 410 (cs msg)
        -- TODO: application error HTTP status code?

mkServantError :: RBPCP.ErrorType -> Int -> String -> ServantErr
mkServantError errType code msg =
    ServantErr
        {  errHTTPCode = code
        ,  errReasonPhrase = cs msg
        ,  errBody = cs responseBody
        ,  errHeaders = []
        }
    where responseBody = JSON.encode $ RBPCP.Error errType (cs msg)
