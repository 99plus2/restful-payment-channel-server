module Server.DB where

import           Server.Util
import qualified Server.ChanStore.Interface as DBConn
import           Data.Bitcoin.PaymentChannel.Types (ReceiverPaymentChannel, Payment)
import qualified Network.Haskoin.Transaction as HT
import qualified Data.ByteString as BS
import           Snap
import           Control.Monad.IO.Class (liftIO)
import           Control.Exception (try)
import           Network.HTTP.Client (HttpException (..))

tryDBRequest :: MonadSnap m => IO a -> m a
tryDBRequest = tryRequestOfType "Database"

trySigningRequest :: MonadSnap m => IO a -> m a
trySigningRequest = tryRequestOfType "Signing service"

tryRequestOfType :: MonadSnap m => String -> IO a -> m a
tryRequestOfType descr ioa = do
    res <- liftIO $ try ioa
    case res of
       Left e -> internalError $ descr ++ " error: " ++ show (e :: HttpException)
       Right a -> return a

confirmChannelDoesntExistOrAbort :: MonadSnap m => DBConn.ConnManager -> BS.ByteString -> HT.OutPoint -> m ()
confirmChannelDoesntExistOrAbort chanMap basePath chanId = do
    maybeItem <- tryDBRequest (DBConn.chanGet chanMap chanId)
    case fmap DBConn.isSettled maybeItem of
        Nothing -> return ()    -- channel doesn't already exist
        Just False ->           -- channel exists already, and is open
            httpLocationSetActiveChannel basePath chanId >>
            errorWithDescription 409 "Channel already exists"
        Just True  ->           -- channel in question has been settled
            errorWithDescription 409 "Channel already existed, but has been settled"


getChannelStateOr404 :: MonadSnap m => DBConn.ConnManager -> HT.OutPoint -> m ReceiverPaymentChannel
getChannelStateOr404 chanMap chanId =
    tryDBRequest (DBConn.chanGet chanMap chanId) >>=
    maybe
        (errorWithDescription 404 "No such channel")
        (return . DBConn.csState)
