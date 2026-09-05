{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Lens (_Just, folding, ix, re, to, (^.), (^?))
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
import Data.Text.Strict.Lens (utf8)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath ((<.>), (</>))
import System.IO (hPutStrLn, stderr)

import NginxConf (toNginxConf)
import Types (Named (..), Server, Upstream, name)

-- ===================== CLI =====================

newtype Args = Args
  { confDir :: FilePath
  }

argsParser :: Parser Args
argsParser = Args
  <$> strOption
      ( long "conf-dir" <> metavar "DIR"
      <> value "/etc/nginx-lb/conf.d"
      <> help "Directory under which each render's timestamped generation (one file per server/upstream) is created" )

opts :: ParserInfo Args
opts = info (argsParser <**> helper)
  ( fullDesc
  <> progDesc "Render nginx server/location/upstream blocks from a JSON array of Consul KV entries read on stdin, one file per server/upstream, into a new --conf-dir/<timestamp>/ generation (does not test or reload nginx, and does not swap any \"current\" symlink - that's left to whatever invokes this)"
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

-- | Decodes the raw JSON array of KV entries read off stdin - the exact
-- shape Consul's own "keyprefix" watch handler is invoked with - into
-- every 'Server'/'Upstream' among them. Decodes as "Maybe [Value]", not
-- "[Value]" outright, because Consul's own "keyprefix" watch handler
-- sends the literal JSON value "null" (not an empty array) when nothing
-- currently matches the watched prefix - verified against a real running
-- agent. "concat" on the resulting "Maybe [Value]" folds "Nothing" to
-- "[]" and "Just vs" to "vs" for free, since "Maybe" is already
-- "Foldable". A "Left" means the response couldn't be parsed at all -
-- either the body isn't even "null" or a JSON array, or (fails fast for
-- now, see decodeKvEntry above) some element didn't decode as a valid
-- server/upstream. Either way deliberately not thrown, since a crash
-- here is worse than skipping a render.
decodeKvBatch :: LBS.ByteString -> Either T.Text ([Server], [Upstream])
decodeKvBatch body = case eitherDecode body :: Either String (Maybe [Value]) of
  Left err  -> Left ("failed to parse Consul KV response: " <> T.pack err)
  Right mvs -> case traverse (parseEither decodeKvEntry) (concat mvs) of
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
renderGeneration baseDir servers upstreams = do
  now <- getCurrentTime
  let genDir = baseDir </> formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
  createDirectoryIfMissing True (genDir </> "servers")
  createDirectoryIfMissing True (genDir </> "upstreams")
  mapM_ (\server -> TIO.writeFile (genDir </> "servers" </> T.unpack (server ^. name) <.> "conf") (toNginxConf server)) servers
  mapM_ (\up -> TIO.writeFile (genDir </> "upstreams" </> T.unpack (up ^. name) <.> "conf") (toNginxConf up)) upstreams
  pure genDir

main :: IO ()
main = do
  args <- execParser opts
  body <- LBS.getContents
  case decodeKvBatch body of
    -- fails fast on the first bad entry for now - see decodeKvEntry
    -- above; per-entry leniency here is coming back via an accumulating
    -- Applicative later.
    Left err -> do
      hPutStrLn stderr (T.unpack err)
      exitFailure
    -- zero servers renders nginx with nothing listening on any port -
    -- refuse rather than risk a swap script putting an empty generation
    -- live. Zero upstreams alone is fine (a server may not proxy to one).
    Right ([], _) -> do
      hPutStrLn stderr "no servers found; refusing to render an empty generation"
      exitFailure
    Right (servers, upstreams) -> do
      genDir <- renderGeneration (confDir args) servers upstreams
      hPutStrLn stderr ("rendered " <> show (length servers) <> " server(s) and "
                          <> show (length upstreams) <> " upstream(s) to " <> genDir)
      putStrLn genDir
