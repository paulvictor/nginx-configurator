{-# LANGUAGE OverloadedStrings #-}

-- | nginx-lb-render: fetch servers/$server and upstreams/$upstream from
-- Consul KV (via decodeKvEntry, below) and render them via NginxConf.hs's
-- NginxConf class. Writes one
-- "<name>.conf" file per server/upstream into a fresh, timestamped
-- generation directory under --conf-dir, never touching --conf-dir itself
-- or any earlier generation, and does not run "nginx -t" or reload nginx
-- itself - that's deliberately left to whatever invokes this (a symlink
-- swap + test + reload/revert flow, the same way confd's
-- check_cmd/reload_cmd and consul-template's exec block work elsewhere in
-- this repo).
--
-- Getting the raw KV bytes and decoding them are deliberately decoupled:
-- 'fetchBytesStdin' and 'fetchBytesHttp' below are two interchangeable
-- ways to produce the same thing - the raw bytes of a JSON array of KV
-- entries, exactly what "GET /v1/kv/<prefix>?recurse=true" itself
-- returns - and 'decodeKvBatch' takes over identically from there
-- regardless of which one supplied them. 'main' currently wires up
-- 'fetchBytesStdin' (this is meant to run as a "keyprefix" consul watch
-- handler, which is handed that same JSON array on stdin, no HTTP
-- round-trip needed); swap that one line to 'fetchBytesHttp
-- (argConsulAddr args) (argKvPrefix args)' to go back to an authoritative
-- self-fetch instead, if the stdin-trusting approach ever turns out to
-- be a problem.
module Main where

import Control.Lens (_Just, _Show, folding, ix, re, to, (^.), (^?))
import Data.Aeson (Value, decodeStrict, eitherDecode, withObject, (.:))
import Data.Aeson.Lens (_String)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.Types as Aeson (Parser)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as LBS
import Data.Either (partitionEithers)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Text.Strict.Lens (packed, utf8)
import Network.HTTP.Simple
import Network.HTTP.Types.Status (statusCode)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath ((<.>), (</>))
import System.IO (hPutStrLn, stderr)

import NginxConf (toNginxConf)
import Types (Named (..), Server, Upstream, name)

-- ===================== CLI =====================

data Args = Args
  { argConsulAddr :: String
  , argKvPrefix   :: T.Text
  , argConfDir    :: FilePath
  }

argsParser :: Parser Args
argsParser = Args
  <$> strOption
      ( long "consul-addr" <> metavar "HOST:PORT"
      <> value "127.0.0.1:8500" <> showDefault
      <> help "Consul HTTP API address" )
  <*> (T.pack <$> strOption
      ( long "kv-prefix" <> metavar "PREFIX"
      <> value "nginx/conf/" <> showDefault
      <> help "Consul KV prefix holding servers/$server and upstreams/$upstream, each one complete JSON value" ))
  <*> strOption
      ( long "conf-dir" <> metavar "DIR"
      <> value "/etc/nginx-lb/conf.d"
      <> help "Directory under which each render's timestamped generation (one file per server/upstream) is created" )

opts :: ParserInfo Args
opts = info (argsParser <**> helper)
  ( fullDesc
  <> progDesc "Render nginx server/location/upstream blocks from Consul KV, one file per server/upstream, into a new --conf-dir/<timestamp>/ generation (does not test or reload nginx, and does not swap any \"current\" symlink - that's left to whatever invokes this)"
  <> header "nginx-lb-render" )

-- ===================== Consul KV entry decode =====================

-- | Decodes one raw Consul KV array element ({"Key": ..., "Value":
-- <base64>}) straight into 'Server' (Left) or 'Upstream' (Right).
-- Classifies by "Key"'s own last two path segments - looked up and
-- split/reversed exactly once - then commits to that one branch, so a
-- correctly-classified entry that fails its own schema (e.g. a
-- "servers/$name" entry missing "listen") reports that specific reason
-- rather than a generic "wrong key shape". One composed Traversal does
-- everything: "ix \"Value\"" (KeyMap's own Ixed instance, so no need to
-- wrap "o" as a Value first the way "key" would require) then "_String"
-- gets the JSON string's Text, "re utf8" flips the Text->ByteString
-- direction of the 'utf8' Prism', "folding B64.decode" decodes the
-- base64 ("Either String" is already Foldable - Left folds to nothing,
-- Right x folds to [x]), "to decodeStrict" turns those bytes into
-- "Maybe" the target settings type via its own FromJSON instance
-- ("decodeStrict :: FromJSON a => ByteString -> Maybe a", strict to
-- match B64.decode's own strict ByteString), and "_Just" unwraps that
-- Maybe into the Traversal itself (so a decode failure just means no
-- match, same as every earlier step).
decodeKvEntry :: Value -> Aeson.Parser (Either Server Upstream)
decodeKvEntry = withObject "KV entry" $ \o -> do
  entryKey <- o .: "Key"
  case reverse (T.splitOn "/" entryKey) of
    (nm : "servers"   : _) -> Left  . Named nm <$> maybe (fail "invalid \"Value\"") pure (o ^? ix "Value"._String.re utf8.folding B64.decode.to decodeStrict._Just)
    (nm : "upstreams" : _) -> Right . Named nm <$> maybe (fail "invalid \"Value\"") pure (o ^? ix "Value"._String.re utf8.folding B64.decode.to decodeStrict._Just)
    _                       -> fail (T.unpack entryKey <> ": unrecognized key shape")

-- ===================== Consul KV fetch =====================

-- | Reads the raw KV bytes straight off stdin - the exact shape Consul's
-- own "keyprefix" watch handler is invoked with (a JSON array of KV
-- entries), no HTTP round-trip needed. Always succeeds - reading stdin
-- doesn't fail the way an HTTP fetch can - but stays "IO (Either T.Text
-- LBS.ByteString)" anyway so it's a drop-in swap for 'fetchBytesHttp' in
-- 'main' below.
fetchBytesStdin :: IO (Either T.Text LBS.ByteString)
fetchBytesStdin = Right <$> LBS.getContents

-- | Fetches the same raw KV bytes via an authoritative
-- "GET /v1/kv/<prefix>?recurse=true" against Consul's own HTTP API,
-- rather than trusting whatever a watch handler is handed on stdin. A
-- 404 (prefix not configured yet) is not an error - it's zero entities -
-- normalized here to "[]", the same bytes Consul itself would return for
-- an existing-but-empty prefix, so 'decodeKvBatch' can handle it
-- uniformly instead of this function special-casing "no entities" itself.
fetchBytesHttp :: String -> T.Text -> IO (Either T.Text LBS.ByteString)
fetchBytesHttp consulAddr prefix = do
  request <- parseRequest ("GET http://" <> consulAddr <> "/v1/kv/" <> T.unpack prefix <> "?recurse=true")
  response <- httpLBS request
  pure $ case statusCode (getResponseStatus response) of
    200  -> Right (getResponseBody response)
    404  -> Right "[]"
    code -> Left ("Consul KV GET /v1/kv/" <> prefix <> " returned HTTP " <> code ^. re _Show.packed)

-- | Where 'fetchBytesStdin' and 'fetchBytesHttp' converge: decodes a raw
-- JSON array of KV entries into every 'Server'/'Upstream' among them,
-- identically regardless of where the bytes came from. A "Left" means
-- the response couldn't be parsed at all - either the body isn't even a
-- JSON array, or (fails fast for now, see decodeKvEntry above) some
-- element didn't decode as a valid server/upstream. Either way
-- deliberately not thrown, since a crash here is worse than skipping a
-- render.
decodeKvBatch :: LBS.ByteString -> Either T.Text ([Server], [Upstream])
decodeKvBatch body = case eitherDecode body :: Either String [Value] of
  Left err -> Left ("failed to parse Consul KV response: " <> T.pack err)
  Right vs -> case traverse (parseEither decodeKvEntry) vs of
    Left err      -> Left ("failed to parse Consul KV response: " <> T.pack err)
    Right results -> Right (partitionEithers results)

-- ===================== render =====================

-- | Renders each server/upstream to its own "<name>.conf" in a fresh
-- "confDir/<timestamp>/{servers,upstreams}/" generation directory, and
-- stops there - the "current" symlink swap, "nginx -t", and reload/revert
-- are left to whatever invokes this. Two subdirectories (rather than one
-- shared one) since a server and an upstream can legitimately share a
-- name - nginx doesn't care which file an "upstream {}"/"server {}" block
-- physically lives in, only that both end up "include"d somewhere under
-- the "http" context.
renderGeneration :: FilePath -> [Server] -> [Upstream] -> IO FilePath
renderGeneration confDir servers upstreams = do
  now <- getCurrentTime
  let genDir = confDir </> formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
  createDirectoryIfMissing True (genDir </> "servers")
  createDirectoryIfMissing True (genDir </> "upstreams")
  mapM_ (\server -> TIO.writeFile (genDir </> "servers" </> T.unpack (server ^. name) <.> "conf") (toNginxConf server)) servers
  mapM_ (\up -> TIO.writeFile (genDir </> "upstreams" </> T.unpack (up ^. name) <.> "conf") (toNginxConf up)) upstreams
  pure genDir

main :: IO ()
main = do
  args <- execParser opts
  -- swap for `fetchBytesHttp (argConsulAddr args) (argKvPrefix args)` to
  -- fetch authoritatively from Consul's KV API instead of trusting stdin.
  bytesResult <- fetchBytesStdin
  case bytesResult >>= decodeKvBatch of
    -- fails fast on the first bad entry for now - see decodeKvEntry
    -- above; per-entry leniency here is coming back via an accumulating
    -- Applicative later.
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
    Right (servers, upstreams) -> do
      genDir <- renderGeneration (argConfDir args) servers upstreams
      hPutStrLn stderr ("rendered " <> show (length servers) <> " server(s) and "
                          <> show (length upstreams) <> " upstream(s) to " <> genDir)
      putStrLn genDir
