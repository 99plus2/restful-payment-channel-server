{-# LANGUAGE OverloadedStrings, FlexibleInstances, MultiParamTypeClasses #-}

module ChanStore.Orphans where


import           Common.Util
import           ChanStore.Lib.Types
import           Data.Bitcoin.PaymentChannel.Types -- (FullPayment, BitcoinAmount)
import           Data.Bitcoin.PaymentChannel.Util (deserEither)
import qualified Network.Haskoin.Transaction as HT
import qualified Network.Haskoin.Crypto as HC

import           Servant.API

import           Common.URLParam
import qualified Servant.API.ContentTypes as Content
import qualified Data.Serialize as Bin
import           Data.EitherR (fmapL)
import qualified Data.ByteString.Lazy as BL
import qualified Web.HttpApiData as Web
import           Data.String.Conversions (cs)
import qualified Network.Haskoin.Util as HU


decodeHex bs = maybe (Left "invalid hex string") Right (HU.decodeHex bs)

instance Web.FromHttpApiData HT.OutPoint where
    parseUrlPiece = fmapL cs . pathParamDecode . cs
instance Web.ToHttpApiData HT.OutPoint where
    toUrlPiece = cs . pathParamEncode

instance Web.FromHttpApiData BitcoinAmount where
    parseUrlPiece = fmapL cs . pathParamDecode . cs
instance Web.ToHttpApiData BitcoinAmount where
    toUrlPiece = cs . pathParamEncode

instance Web.FromHttpApiData HT.TxHash where
    parseUrlPiece = fmapL cs . pathParamDecode . cs
instance Web.ToHttpApiData HT.TxHash where
    toUrlPiece = cs . pathParamEncode

instance Web.FromHttpApiData BitcoinLockTime where
    parseUrlPiece = fmapL cs . pathParamDecode . cs
instance Web.ToHttpApiData BitcoinLockTime where
    toUrlPiece = cs . pathParamEncode

instance Web.FromHttpApiData SendPubKey where
    parseUrlPiece = fmapL cs . hexDecode . cs
instance Web.ToHttpApiData SendPubKey where
    toUrlPiece = cs . hexEncode

instance Web.FromHttpApiData HC.Signature where
    parseUrlPiece = fmapL cs . hexDecode . cs
instance Web.ToHttpApiData HC.Signature where
    toUrlPiece = cs . hexEncode

-- instance Web.FromHttpApiData FullPayment where
--     parseUrlPiece = fmapL cs . pathParamDecode . cs
-- instance Web.ToHttpApiData FullPayment where
--     toUrlPiece = cs . pathParamEncode


instance Content.MimeUnrender Content.OctetStream [ReceiverPaymentChannel] where
    mimeUnrender _ = deserEither . BL.toStrict
instance Content.MimeRender Content.OctetStream [ReceiverPaymentChannel] where
    mimeRender _ = BL.fromStrict . Bin.encode

instance Content.MimeUnrender Content.OctetStream ReceiverPaymentChannel where
    mimeUnrender _ = deserEither . BL.toStrict
instance Content.MimeRender Content.OctetStream ReceiverPaymentChannel where
    mimeRender _ = BL.fromStrict . Bin.encode

instance Content.MimeUnrender Content.OctetStream Payment where
    mimeUnrender _ = deserEither . BL.toStrict
instance Content.MimeRender Content.OctetStream Payment where
    mimeRender _ = BL.fromStrict . Bin.encode

instance Content.MimeUnrender Content.OctetStream FullPayment where
    mimeUnrender _ = deserEither . BL.toStrict
instance Content.MimeRender Content.OctetStream FullPayment where
    mimeRender _ = BL.fromStrict . Bin.encode