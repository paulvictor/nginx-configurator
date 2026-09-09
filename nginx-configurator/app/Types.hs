{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}

module Types where

import Control.Lens
import Data.Aeson
import Data.Aeson.Lens (_Bool, _Number, _String, key)
import qualified Data.Aeson.Key as Key
import Data.Aeson.KeyMap (KeyMap)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import Data.Char (toLower)
import Data.Default.Class (Default (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data Named a = Named
  { _name   :: Text
  , _config :: a
  } deriving (Show, Generic)

makeFieldsNoPrefix ''Named

checkIsRawValue :: Key -> Value -> Parser ()
checkIsRawValue k v =
  if has (_Bool.united `failing` _Number.united `failing` _String.united) v
  then pure ()
  else fail ("parameter \"" <> Key.toString k <> "\" must be a bool, number, or string")

-- ===================== Resolver =====================

-- | nginx's own docs: "resolver address ... [valid=time] [ipv6=on|off]
-- [status_zone=zone];" - valid in http, server, and location
-- (ngx_http_core_module), and with the same shape inside upstream blocks
-- (ngx_http_upstream_module, paired with the "resolve" parameter on a
-- server directive). http-level stays out of scope (still static,
-- Nix-managed, per the earlier design) - only server/location/upstream.
--
-- "address" is required and positional in nginx's syntax (a bare value,
-- not a key=value parameter like the rest), so it's a mandatory field
-- here rather than folded into the generic map - same shape as
-- UpstreamServer's own "address" + "parameters" split above. Everything
-- else (valid, ipv6, status_zone, ...) renders via the shared key/value
-- helpers. JSON keys are nginx's own parameter names (snake_case, matching
-- nginx's own documentation), same convention as Proxy and
-- UpstreamServer's parameters.
data Resolver = Resolver
  { _address    :: Text
  , _parameters :: KeyMap Value
  } deriving (Show, Generic)

makeFieldsNoPrefix ''Resolver

instance FromJSON Resolver where
  parseJSON = withObject "Resolver" $ \o -> do
    addr <- o .: "address"
    let rest = KM.delete "address" o
    itraverse_ checkIsRawValue rest
    pure (Resolver addr rest)

-- ===================== Proxy =====================

-- | The ngx_http_proxy_module directives valid in both server and location
-- contexts (proxy_pass itself is location-only - context: location, if in
-- location, limit_except - so it stays a plain field on Location, not part
-- of this shared bundle). JSON keys are nginx's own directive names
-- (snake_case), with the "proxy_" prefix added automatically when absent
-- (so both "http_version" and "proxy_http_version" work). "next_upstream"
-- and "set_header" get their own typed fields because nginx's own syntax
-- for each doesn't fit the generic "key value;" shape everything else
-- renders as (next_upstream is nginx's one proxy directive taking multiple
-- space-separated tokens; set_header is a name->value map, rendered as one
-- line per entry) - everything else stays a raw name/Value map, same
-- reasoning as UpstreamServer's/Resolver's own raw parameters: a directive
-- we haven't explicitly modeled doesn't need a code change. None of the
-- three fields is Maybe - an absent "proxy" key parses to 'def', and any
-- directive left empty here is simply omitted from the rendered config,
-- letting nginx fall back to its own built-in default (proxy_http_version,
-- proxy_next_upstream etc. all have one) rather than this code keeping its
-- own copy in sync.
data ProxyParameters = ProxyParameters
  { _rawParams    :: KeyMap Value  -- everything but next_upstream/set_header;
                                   -- keys already carry their "proxy_" prefix
  , _nextUpstream :: [Text]        -- proxy_next_upstream's space-separated tokens
  , _setHeader    :: KeyMap Text   -- proxy_set_header's name->value pairs
  } deriving (Show, Generic)

makeLenses ''ProxyParameters

instance Default ProxyParameters where
  def = ProxyParameters KM.empty [] KM.empty

-- | Only called (via "parseOptionalProxy" below) when a "proxy" key is
-- actually present - an absent key short-circuits to 'def' without ever
-- reaching here.
parseProxyParams :: Object -> Parser ProxyParameters
parseProxyParams given = do
  let normalized = KM.mapKeyVal normalizeKey id given
  nextUp <- case Object normalized ^? key "proxy_next_upstream" of
    Nothing -> pure []
    Just v  -> parseJSON v
  headers <- case Object normalized ^? key "proxy_set_header" of
    Nothing          -> pure KM.empty
    Just (Object hs) -> traverse expectHeaderString hs
    Just _           -> fail "proxy_set_header must be an object of header name/value pairs"
  let raw = KM.delete "proxy_set_header" (KM.delete "proxy_next_upstream" normalized)
  itraverse_ checkRawProxyParam raw
  pure (ProxyParameters raw nextUp headers)
  where
    normalizeKey k =
      if "proxy_" `T.isPrefixOf` Key.toText k
      then k
      else Key.fromText ("proxy_" <> Key.toText k)

    expectHeaderString v = maybe (fail "proxy_set_header values must be strings") pure (v ^? _String)

    checkRawProxyParam :: Key -> Value -> Parser ()
    checkRawProxyParam k v =
      if has (_String.united `failing` _Number.united) v
      then pure ()
      else fail ("proxy parameter \"" <> Key.toString k <> "\" must be a string or number")

-- | Parses an optional "proxy" object field, defaulting to 'def' when the
-- key is absent. Shared by Location's and ServerConfig's FromJSON
-- instances.
parseOptionalProxy :: Object -> Parser ProxyParameters
parseOptionalProxy o = o .:? "proxy" >>= maybe (pure def) parseProxyParams

-- ===================== Upstream =====================

-- | nginx's own docs shape the "server" directive inside upstream as
-- "server address [parameters];" - address separate from a bag of
-- optional parameters. Kept as a raw name/Value map rather than individual
-- typed fields: JSON keys are literally nginx's own parameter names (e.g.
-- "max_fails", "fail_timeout"), so there's no camelCase<->snake_case
-- translation to get wrong, and adding a parameter nginx supports that we
-- haven't explicitly modeled doesn't need a code change. FromJSON (below,
-- inline in UpstreamServer's own instance) merges whatever Consul provides
-- over these nginx-matching defaults, so an absent key just falls back to
-- its default rather than needing to be repeated in every KV entry.

-- | "address" mirrors nginx's own documented name for the "server"
-- directive's first (positional) argument - "server address [parameters];" -
-- and matches Resolver's own use of the same word for the same idea (a
-- host to reach), even though the two are unrelated mechanisms (one a
-- real record field, the other a KeyMap key). Bare field names +
-- `makeFieldsNoPrefix` here join the same `HasAddress`/`HasParameters`
-- classes Resolver's own bare fields already established - what unifies
-- them is the derived name ("address"/"parameters"), not which type
-- declared it. Requires `DuplicateRecordFields` (Resolver also has
-- literal `_address`/`_parameters`) + `NoFieldSelectors` (so the raw
-- fields never become ambiguous accessor functions - only the generated
-- lenses are ever used).
data UpstreamServer = UpstreamServer
  { _address    :: Text  -- "log-processor-backend.service.consul:8080"
  , _parameters :: KeyMap Value
  } deriving (Show, Generic)

makeFieldsNoPrefix ''UpstreamServer

instance FromJSON UpstreamServer where
  parseJSON = withObject "UpstreamServer" $ \o -> do
    given <- o .:? "parameters" .!= KM.empty
    itraverse_ checkIsRawValue given
    UpstreamServer
      <$> o .: "address"
      <*> pure (KM.union given defaultUpstreamServerParams)
    where
      defaultUpstreamServerParams = KM.fromList
        [ ("weight", Number 1)
        , ("resolve", Bool False)
        , ("max_fails", Number 3)
        , ("fail_timeout", "10s")
        , ("backup", Bool False)
        ]

-- | `resolver` joins the same `HasResolver` class Location's/
-- ServerConfig's own field of the same name established - what unifies a
-- shared field under one class is the final derived name, not which type
-- declared it. `Upstream` itself is `Named UpstreamConfig` below - its
-- name comes from `Named`, not from a field here.
data UpstreamConfig = UpstreamConfig
  { _resolver          :: Maybe Resolver
  , _servers           :: [UpstreamServer]
  , _keepalive         :: Maybe Int
  , _keepaliveRequests :: Maybe Int
  , _keepaliveTimeout  :: Maybe Text
  , _zoneSize          :: Maybe Text    -- "2m"
  } deriving (Show, Generic)

makeFieldsNoPrefix ''UpstreamConfig

instance FromJSON UpstreamConfig where
  parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = camelTo2 '_' . drop 1 }

type Upstream = Named UpstreamConfig

-- ===================== Location =====================

data MatchType = Exact | PrefixExact | Prefix | Regex | RegexCI
  deriving (Show, Eq, Generic)

instance FromJSON MatchType where
  parseJSON = genericParseJSON defaultOptions { constructorTagModifier = camelTo2 '_' }

-- | The three ngx_http_rewrite_module directives valid in server, location,
-- AND if contexts - and per nginx's own docs, the only ones "100% safe"
-- inside "if". Modeled as an ordered list wherever used (Location,
-- ServerConfig, ConditionalResponse below) because nginx evaluates
-- multiple such directives in the same context in the order they're
-- written - e.g. the rewrite module's own docs example:
--   rewrite ^(/download/.*)/media/(.*)\..*$ $1/mp3/$2.mp3 last;
--   rewrite ^(/download/.*)/audio/(.*)\..*$ $1/mp3/$2.ra  last;
--   return  403;
-- Constructor names (Return/Rewrite/BreakDirective) don't clash with
-- anything: data constructors and lowercase functions are different
-- namespaces, so "Return" doesn't shadow Prelude's "return" the way a
-- field named bare "return" would have (see ConditionalResponse's old
-- "returnCode", now gone - this replaces it, and Location's old
-- "locReturn"/"LocationReturn" too, both fully subsumed by a
-- single-element list here). RewriteModuleDirective's own nullary
-- constructor is "BreakDirective" rather than "Break" so it doesn't
-- clash with RewriteFlag's "Break" just below - two different nginx
-- concepts (the standalone `break;` directive vs. the `rewrite ...
-- break;` flag) that happen to share the same word.
data RewriteFlag = Last | Break | Redirect | Permanent
  deriving (Show, Eq, Generic)

instance FromJSON RewriteFlag where
  parseJSON = genericParseJSON defaultOptions { constructorTagModifier = map toLower }

-- | `code`/`value` only exist on `Return`, and `regex`/`replacement`/`flag`
-- only on `Rewrite` - `makeFieldsNoPrefix` still works across constructors
-- like this, it just generates a `Traversal'` instead of a `Lens'` for a
-- field that isn't present in every constructor (e.g. `value` here is a
-- `Traversal'`, not a `Lens'`, since `BreakDirective` has neither `code`
-- nor `value`). `value` is also shared with AccessRule's field of the
-- same name below.
data RewriteModuleDirective
  = Return { _code :: Int, _value :: Maybe Text }
    -- e.g. {"type":"return","code":403} or
    -- {"type":"return","code":301,"value":"https://example.com"}. The bare
    -- "return URL;" (implicit 302) shorthand isn't modeled - write it
    -- explicitly as code=302 instead, one less Maybe to thread through.
  | Rewrite { _regex :: Text, _replacement :: Text, _flag :: Maybe RewriteFlag }
    -- e.g. {"type":"rewrite","regex":"^/old/(.*)","replacement":"/new/$1","flag":"last"}
  | BreakDirective
    -- {"type":"break"}
  deriving (Show, Generic)

makeFieldsNoPrefix ''RewriteModuleDirective

instance FromJSON RewriteModuleDirective where
  parseJSON = genericParseJSON defaultOptions
    { sumEncoding = TaggedObject { tagFieldName = "type", contentsFieldName = "contents" }
    , constructorTagModifier = tag
    , fieldLabelModifier = drop 1
    }
    where
      tag "BreakDirective" = "break"
      tag other            = map toLower other

-- | ngx_http_access_module's "allow"/"deny" directives - valid in http,
-- server, and location (http-level stays out of scope, same as
-- resolver/proxy above). Modeled as an ordered list: nginx evaluates
-- allow/deny rules in the order they're written and stops at the first
-- match, so an unordered shape (e.g. two separate [Text] fields) would
-- lose that interleaving. "value" is a free-form string (an address, CIDR,
-- "unix:", or the literal "all") - not validated further, same reasoning
-- as Resolver's/UpstreamServer's raw parameters: "nginx -t" is the real
-- validator.
data AccessDirection = Allow | Deny
  deriving (Show, Eq, Generic)

instance FromJSON AccessDirection where
  parseJSON = genericParseJSON defaultOptions { constructorTagModifier = map toLower }

data AccessRule = AccessRule
  { _direction :: AccessDirection
  , _value     :: Text  -- e.g. "10.0.0.0/8", "unix:", or "all"
  } deriving (Show, Generic)

makeFieldsNoPrefix ''AccessRule

instance FromJSON AccessRule where
  parseJSON = withObject "AccessRule" $ \o -> AccessRule
    <$> o .: "type"
    <*> o .: "value"

-- | A narrowly-scoped model of nginx's "if" directive (ngx_http_rewrite_module)
-- inside a location - deliberately NOT a generic escape hatch for arbitrary
-- nginx snippets. nginx's own advice ("if is evil") is that almost nothing
-- is safe inside "if" in a location context except returning a response;
-- this covers exactly that one common, well-understood pattern - reply
-- directly to a specific condition (e.g. a CORS preflight OPTIONS request)
-- with some headers and a status code, without touching the rest of the
-- location's normal behavior.
--
-- IMPORTANT for whoever writes these configs: this extra_headers is NOT
-- the same list as Location's own extra_headers, and the two are not
-- interchangeable:
--   * Location.extra_headers applies to every response from that location,
--     INCLUDING the one generated by this conditional - add_header is
--     inherited into an empty "if" block from the enclosing location (per
--     nginx's own add_header docs: inherited if and only if the current
--     level defines none of its own), so shared headers (e.g. CORS ones)
--     belong there, set once.
--   * This extra_headers is only for headers that must NOT appear on the
--     location's normal (non-matching) response - e.g. Content-Length/
--     Content-Type on a synthetic "return 200" for an OPTIONS preflight,
--     which would be actively wrong if applied to the real proxied
--     response (mismatched Content-Length corrupts HTTP framing; a second
--     Content-Type conflicts with the one the upstream already sends).
data ConditionalResponse = ConditionalResponse
  { _condition         :: Text                    -- raw nginx condition, e.g. "$request_method = 'OPTIONS'"
  , _extraHeaders      :: [(Text, Text)]          -- branch-only add_header pairs - see note above
  , _rewriteDirectives :: [RewriteModuleDirective] -- e.g. a single Return; ordered, see that type's doc
  } deriving (Show, Generic)

makeFieldsNoPrefix ''ConditionalResponse

instance FromJSON ConditionalResponse where
  parseJSON = withObject "ConditionalResponse" $ \o -> ConditionalResponse
    <$> o .:  "condition"
    <*> o .:? "extra_headers" .!= def
    <*> o .:? "rewrite_directives" .!= def

-- | Bare field names + `makeFieldsNoPrefix`: `proxy`/`rewriteDirectives`/
-- `extraHeaders`/`accessRules` join ServerConfig's (and
-- `rewriteDirectives`/`extraHeaders` also unify with
-- ConditionalResponse's own fields the same way) - again, the derived
-- name is what matters, not the source spelling. No `name` field here -
-- unlike `Server`'s/`Upstream`'s own KV-key-derived name (which lives on
-- the shared `Named` wrapper, not on ServerConfig/UpstreamConfig
-- themselves), nothing ever reads a Location's name: it's not rendered
-- (the real, user-visible identity of a location is its `path`), and
-- locations don't get written to their own output file the way
-- servers/upstreams do, so there's nothing downstream to pass it to.
data Location = Location
  { _path                 :: Text                     -- real nginx path, e.g. "/foo/bar"
  , _match                :: MatchType
  , _proxyPass            :: Maybe Text               -- nginx's own full "proxy_pass" target,
                                                       -- scheme included (e.g. "http://backend" or
                                                       -- "https://backend") - not hardcoded to a
                                                       -- scheme here, so a KV entry can point at an
                                                       -- https upstream just as easily.
  , _proxy                :: ProxyParameters          -- proxy_http_version/proxy_set_header/
                                                       -- proxy_next_upstream* - only rendered when
                                                       -- proxy_pass is set. Shared with ServerConfig's
                                                       -- field of the same name; see parseProxyParams.
  , _rewriteDirectives    :: [RewriteModuleDirective] -- return/rewrite/break, in order. Shared
                                                       -- with ServerConfig's/ConditionalResponse's
                                                       -- field of the same name.
  , _accessLog            :: Bool
  , _extraIncludes        :: [Text]                   -- static, Nix-managed file paths
  , _extraHeaders         :: [(Text, Text)]           -- extra add_header name/value pairs (e.g. CORS).
                                                       -- Shared with ServerConfig's field of the same
                                                       -- name below.
  , _conditionalResponses :: [ConditionalResponse]    -- e.g. CORS preflight handling; see
                                                       -- ConditionalResponse's own doc comment
  , _accessRules          :: [AccessRule]              -- allow/deny, in order. Shared with
                                                       -- ServerConfig's field of the same name.
  , _extraDirectives      :: [(Text, Text)]           -- catch-all for any other
                                                       -- ngx_http_core_module location-context
                                                       -- directive not explicitly modeled above.
                                                       -- Shared with ServerConfig's field of the
                                                       -- same name; see its own doc comment.
  } deriving (Show, Generic)

makeFieldsNoPrefix ''Location

instance FromJSON Location where
  parseJSON = withObject "Location" $ \o -> Location
    <$> o .:  "path"
    <*> o .:? "match" .!= Prefix
    <*> o .:? "proxy_pass"
    <*> parseOptionalProxy o
    <*> o .:? "rewrite_directives" .!= def
    <*> o .:? "access_log" .!= True
    <*> o .:? "extra_includes" .!= def
    <*> o .:? "extra_headers" .!= def
    <*> o .:? "conditional_responses" .!= def
    <*> o .:? "access_rules" .!= def
    <*> o .:? "extra_directives" .!= def

-- ===================== Server =====================

data Listen = Listen
  { _port :: Int
  , _ssl  :: Bool
  , _ipv6 :: Bool
  } deriving (Show, Generic)

makeFieldsNoPrefix ''Listen

instance FromJSON Listen where
  parseJSON = withObject "Listen" $ \o -> Listen
    <$> o .:  "port"
    <*> o .:? "ssl"  .!= def
    <*> o .:? "ipv6" .!= def

-- | Bare field names + `makeFieldsNoPrefix`: `proxy`/`extraHeaders`/
-- `rewriteDirectives`/`accessRules` all join the classes Location (and,
-- for the latter two, ConditionalResponse) already established;
-- `locations` is unique to ServerConfig. A server's own
-- settings and its child locations live in one type, not split further -
-- the KV wire format is flat (one JSON object per server, "locations"
-- alongside its other fields, see DESIGN.md's KV layout section), and
-- nothing outside this file's own decode/render code ever needed a "just
-- the settings, no locations" value on its own. `Server` itself is `Named
-- ServerConfig` below - its name comes from `Named`, not from a field
-- here, same reasoning as `UpstreamConfig` above. Upstreams are a
-- separate top-level KV entity (nginx's own "upstream {}" is an
-- http-scope construct referenced by name from anywhere, not owned by one
-- server), so there's no upstreams field here at all.
data ServerConfig = ServerConfig
  { _serverName       :: [Text]        -- nginx's own "server_name name ...;" takes one or
                                       -- more space-separated names/wildcards/regexes; kept
                                       -- as its own required field (not folded into
                                       -- extra_directives) since it's a first-class,
                                       -- always-relevant part of a server block, unlike
                                       -- one-off directives like the removed "hsts".
  , _listen           :: [Listen]
  , _http2            :: Bool
  , _tlsCertPath      :: Maybe Text    -- same file used for cert + key
  , _extraHeaders     :: [(Text, Text)]  -- extra add_header name/value pairs, site-wide. Shared
                                       -- with Location's field of the same name above.
  , _proxy            :: ProxyParameters -- site-wide proxy_http_version/proxy_set_header/
                                       -- proxy_next_upstream*, inherited by every location
                                       -- unless a location sets its own. Shared with Location's
                                       -- field of the same name; empty (nothing rendered) when
                                       -- unset, same as Location's.
  , _rewriteDirectives :: [RewriteModuleDirective]  -- return/rewrite/break, in order, at the
                                       -- server level. Shared with Location's/
                                       -- ConditionalResponse's field of the same name.
  , _accessRules      :: [AccessRule]    -- allow/deny, in order, at the server level. Shared
                                       -- with Location's field of the same name.
  , _extraDirectives  :: [(Text, Text)]  -- catch-all for any other ngx_http_core_module
                                       -- server-context directive not explicitly modeled
                                       -- above (e.g. "client_max_body_size", "server_tokens",
                                       -- "error_page") - rendered verbatim as "key value;".
                                       -- An ordered assoc list, not a KeyMap, so a directive
                                       -- nginx allows multiple times in one server block
                                       -- (e.g. several "error_page" lines) can appear more
                                       -- than once here too, same reasoning as extra_headers.
  , _locations        :: [Location]    -- attached from this KV entry's own "locations" object
  } deriving (Show, Generic)

makeFieldsNoPrefix ''ServerConfig

-- | Reads its own fields straight off the KV entry's top-level object,
-- and its child locations from that same object's "locations" key - a
-- plain JSON array, not an object keyed by name, since nothing ever
-- reads a Location's name (see Location's own doc comment) and inventing
-- one per location just to satisfy an object shape would be pure
-- busywork for whoever's writing these into Consul KV. This type's own
-- "name" is handled one level up, by 'Named'\'s instance.
instance FromJSON ServerConfig where
  parseJSON = withObject "ServerConfig" $ \o -> ServerConfig
      <$> o .:  "server_name"
      <*> o .:  "listen"
      <*> o .:? "http2" .!= def
      <*> o .:? "tls_cert_path"
      <*> o .:? "extra_headers" .!= def
      <*> parseOptionalProxy o
      <*> o .:? "rewrite_directives" .!= def
      <*> o .:? "access_rules" .!= def
      <*> o .:? "extra_directives" .!= def
      <*> o .:? "locations" .!= def

type Server = Named ServerConfig
