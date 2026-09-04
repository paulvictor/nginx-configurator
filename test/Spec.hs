{-# LANGUAGE OverloadedStrings #-}

-- Worked-example unit tests for Types.hs and Grouping.hs, run against the
-- backend's current routes expressed as the servers/$server and
-- upstreams/$upstream JSON documents this design expects from Consul KV,
-- built as aeson 'Value's via 'object'/'.=' (which construct their
-- underlying KeyMap via 'KM.fromList') rather than as raw JSON text.
module Main where

import Control.Lens (at, set, (&), (?~))
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), encode, object, (.=))
import Data.Aeson.Lens (_Object)
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
      let rendered = toNginxConf (set name "backend" u)
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
        `shouldMatchList` [ "resolver", "dns-server-1:8600", "valid=10s" ]
      directiveTokens "server backend.service.consul:8080" rendered
        `shouldMatchList` [ "server", "backend.service.consul:8080"
                          , "weight=1", "resolve", "max_fails=2", "fail_timeout=60s" ]

    it "renders weight, backup and slow_start when set" $ do
      u <- decodeOrFail
             (object
               [ "name" .= ("unnamed" :: Text)
               , "servers" .=
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
      let rendered = toNginxConf (set name "weighted" u)
      directiveTokens "server backend.service.consul:8080" rendered
        `shouldMatchList` [ "server", "backend.service.consul:8080", "weight=5"
                          , "max_fails=3", "fail_timeout=10s", "backup", "slow_start=30s" ]

    it "defaults maxFails to 3 and failTimeout to 10s when omitted" $ do
      u <- decodeOrFail
             (object
               [ "name" .= ("unnamed" :: Text)
               , "servers" .= [ object [ "address" .= ("backend.service.consul:8080" :: Text) ] ]
               ])
             :: IO Upstream
      let rendered = toNginxConf (set name "minimal" u)
      directiveTokens "server backend.service.consul:8080" rendered
        `shouldMatchList` [ "server", "backend.service.consul:8080", "weight=1"
                          , "max_fails=3", "fail_timeout=10s" ]

  describe "Location" $ do
    it "renders the /health static check with access_log off" $ do
      l <- decodeOrFail healthJson :: IO Location
      let rendered = toNginxConf l
      rendered `shouldContainAll`
        [ "location /health {"
        , "return 200 ok;"
        , "access_log off;"
        ]

    it "renders the ^~ / catch-all 404" $ do
      l <- decodeOrFail catchallJson :: IO Location
      let rendered = toNginxConf l
      rendered `shouldContainAll`
        [ "location ^~ / {"
        , "return 404 unavailable;"
        ]

    it "renders a proxying location with its extra includes" $ do
      l <- decodeOrFail barJson :: IO Location
      let rendered = toNginxConf l
      rendered `shouldContainAll`
        [ "location ^~ /bar {"
        , "proxy_pass http://backend;"
        , "include /etc/nginx/backend-common.conf;"
        ]

    it "renders no proxy_* directives at all when \"proxy\" is unset, leaving nginx's own defaults in effect" $ do
      l <- decodeOrFail barJson :: IO Location
      let rendered = toNginxConf l
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
      let rendered = toNginxConf l
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
      let rendered = toNginxConf l
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
      let rendered = toNginxConf l
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
      let rendered = toNginxConf l
      rendered `shouldContainAll` [ "location /dynamic {" ]
      -- parameters render as an unordered map, so check the token set rather
      -- than one fixed-order string
      directiveTokens "resolver 127.0.0.1:53" rendered
        `shouldMatchList` [ "resolver", "127.0.0.1:53", "valid=5s", "ipv6=on" ]

  describe "Server" $ do
    it "renders the full foo server block from its parsed parts" $ do
      server <- decodeOrFail
                  (serverConfigJson & _Object . at "locations" ?~ object
                    [ "health"   .= healthJson
                    , "catchall" .= catchallJson
                    , "bar"      .= barJson
                    ])
                :: IO Server
      let rendered = toNginxConf (set name "foo" server)
      rendered `shouldContainAll`
        [ "server {"
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
      server <- decodeOrFail
               (object
                 [ "name" .= ("unnamed" :: Text)
                 , "server_name" .= (["foo", "www.foo", "*.foo.example"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 ])
               :: IO Server
      toNginxConf (set name "foo" server) `shouldContainAll` [ "server_name foo www.foo *.foo.example;" ]

    it "renders a server-level resolver (ngx_http_core_module allows this context)" $ do
      server <- decodeOrFail
               (object
                 [ "name" .= ("unnamed" :: Text)
                 , "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "resolver" .= object [ "address" .= ("10.0.0.2:53" :: Text) ]
                 ])
               :: IO Server
      toNginxConf (set name "foo" server) `shouldContainAll` [ "resolver 10.0.0.2:53;" ]

    it "renders extra_directives verbatim, including a directive given more than once" $ do
      server <- decodeOrFail
               (object
                 [ "name" .= ("unnamed" :: Text)
                 , "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "extra_directives" .=
                     ([ ["client_max_body_size", "10m"]
                      , ["error_page", "404 /404.html"]
                      , ["error_page", "500 502 503 504 /50x.html"]
                      ] :: [[Text]])
                 ])
               :: IO Server
      toNginxConf (set name "foo" server) `shouldContainAll`
        [ "client_max_body_size 10m;"
        , "error_page 404 /404.html;"
        , "error_page 500 502 503 504 /50x.html;"
        ]

    it "renders a server-level (site-wide) proxy block (keys given with the \"proxy_\" prefix already present)" $ do
      server <- decodeOrFail
               (object
                 [ "name" .= ("unnamed" :: Text)
                 , "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "proxy" .= object
                     [ "proxy_next_upstream" .= (["error", "http_502"] :: [Text])
                     , "proxy_next_upstream_tries" .= (3 :: Int)
                     ]
                 ])
               :: IO Server
      let rendered = toNginxConf (set name "foo" server)
      rendered `shouldContainAll`
        [ "proxy_next_upstream error http_502;"
        , "proxy_next_upstream_tries 3;"
        ]
      -- unset proxy params (http_version, next_upstream_timeout) are simply
      -- omitted, leaving nginx's own built-in defaults in effect
      rendered `shouldNotContainAny` [ "proxy_http_version", "proxy_next_upstream_timeout" ]

    it "renders ordered rewrite/rewrite/return directives (ngx_http_rewrite_module's own docs example)" $ do
      server <- decodeOrFail
               (object
                 [ "name" .= ("unnamed" :: Text)
                 , "server_name" .= (["foo"] :: [Text])
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
               :: IO Server
      let rendered = toNginxConf (set name "foo" server)
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
      server <- decodeOrFail
               (object
                 [ "name" .= ("unnamed" :: Text)
                 , "server_name" .= (["foo"] :: [Text])
                 , "listen" .= [ object [ "port" .= (443 :: Int) ] ]
                 , "rewrite_directives" .= [ object [ "type" .= ("break" :: Text) ] ]
                 ])
               :: IO Server
      toNginxConf (set name "foo" server) `shouldContainAll` [ "break;" ]

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

    it "rejects an Entity JSON with no \"Value\"" $ do
      case (parseEither parseJSON (object [ "Key" .= ("servers/foo" :: Text) ])
              :: Either String Entity) of
        Left err -> err `shouldSatisfy` ("has no value" `isInfixOf`)
        Right _  -> expectationFailure "expected a parse failure"

    it "rejects an Entity JSON whose \"Value\" isn't valid base64" $ do
      case (parseEither parseJSON
              (object
                [ "Key" .= ("servers/foo" :: Text)
                , "Value" .= ("not-valid-base64!!!" :: Text)
                ])
              :: Either String Entity) of
        Left err -> err `shouldSatisfy` ("invalid base64" `isInfixOf`)
        Right _  -> expectationFailure "expected a parse failure"

    it "rejects an Entity JSON whose \"Value\" doesn't decode to a JSON object" $ do
      -- base64 of "\"just a string\"" - valid base64, valid JSON, not an object
      case (parseEither parseJSON
              (object
                [ "Key" .= ("servers/foo" :: Text)
                , "Value" .= ("Imp1c3QgYSBzdHJpbmci" :: Text)
                ])
              :: Either String Entity) of
        Left _  -> pure ()
        Right v -> expectationFailure ("expected a parse failure, got: " <> show v)

  describe "Entity (FromJSON, decoding straight from a raw Consul KV array element)" $ do
    it "decodes a server (with its nested locations) and an upstream from their own KV entries" $ do
      let serverBody = serverConfigJson & _Object . at "locations" ?~ object
            [ "health"   .= healthJson
            , "catchall" .= catchallJson
            , "bar"      .= barJson
            ]
          rawEntries =
            [ consulEntry "nginx/conf/servers/foo" serverBody
            , consulEntry "nginx/conf/upstreams/backend" upstreamJson
            ]
      case parseEither parseJSON (toJSON rawEntries) :: Either String [Entity] of
        Left err -> expectationFailure ("expected success, got: " <> err)
        Right entities -> do
          let (servers, upstreams) = partitionEntities entities
          length servers `shouldBe` 1
          length upstreams `shouldBe` 1
          let rendered = toNginxConf (head servers)
          rendered `shouldContainAll`
            [ "server {"
            , "listen 0.0.0.0:443 ssl;"
            , "server_name foo;"
            , "location /health {"
            , "location ^~ / {"
            , "location ^~ /bar {"
            ]
          toNginxConf (head upstreams) `shouldContainAll` [ "upstream backend {" ]

    it "fails on an unrecognized key shape, even alongside an otherwise-valid entry" $ do
      let rawEntries =
            [ consulEntry "nginx/conf/servers/foo" serverConfigJson
            , consulEntry "nginx/conf/servers/foo/bogus" (object [])
            ]
      case parseEither parseJSON (toJSON rawEntries) :: Either String [Entity] of
        Left err -> err `shouldSatisfy` ("unrecognized key shape" `isInfixOf`)
        Right _  -> expectationFailure "expected a failure for the unrecognized key shape"

    it "fails on a server entry whose JSON body has no \"listen\" key" $ do
      let rawEntries = [ consulEntry "nginx/conf/servers/orphan" (object [ "server_name" .= (["orphan"] :: [Text]) ]) ]
      case parseEither parseJSON (toJSON rawEntries) :: Either String [Entity] of
        Left err -> err `shouldSatisfy` ("key \"listen\" not found" `isInfixOf`)
        Right _  -> expectationFailure "expected a failure for the missing \"listen\" key"

-- ===================== worked-example fixtures =====================
-- These mirror servers/foo and upstreams/backend as this design expects
-- them to be stored in Consul KV - a server's own fields (server_name,
-- listen, ...) live flat alongside its "locations", no "config" wrapper -
-- built here as aeson 'Value's rather than stringified JSON. All keys are
-- snake_case, matching nginx's own documented directive/parameter names.

-- | "name" is required by Server's/Upstream's FromJSON instances
-- (Grouping.hs injects the real one from the KV key before parsing - see
-- there); Location has no "name" field at all, nothing ever reads one.
-- These fixtures need *a* value here even though every test overwrites it
-- via "set name ..." right after decoding; "unnamed" is a deliberately
-- obvious placeholder for that.
serverConfigJson :: Value
serverConfigJson = object
  [ "name" .= ("unnamed" :: Text)
  , "server_name" .= (["foo"] :: [Text])
  , "listen" .= [ object [ "port" .= (443 :: Int), "ssl" .= True ] ]
  , "http2" .= True
  , "tls_cert_path" .= ("/var/lib/nginx-tls/backend.pem" :: Text)
  , "extra_directives" .=
      ([ ["add_header", "Strict-Transport-Security \"max-age=31536000; includeSubDomains\" always"]
       ] :: [[Text]])
  ]

upstreamJson :: Value
upstreamJson = object
  [ "name" .= ("unnamed" :: Text)
  , "resolver" .= object
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
  case filter (prefix `T.isPrefixOf`) (T.strip <$> T.lines rendered) of
    (line : _) -> T.words (T.dropEnd 1 line)
    []         -> []

-- | Builds one raw Consul KV array element - the exact shape 'Entity's own
-- FromJSON decodes directly, base64 round-trip included (unlike the
-- malformed-envelope fixtures above, which build their own "Value" text
-- by hand specifically to exercise that round-trip's failure modes).
consulEntry :: Text -> Value -> Value
consulEntry key body = object
  [ "Key" .= key
  , "Value" .= T.pack (LBS8.unpack (B64L.encode (encode body)))
  ]
