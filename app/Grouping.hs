{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

-- | Pure assembly of Consul's KV tree (servers/$server/{config,
-- upstreams/*/config, locations/*/config}) into rendered-ready 'Server's.
-- Kept free of IO so it can be unit tested the same way as "Types.hs" -
-- "Main.hs" is the only place that talks to the network or the filesystem.
module Grouping
  ( KVEntry (..)
  , decodeKvEntries
  , assembleServersFromKv
  ) where

import Data.Aeson (FromJSON (..), Object, Value (Object), eitherDecodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Base64 as B64
import Data.Either (partitionEithers)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Types

-- | One entry as Consul's KV API returns it, already validated: "Key" is
-- the full path from the root (not relative to the watched prefix),
-- "Value" is base64 in Consul's own response but has been decoded and
-- parsed as a JSON object here - the only shape ServerConfig/Upstream/
-- Location ever expect (all three parse via withObject in Types.hs). A
-- null/absent, non-base64, or non-object "Value" all fail this instance's
-- parse ("fail" below) rather than producing some placeholder KVEntry -
-- see decodeKvEntries below for why that per-entry failure doesn't take
-- down the whole batch.
data KVEntry = KVEntry
  { kvKey   :: Text
  , kvValue :: Object
  } deriving (Show, Generic)

instance FromJSON KVEntry where
  parseJSON = withObject "KVEntry" $ \o -> do
    key   <- o .: "Key"
    mb64  <- o .:? "Value"
    b64   <- maybe (fail (T.unpack key <> ": has no value")) pure mb64
    bytes <- either (\err -> fail (T.unpack key <> ": invalid base64: " <> err)) pure
               (B64.decode (TE.encodeUtf8 b64))
    obj   <- either (\err -> fail (T.unpack key <> ": " <> err)) pure
               (eitherDecodeStrict bytes)
    pure (KVEntry key obj)

-- | Decodes every entry from Consul's raw KV response, keeping only the
-- ones that parse as a valid KVEntry (present, valid base64, a JSON
-- object) and rejecting everything else with a warning. Deliberately takes
-- [Value] rather than doing "eitherDecode :: Either String [KVEntry]"
-- itself: aeson's list FromJSON instance is fail-fast, so that would abort
-- the ENTIRE batch the moment any one entry's Value is null/bad-base64/
-- non-object. [Value] only fails to decode if Consul's response isn't even
-- a JSON array (see fetchKvPrefix in Main.hs, a genuine bug worth
-- aborting over) - once we have that, running KVEntry's own FromJSON over
-- each element individually via parseEither isolates each entry's failure
-- to just that entry.
decodeKvEntries :: [Value] -> ([Text], [KVEntry])
decodeKvEntries values =
  let (errs, entries) = partitionEithers (map (parseEither parseJSON) values)
  in (map T.pack errs, entries)

data ServerBuild = ServerBuild
  { sbConfig    :: Maybe ServerConfig
  , sbUpstreams :: Map Text Upstream
  , sbLocations :: Map Text Location
  }

emptyServerBuild :: ServerBuild
emptyServerBuild = ServerBuild Nothing Map.empty Map.empty

-- | Strip the watched prefix off a key and split what's left into path
-- segments, e.g. "nginx/conf/servers/alb/locations/events/config" with
-- prefix "nginx/conf/servers/" becomes ["alb", "locations", "events", "config"].
relativeSegments :: Text -> Text -> [Text]
relativeSegments prefix key =
  filter (not . T.null) (T.splitOn "/" (maybe key id (T.stripPrefix prefix key)))

-- | Group + assemble every (already-validated, see decodeKvEntries above)
-- KV entry under the watched prefix into 'Server's. Anything that doesn't
-- fit (bad JSON shape for its target type, an unrecognized key shape) is
-- dropped with a warning rather than aborting - the whole-file 'nginx -t'
-- gate in Main.hs is the real safety net, so being lenient here just means
-- "this one entry didn't parse" shows up as a log line instead of taking
-- down every other server's render too.
assembleServersFromKv :: Text -> [KVEntry] -> ([Text], [Server])
assembleServersFromKv prefix entries =
  let (warnings, builds) = foldl (step prefix) ([], Map.empty) entries
      (skipWarnings, servers) = foldMap finalize (Map.toList builds)
  in (reverse warnings <> skipWarnings, servers)
  where
    finalize (name, sb) = case sbConfig sb of
      Nothing ->
        ( [ "skipping server \"" <> name <> "\": no servers/" <> name <> "/config key found" ]
        , []
        )
      Just cfg ->
        ( []
        , [ Server
              { config    = cfg
              , upstreams = Map.elems (sbUpstreams sb)
              , locations = Map.elems (sbLocations sb)
              }
          ]
        )

step :: Text -> ([Text], Map Text ServerBuild) -> KVEntry -> ([Text], Map Text ServerBuild)
step prefix (warnings, builds) entry = case relativeSegments prefix (kvKey entry) of
  [server, "config"] ->
    withDecoded $ \(cfg :: ServerConfig) ->
      Map.alter (upsert (\sb -> sb { sbConfig = Just ((cfg :: ServerConfig) { name = server }) })) server builds
  [server, "upstreams", entryName, "config"] ->
    withDecoded $ \(up :: Upstream) ->
      Map.alter (upsert (\sb -> sb { sbUpstreams = Map.insert entryName ((up :: Upstream) { name = entryName }) (sbUpstreams sb) })) server builds
  [server, "locations", entryName, "config"] ->
    withDecoded $ \(loc :: Location) ->
      Map.alter (upsert (\sb -> sb { sbLocations = Map.insert entryName ((loc :: Location) { name = entryName }) (sbLocations sb) })) server builds
  _ -> (warn ("ignoring unrecognized key shape: " <> kvKey entry) : warnings, builds)
  where
    warn msg = msg
    upsert f = Just . f . maybe emptyServerBuild id
    withDecoded :: FromJSON a => (a -> Map Text ServerBuild) -> ([Text], Map Text ServerBuild)
    withDecoded withValue = case parseEither parseJSON (Object (kvValue entry)) of
      Left err -> (warn (kvKey entry <> ": " <> T.pack err) : warnings, builds)
      Right v  -> (warnings, withValue v)
