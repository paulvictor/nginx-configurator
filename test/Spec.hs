{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DuplicateRecordFields #-}

-- Worked-example unit tests for Types.hs and Grouping.hs, run against the
-- backend's current routes expressed as the
-- servers/$server/{config,upstreams/*,locations/*} JSON documents this
-- design expects from Consul KV, built as aeson 'Value's via 'object'/'.='
-- (which construct their underlying KeyMap via 'KM.fromList') rather than
-- as raw JSON text.
module Main where

import Data.Aeson (FromJSON (..), Value (..), encode, object, (.=))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Base64.Lazy as B64L
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Text (Text)
import Test.Hspec

import Grouping
import Types

main :: IO ()
main = hspec $ do
  describe "Upstream" $ do
    it "parses and renders backend" $ do
      u <- decodeOrFail upstreamJson :: IO Upstream
      let rendered = toNginxConf ((u :: Upstream) { name = "backend" })
      rendered `shouldContainAll`
        [ "upstream backend {"
        , "keepalive 512;"
        , "keepalive_requests 10000;"
        , "keepalive_timeout 30s;"
        , "zone backend 2m;"
        , "}"
        ]
      -- parameters render as an unordered map, so check the token set rather
      -- than one fixed-order string
      directiveTokens "resolver dns-server-1:8600" rendered
        `shouldMatchList` [ "resolver", "dns-server-1:8600", "valid=10s", "ipv6=off" ]
      directiveTokens "server backend.service.consul:8080" rendered
        `shouldMatchList` [ "server", "backend.service.consul:8080"
                          , "weight=1", "resolve", "max_fails=2", "fail_timeout=60s" ]

    it "renders weight, backup and slow_start when set" $ do
      u <- decodeOrFail
             (object
               [ "servers" .=
                   [ object
                       [ "address" .= ("backend.service.consul:8080" :: Text)
                       , "parameters" .= object
                           [ "weight" .= (5 :: Int)
                           , "backup" .= True
                           , "slow_start" .= ("30s" :: Text)
                           ]
                       ]
                   ]
               ])
             :: IO Upstream
      let rendered = toNginxConf ((u :: Upstream) { name = "weighted" })
      directiveTokens "server backend.service.consul:8080" rendered
        `shouldMatchList` [ "server", "backend.service.consul:8080", "weight=5"
                          , "max_fails=3", "fail_timeout=10s", "backup", "slow_start=30s" ]

    it "defaults maxFails to 3 and failTimeout to 10s when omitted" $ do
      u <- decodeOrFail
             (object
               [ "servers" .= [ object [ "address" .= ("backend.service.consul:8080" :: Text) ] ] ])
             :: IO Upstream
      let rendered = toNginxConf ((u :: Upstream) { name = "minimal" })
      directiveTokens "server backend.service.consul:8080" rendered
        `shouldMatchList` [ "server", "backend.service.consul:8080", "weight=1"
                          , "max_fails=3", "fail_timeout=10s" ]

  describe "Location" $ do
    it "renders the /health static check with access_log off" $ do
      l <- decodeOrFail healthJson :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "health" })
      rendered `shouldContainAll`
        [ "location /health {"
        , "return 200 ok;"
        , "access_log off;"
        ]

    it "renders the ^~ / catch-all 404" $ do
      l <- decodeOrFail catchallJson :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "catchall" })
      rendered `shouldContainAll`
        [ "location ^~ / {"
        , "return 404 unavailable;"
        ]

    it "renders a proxying location with its extra includes" $ do
      l <- decodeOrFail barJson :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "bar" })
      rendered `shouldContainAll`
        [ "location ^~ /bar {"
        , "proxy_pass http://backend;"
        , "include /etc/nginx/backend-common.conf;"
        ]

    it "renders no proxy_* directives at all when \"proxy\" is unset, leaving nginx's own defaults in effect" $ do
      l <- decodeOrFail barJson :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "bar" })
      rendered `shouldNotContainAny`
        [ "proxy_http_version", "proxy_next_upstream", "proxy_set_header" ]

    it "renders a custom proxy_http_version, proxy_set_header pairs, and proxy_next_upstream \
       \(keys given without the \"proxy_\" prefix, which gets added automatically)" $ do
      l <- decodeOrFail
             (object
               [ "path" .= ("/legacy" :: Text)
               , "proxy_pass" .= ("https://backend" :: Text)
               , "proxy" .= object
                   [ "http_version" .= ("1.0" :: Text)
                   , "set_header" .= object
                       [ "Connection" .= ("" :: Text)
                       , "X-Real-IP" .= ("$remote_addr" :: Text)
                       ]
                   , "next_upstream" .= (["error", "timeout", "http_502", "non_idempotent"] :: [Text])
                   , "next_upstream_tries" .= (5 :: Int)
                   , "next_upstream_timeout" .= ("15s" :: Text)
                   ]
               ])
             :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "legacy" })
      rendered `shouldContainAll`
        [ "proxy_pass https://backend;"  -- scheme comes from the JSON value, not hardcoded
        , "proxy_http_version 1.0;"
        , "proxy_set_header Connection \"\";"
        , "proxy_set_header X-Real-IP \"$remote_addr\";"
        , "proxy_next_upstream error timeout http_502 non_idempotent;"
        , "proxy_next_upstream_tries 5;"
        , "proxy_next_upstream_timeout 15s;"
        ]

    it "does not render proxy_http_version/proxy_set_header on a non-proxying location" $ do
      l <- decodeOrFail healthJson :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "health" })
      rendered `shouldSatisfy` (not . ("proxy_http_version" `T.isInfixOf`))

    it "renders a CORS-preflight conditional_response: shared headers via Location.extra_headers \
       \(relying on nginx's own add_header inheritance into an empty \"if\"), branch-only \
       \headers via ConditionalResponse.extra_headers" $ do
      l <- decodeOrFail
             (object
               [ "path" .= ("/bar" :: Text)
               , "proxy_pass" .= ("http://backend" :: Text)
               , "extra_headers" .=
                   ([ ["Access-Control-Allow-Origin", "*"]
                    , ["Access-Control-Allow-Methods", "GET, POST"]
                    ] :: [[Text]])
               , "conditional_responses" .=
                   [ object
                       [ "condition" .= ("$request_method = 'OPTIONS'" :: Text)
                       , "extra_headers" .=
                           ([ ["Content-Length", "0"]
                            , ["Content-Type", "text/plain"]
                            ] :: [[Text]])
                       , "rewrite_directives" .=
                           [ object [ "type" .= ("return" :: Text), "code" .= (200 :: Int) ] ]
                       ]
                   ]
               ])
             :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "bar" })
      rendered `shouldContainAll`
        [ "if ($request_method = 'OPTIONS') {"
        , "add_header Content-Length \"0\" always;"
        , "add_header Content-Type \"text/plain\" always;"
        , "return 200;"
        , "}"
        -- shared CORS headers, rendered once at the location level - nginx inherits them
        -- into the "if" above since that block declares no add_header of its own
        , "add_header Access-Control-Allow-Origin \"*\" always;"
        , "add_header Access-Control-Allow-Methods \"GET, POST\" always;"
        ]

    it "renders a location-level resolver (ngx_http_core_module allows this context)" $ do
      l <- decodeOrFail
             (object
               [ "path" .= ("/dynamic" :: Text)
               , "proxy_pass" .= ("http://backend" :: Text)
               , "resolver" .= object
                   [ "address" .= ("127.0.0.1:53" :: Text)
                   , "valid" .= ("5s" :: Text)
                   , "ipv6" .= ("on" :: Text)
                   ]
               ])
             :: IO Location
      let rendered = toNginxConf ((l :: Location) { name = "dynamic" })
      rendered `shouldContainAll` [ "location /dynamic {" ]
      -- parameters render as an unordered map, so check the token set rather
      -- than one fixed-order string
      directiveTokens "resolver 127.0.0.1:53" rendered
        `shouldMatchList` [ "resolver", "127.0.0.1:53", "valid=5s", "ipv6=on" ]

  describe "Server" $ do
    it "renders the full foo server block from its parsed parts" $ do
      cfg <- decodeOrFail serverConfigJson :: IO ServerConfig
      up <- decodeOrFail upstreamJson :: IO Upstream
      health <- decodeOrFail healthJson :: IO Location
      catchall <- decodeOrFail catchallJson :: IO Location
      bar <- decodeOrFail barJson :: IO Location
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = [ (up :: Upstream) { name = "backend" } ]
            , locations =
                [ (health :: Location) { name = "health" }
                , (catchall :: Location) { name = "catchall" }
                , (bar :: Location) { name = "bar" }
                ]
            }
          rendered = toNginxConf server
      rendered `shouldContainAll`
        [ "upstream backend {"
        , "server {"
        , "listen 0.0.0.0:443 ssl;"
        , "server_name foo;"
        , "http2 on;"
        , "ssl_certificate /var/lib/nginx-tls/backend.pem;"
        , "ssl_certificate_key /var/lib/nginx-tls/backend.pem;"
        , "add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always;"
        , "proxy_set_header X-Forwarded-Port 443;"
        , "location /health {"
        , "location ^~ / {"
        , "location ^~ /bar {"
        ]

    it "renders multiple server_name values space-separated on one directive" $ do
      cfg <- decodeOrFail
               (object
                 [ "server_name" .= (["foo", "www.foo", "*.foo.example"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 ])
               :: IO ServerConfig
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = []
            , locations = []
            }
      toNginxConf server `shouldContainAll` [ "server_name foo www.foo *.foo.example;" ]

    it "renders a server-level resolver (ngx_http_core_module allows this context)" $ do
      cfg <- decodeOrFail
               (object
                 [ "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "resolver" .= object [ "address" .= ("10.0.0.2:53" :: Text) ]
                 ])
               :: IO ServerConfig
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = []
            , locations = []
            }
      toNginxConf server `shouldContainAll` [ "resolver 10.0.0.2:53 ipv6=off;" ]

    it "renders extra_directives verbatim, including a directive given more than once" $ do
      cfg <- decodeOrFail
               (object
                 [ "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "extra_directives" .=
                     ([ ["client_max_body_size", "10m"]
                      , ["error_page", "404 /404.html"]
                      , ["error_page", "500 502 503 504 /50x.html"]
                      ] :: [[Text]])
                 ])
               :: IO ServerConfig
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = []
            , locations = []
            }
      toNginxConf server `shouldContainAll`
        [ "client_max_body_size 10m;"
        , "error_page 404 /404.html;"
        , "error_page 500 502 503 504 /50x.html;"
        ]

    it "renders a server-level (site-wide) proxy block (keys given with the \"proxy_\" prefix already present)" $ do
      cfg <- decodeOrFail
               (object
                 [ "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "proxy" .= object
                     [ "proxy_next_upstream" .= (["error", "http_502"] :: [Text])
                     , "proxy_next_upstream_tries" .= (3 :: Int)
                     ]
                 ])
               :: IO ServerConfig
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = []
            , locations = []
            }
      let rendered = toNginxConf server
      rendered `shouldContainAll`
        [ "proxy_next_upstream error http_502;"
        , "proxy_next_upstream_tries 3;"
        ]
      -- unset proxy params (http_version, next_upstream_timeout) are simply
      -- omitted, leaving nginx's own built-in defaults in effect
      rendered `shouldNotContainAny` [ "proxy_http_version", "proxy_next_upstream_timeout" ]

    it "renders ordered rewrite/rewrite/return directives (ngx_http_rewrite_module's own docs example)" $ do
      cfg <- decodeOrFail
               (object
                 [ "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "rewrite_directives" .=
                     [ object
                         [ "type" .= ("rewrite" :: Text)
                         , "regex" .= ("^(/download/.*)/media/(.*)\\..*$" :: Text)
                         , "replacement" .= ("$1/mp3/$2.mp3" :: Text)
                         , "flag" .= ("last" :: Text)
                         ]
                     , object
                         [ "type" .= ("rewrite" :: Text)
                         , "regex" .= ("^(/download/.*)/audio/(.*)\\..*$" :: Text)
                         , "replacement" .= ("$1/mp3/$2.ra" :: Text)
                         , "flag" .= ("last" :: Text)
                         ]
                     , object [ "type" .= ("return" :: Text), "code" .= (403 :: Int) ]
                     ]
                 ])
               :: IO ServerConfig
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = []
            , locations = []
            }
          rendered = toNginxConf server
      rendered `shouldContainAll`
        [ "rewrite ^(/download/.*)/media/(.*)\\..*$ $1/mp3/$2.mp3 last;"
        , "rewrite ^(/download/.*)/audio/(.*)\\..*$ $1/mp3/$2.ra last;"
        , "return 403;"
        ]
      -- order matters: media rewrite, then audio rewrite, then the return fallback
      let indexOf needle haystack = T.length (fst (T.breakOn needle haystack))
          mediaPos  = indexOf "media" rendered
          audioPos  = indexOf "audio" rendered
          returnPos = indexOf "return 403;" rendered
      (mediaPos < audioPos && audioPos < returnPos) `shouldBe` True

    it "renders break as a bare directive" $ do
      cfg <- decodeOrFail
               (object
                 [ "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "rewrite_directives" .= [ object [ "type" .= ("break" :: Text) ] ]
                 ])
               :: IO ServerConfig
      let server = Server
            { config = (cfg :: ServerConfig) { name = "foo" }
            , upstreams = []
            , locations = []
            }
      toNginxConf server `shouldContainAll` [ "break;" ]

  describe "FromJSON failure modes" $ do
    it "rejects a location JSON missing the required \"path\" field" $ do
      case (parseEither parseJSON (object [ "match" .= ("prefix" :: Text) ]) :: Either String Location) of
        Left _  -> pure ()
        Right v -> expectationFailure ("expected a parse failure, got: " <> show v)

    it "rejects an upstream JSON missing the required \"servers\" field" $ do
      case (parseEither parseJSON (object [ "keepalive" .= (512 :: Int) ]) :: Either String Upstream) of
        Left _  -> pure ()
        Right v -> expectationFailure ("expected a parse failure, got: " <> show v)

    it "rejects an UpstreamServer parameter whose value isn't a bool/number/string" $ do
      case (parseEither parseJSON
              (object
                [ "address" .= ("x:80" :: Text)
                , "parameters" .= object [ "weight" .= ([1, 2] :: [Int]) ]
                ])
              :: Either String UpstreamServer) of
        Left _  -> pure ()
        Right v -> expectationFailure ("expected a parse failure, got: " <> show v)

    it "rejects a KVEntry JSON with no \"Value\"" $ do
      case (parseEither parseJSON (object [ "Key" .= ("servers/foo/config" :: Text) ])
              :: Either String KVEntry) of
        Left err -> err `shouldSatisfy` ("has no value" `isInfixOf`)
        Right v  -> expectationFailure ("expected a parse failure, got: " <> show v)

    it "rejects a KVEntry JSON whose \"Value\" isn't valid base64" $ do
      case (parseEither parseJSON
              (object
                [ "Key" .= ("servers/foo/config" :: Text)
                , "Value" .= ("not-valid-base64!!!" :: Text)
                ])
              :: Either String KVEntry) of
        Left err -> err `shouldSatisfy` ("invalid base64" `isInfixOf`)
        Right v  -> expectationFailure ("expected a parse failure, got: " <> show v)

    it "rejects a KVEntry JSON whose \"Value\" doesn't decode to a JSON object" $ do
      -- base64 of "\"just a string\"" - valid base64, valid JSON, not an object
      case (parseEither parseJSON
              (object
                [ "Key" .= ("servers/foo/config" :: Text)
                , "Value" .= ("Imp1c3QgYSBzdHJpbmci" :: Text)
                ])
              :: Either String KVEntry) of
        Left _  -> pure ()
        Right v -> expectationFailure ("expected a parse failure, got: " <> show v)

  describe "Grouping (assembleServersFromKv, as Consul's KV API would return it)" $ do
    it "reassembles the foo server from its five KV entries with no warnings" $ do
      let prefix = "nginx/conf/servers/"
          entries =
            [ kvEntry "nginx/conf/servers/foo/config" serverConfigJson
            , kvEntry "nginx/conf/servers/foo/upstreams/backend/config" upstreamJson
            , kvEntry "nginx/conf/servers/foo/locations/health/config" healthJson
            , kvEntry "nginx/conf/servers/foo/locations/catchall/config" catchallJson
            , kvEntry "nginx/conf/servers/foo/locations/bar/config" barJson
            ]
          (warnings, servers) = assembleServersFromKv prefix entries
      warnings `shouldBe` []
      length servers `shouldBe` 1
      let rendered = toNginxConf (head servers)
      rendered `shouldContainAll`
        [ "upstream backend {"
        , "server {"
        , "listen 0.0.0.0:443 ssl;"
        , "server_name foo;"
        , "location /health {"
        , "location ^~ / {"
        , "location ^~ /bar {"
        ]

    it "warns and drops an unrecognized key shape but still assembles the rest" $ do
      let prefix = "nginx/conf/servers/"
          entries =
            [ kvEntry "nginx/conf/servers/foo/config" serverConfigJson
            , kvEntry "nginx/conf/servers/foo/bogus" (object [])
            ]
          (warnings, servers) = assembleServersFromKv prefix entries
      length servers `shouldBe` 1
      T.concat warnings `shouldSatisfy` ("ignoring unrecognized key shape" `T.isInfixOf`)

    it "warns and skips a server with locations but no servers/$name/config key" $ do
      let prefix = "nginx/conf/servers/"
          entries = [ kvEntry "nginx/conf/servers/orphan/locations/health/config" healthJson ]
          (warnings, servers) = assembleServersFromKv prefix entries
      length servers `shouldBe` 0
      T.concat warnings `shouldSatisfy` ("no servers/orphan/config key found" `T.isInfixOf`)

  describe "decodeKvEntries" $ do
    it "keeps entries that decode and warns-and-drops the rest, without losing the rest of the batch" $ do
      let values =
            [ object [ "Key" .= ("servers/foo/config" :: Text) ]                                      -- no value
            , object [ "Key" .= ("bad-base64" :: Text), "Value" .= ("not-valid-base64!!!" :: Text) ]  -- invalid base64
            , object [ "Key" .= ("not-an-object" :: Text), "Value" .= ("Imp1c3QgYSBzdHJpbmci" :: Text) ] -- not a JSON object
            , object [ "Key" .= ("servers/foo/config" :: Text), "Value" .= T.pack serverConfigB64 ]
            ]
          (warnings, entries) = decodeKvEntries values
      length entries `shouldBe` 1
      length warnings `shouldBe` 3

-- ===================== worked-example fixtures =====================
-- These mirror servers/foo/{config,upstreams/backend/config,
-- locations/{health,catchall,bar}/config} as this design expects them
-- to be stored in Consul KV, built here as aeson 'Value's rather than
-- stringified JSON. All keys are snake_case, matching nginx's own
-- documented directive/parameter names.

serverConfigJson :: Value
serverConfigJson = object
  [ "server_name" .= (["foo"] :: [Text])
  , "listen" .= [ object [ "port" .= (443 :: Int), "ssl" .= True ] ]
  , "http2" .= True
  , "tls_cert_path" .= ("/var/lib/nginx-tls/backend.pem" :: Text)
  , "extra_directives" .=
      ([ ["add_header", "Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always"]
       ] :: [[Text]])
  ]

serverConfigB64 :: String
serverConfigB64 = LBS8.unpack (B64L.encode (encode serverConfigJson))

upstreamJson :: Value
upstreamJson = object
  [ "resolver" .= object
      [ "address" .= ("dns-server-1:8600" :: Text)
      , "valid" .= ("10s" :: Text)
      ]
  , "servers" .=
      [ object
          [ "address" .= ("backend.service.consul:8080" :: Text)
          , "parameters" .= object
              [ "resolve" .= True
              , "max_fails" .= (2 :: Int)
              , "fail_timeout" .= ("60s" :: Text)
              ]
          ]
      ]
  , "keepalive" .= (512 :: Int)
  , "keepalive_requests" .= (10000 :: Int)
  , "keepalive_timeout" .= ("30s" :: Text)
  , "zone_size" .= ("2m" :: Text)
  ]

healthJson :: Value
healthJson = object
  [ "path" .= ("/health" :: Text)
  , "match" .= ("prefix" :: Text)
  , "rewrite_directives" .=
      [ object [ "type" .= ("return" :: Text), "code" .= (200 :: Int), "value" .= ("ok" :: Text) ] ]
  , "access_log" .= False
  ]

catchallJson :: Value
catchallJson = object
  [ "path" .= ("/" :: Text)
  , "match" .= ("prefix_exact" :: Text)
  , "rewrite_directives" .=
      [ object [ "type" .= ("return" :: Text), "code" .= (404 :: Int), "value" .= ("unavailable" :: Text) ] ]
  ]

barJson :: Value
barJson = object
  [ "path" .= ("/bar" :: Text)
  , "match" .= ("prefix_exact" :: Text)
  , "proxy_pass" .= ("http://backend" :: Text)
  , "extra_includes" .= (["/etc/nginx/backend-common.conf"] :: [Text])
  ]

-- ===================== helpers =====================

decodeOrFail :: FromJSON a => Value -> IO a
decodeOrFail v = case parseEither parseJSON v of
  Left err -> fail ("JSON decode failed: " <> err <> "\n  input: " <> show v)
  Right x  -> pure x

shouldContainAll :: Text -> [Text] -> Expectation
shouldContainAll haystack = mapM_ (\needle -> haystack `shouldSatisfy` (needle `T.isInfixOf`))

shouldNotContainAny :: Text -> [Text] -> Expectation
shouldNotContainAny haystack = mapM_ (\needle -> haystack `shouldNotSatisfy` (needle `T.isInfixOf`))

-- | Extract the whitespace-separated tokens of the one rendered line
-- starting with the given prefix (e.g. "server <address>"), stripping the
-- trailing ";" - for checking a directive's parameters as a token set
-- rather than one fixed-order string, since these render from an unordered
-- map.
directiveTokens :: Text -> Text -> [Text]
directiveTokens prefix rendered =
  case filter (prefix `T.isPrefixOf`) (map T.strip (T.lines rendered)) of
    (line : _) -> T.words (T.dropEnd 1 line)
    []         -> []

-- | Build a KVEntry from a fixture 'Value' that's already an object - the
-- shape assembleServersFromKv now receives, skipping the base64 round-trip
-- that FromJSON KVEntry's own "Value" field goes through in the real
-- pipeline (see the "rejects a KVEntry JSON whose \"Value\" isn't valid
-- base64" test above for that).
kvEntry :: Text -> Value -> KVEntry
kvEntry key body = case body of
  Object obj -> KVEntry key obj
  _          -> error "kvEntry: not a JSON object"
