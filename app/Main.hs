{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | nginx-lb-render: fetch servers/$server/{config,upstreams/*,locations/*}
-- from Consul KV and render them via Types.hs's ToNginxConf. Writes one
-- "<name>.conf" file per server into a fresh, timestamped generation
-- directory under --conf-dir, never touching --conf-dir itself or any
-- earlier generation, and does not run "nginx -t" or reload nginx itself -
-- that's deliberately left to whatever invokes this (a symlink swap +
-- test + reload/revert flow, the same way confd's check_cmd/reload_cmd
-- and consul-template's exec block work elsewhere in this repo).
--
-- Invoked two ways, both doing the same authoritative "GET /v1/kv/<prefix>"
-- fetch rather than trusting whatever a consul watch handler is passed on
-- stdin: once as a pre-start render before nginx.service starts (no watch
-- event, nothing on stdin to trust anyway), and again as the handler of a
-- "keyprefix" consul watch on --kv-prefix for every KV change afterwards.
module Main where

import Data.Aeson (Value, eitherDecode)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Network.HTTP.Simple
import Network.HTTP.Types.Status (statusCode)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((<.>), (</>))
import System.IO (hPutStrLn, stderr)

import Grouping
import Types (Server, config, name, toNginxConf)

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
      <> value "nginx/conf/servers/" <> showDefault
      <> help "Consul KV prefix holding servers/$server/{config,upstreams/*/config,locations/*/config}" ))
  <*> strOption
      ( long "conf-dir" <> metavar "DIR"
      <> value "/etc/nginx-lb/conf.d"
      <> help "Directory under which each render's timestamped generation (one file per server) is created" )

opts :: ParserInfo Args
opts = info (argsParser <**> helper)
  ( fullDesc
  <> progDesc "Render nginx server/location/upstream blocks from Consul KV, one file per server, into a new --conf-dir/<timestamp>/ generation (does not test or reload nginx, and does not swap any \"current\" symlink - that's left to whatever invokes this)"
  <> header "nginx-lb-render" )

-- ===================== Consul KV fetch =====================

-- | A 404 (prefix not configured yet) is not an error - it's zero servers.
-- A "Left" means Consul's response couldn't be parsed at all; it's
-- deliberately not thrown, since a crash here is worse than skipping a
-- render (see decodeKvEntries in Grouping.hs for per-entry failures).
fetchKvPrefix :: String -> T.Text -> IO (Either T.Text ([T.Text], [KVEntry]))
fetchKvPrefix consulAddr prefix = do
  request <- parseRequest ("GET http://" <> consulAddr <> "/v1/kv/" <> T.unpack prefix <> "?recurse=true")
  response <- httpLBS request
  pure $ case statusCode (getResponseStatus response) of
    200 -> case eitherDecode (getResponseBody response) :: Either String [Value] of
      Left err     -> Left ("failed to parse Consul KV response: " <> T.pack err)
      Right values -> Right (decodeKvEntries values)
    404 -> Right ([], [])
    code -> Left ("Consul KV GET /v1/kv/" <> prefix <> " returned HTTP " <> T.pack (show code))

-- ===================== render =====================

-- | Renders each server to its own "<name>.conf" in a fresh
-- "confDir/<timestamp>/" generation directory, and stops there - the
-- "current" symlink swap, "nginx -t", and reload/revert are left to
-- whatever invokes this.
renderGeneration :: FilePath -> [Server] -> IO FilePath
renderGeneration confDir servers = do
  now <- getCurrentTime
  let genDir = confDir </> formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
  createDirectoryIfMissing True genDir
  mapM_ (\server -> TIO.writeFile (genDir </> T.unpack server.config.name <.> "conf") (toNginxConf server)) servers
  pure genDir

main :: IO ()
main = do
  args <- execParser opts
  result <- fetchKvPrefix (argConsulAddr args) (argKvPrefix args)
  case result of
    Left err -> hPutStrLn stderr (T.unpack err)
    Right (fetchWarnings, entries) -> do
      let (warnings, servers) = assembleServersFromKv (argKvPrefix args) entries
      mapM_ (hPutStrLn stderr . T.unpack) (fetchWarnings <> warnings)
      genDir <- renderGeneration (argConfDir args) servers
      hPutStrLn stderr ("rendered " <> show (length servers) <> " server(s) to " <> genDir)
      putStrLn genDir
