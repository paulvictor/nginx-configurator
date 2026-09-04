{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Pure decoding of Consul's flattened KV tree (servers/$server,
-- upstreams/$upstream - see DESIGN.md's KV layout section) into
-- rendered-ready 'Server's and 'Upstream's. Kept free of IO so it can be
-- unit tested the same way as "Types.hs" - "Main.hs" is the only place
-- that talks to the network or the filesystem.
--
-- 'Entity' has a genuine "FromJSON" instance that goes straight from one
-- raw Consul KV array element ({"Key": ..., "Value": <base64>, ...}) to a
-- typed 'Server' or 'Upstream' - no intermediate "raw KV entry" type. That
-- works because classifying a key ("is this a server or an upstream, and
-- what's its name") only needs the key's own *last two path segments*
-- ("servers"/"upstream" + a name), not the watched KV prefix - the prefix
-- is still needed to scope the Consul HTTP query itself (see
-- Main.hs's fetchKvPrefix), just not for classifying what comes back.
-- This assumes the watched prefix contains nothing but servers/upstreams
-- entries - a real precondition, not enforced here.
--
-- There is no cross-entry assembly here either: a Nix module upstream of
-- Consul merges each server's config+locations (and each upstream) into
-- one complete KV value apiece, so every entry independently decodes to
-- exactly one 'Server' or 'Upstream' - see DESIGN.md for why this
-- replaced the earlier three-level, fold-based KV layout.
--
-- A server's/upstream's own name comes from its KV key, not the JSON
-- body - it's injected as a real "name" field into the JSON *before*
-- anything is parsed - see 'prepareServerValue' below - so Types.hs's own
-- FromJSON instances can read "name" like any other required field.
-- Locations have no name field at all (see Types.hs's Location) - nothing
-- ever reads one - so their "locations" map key is only ever used to
-- pick out which JSON value to decode, never injected anywhere.
module Grouping
  ( Entity (..)
  , _ServerEntity
  , _UpstreamEntity
  , partitionEntities
  ) where

import Control.Lens (makePrisms, preview)
import Data.Aeson (FromJSON (..), Object, Value (..), eitherDecodeStrict, withObject, (.:), (.:?))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Base64 as B64
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Types

-- | Sum of the two top-level KV entities.
data Entity = ServerEntity Server | UpstreamEntity Upstream
  deriving (Show)

makePrisms ''Entity

-- | Decodes one raw Consul KV array element directly: extracts "Key",
-- base64-decodes and JSON-decodes "Value" (a null/absent, non-base64, or
-- non-object "Value" all fail here - real states a live Consul KV tree
-- can produce, e.g. an unrelated key sharing part of the watched prefix,
-- not bugs worth crashing over), classifies by the key's last two path
-- segments, injects whatever name(s) that classification implies, and
-- parses the result as a 'Server' or 'Upstream'.
instance FromJSON Entity where
  parseJSON = withObject "Entity" $ \o -> do
    key   <- o .: "Key"
    mb64  <- o .:? "Value"
    b64   <- maybe (fail (T.unpack key <> ": has no value")) pure mb64
    bytes <- either (\err -> fail (T.unpack key <> ": invalid base64: " <> err)) pure
               (B64.decode (TE.encodeUtf8 b64))
    obj   <- either (\err -> fail (T.unpack key <> ": " <> err)) pure
               (eitherDecodeStrict bytes)
    case reverse (T.splitOn "/" key) of
      (nm : "servers"   : _) ->
        ServerEntity   <$> parseJSON (prepareServerValue nm obj)
      (nm : "upstreams" : _) ->
        UpstreamEntity <$> parseJSON (Object (KM.insert "name" (String nm) obj))
      _                       -> fail ("unrecognized key shape: " <> T.unpack key)

-- | Injects the server's own name directly into the top-level object -
-- Server's FromJSON instance reads "name" (and its other settings fields)
-- straight off this same object, ignoring the sibling "locations" key it
-- doesn't ask for, so there's no need for a separate "config" wrapper.
-- Each nested location is left untouched: Location has no "name" field
-- for anything to inject.
prepareServerValue :: Text -> Object -> Value
prepareServerValue srvName o = Object (KM.insert "name" (String srvName) o)

partitionEntities :: [Entity] -> ([Server], [Upstream])
partitionEntities entities =
  (mapMaybe (preview _ServerEntity) entities, mapMaybe (preview _UpstreamEntity) entities)
