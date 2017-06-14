{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE OverloadedStrings     #-}

module Node.Message.Store
    ( StoreP (..)
    ) where

import qualified Data.Store                    as Store
import qualified Data.ByteString               as BS
import qualified Data.ByteString.Lazy          as LBS
import           Data.Word                     (Word32)
import qualified Network.Transport.Internal    as NT (encodeWord32, decodeWord32)
import           Node.Message.Class            (Serializable (..))
import           Node.Message.Decoder          (Decoder (..))

data StoreP = StoreP

instance Store.Store t => Serializable StoreP t where

    -- Length-prefix the store-encoded body. The length is assumed to fit into
    -- 32 bits.
    packMsg _ t = encoded
      where
        encodedBody = Store.encode t
        encodedLength = NT.encodeWord32 (fromIntegral (BS.length encodedBody))
        encoded = LBS.fromStrict (BS.append encodedLength encodedBody)

    unpackMsg _ = storeDecoder BS.empty

storeDecoder :: Store.Store t => BS.ByteString -> Decoder t
storeDecoder bs = Partial $ \mbs -> case mbs of
    Nothing -> Fail BS.empty (fromIntegral (BS.length bs)) "Unexpected end of input (length prefix)"
    Just bs' ->
        let (front, back) = BS.splitAt 4 (BS.append bs bs')
        in  if BS.length front == 4
            then storeDecoderBody (NT.decodeWord32 front) BS.empty (Just back)
            -- In this case, back is empty and front has length strictly less
            -- than 4, so we have to wait for more input.
            else storeDecoder front

storeDecoderBody
    :: ( Store.Store t )
    => Word32
    -> BS.ByteString
    -> Maybe BS.ByteString
    -> Decoder t
storeDecoderBody !remaining !acc !mbs = case mbs of
    Nothing -> Fail BS.empty (fromIntegral (BS.length acc)) "Unexpected end of input (body)"
    Just bs ->
        let (front, back) = BS.splitAt (fromIntegral remaining) bs
            taken = fromIntegral (BS.length front)
            acc' = BS.append acc front
            remaining' = remaining - taken
        in  if taken < remaining
            then Partial $ storeDecoderBody remaining' acc'
            else case Store.decode acc' of
                Left ex -> Fail back (fromIntegral (BS.length acc')) (Store.peekExMessage ex)
                Right t -> Done back (fromIntegral (BS.length acc')) t
