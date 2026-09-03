{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Types where

import Data.Aeson
import Data.Aeson.Key (Key)
import qualified Data.Aeson.Key as Key
import Data.Aeson.KeyMap (KeyMap)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import Data.Foldable.WithIndex (ifoldMap, itraverse_)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | Anything that can turn itself into a fragment of nginx config text,
-- regardless of where in the KV tree (or the assembled config) it came from.
class ToNginxConf a where
  toNginxConf :: a -> Text

-- ===================== shared key/value parameter helpers =====================

-- | A parameter whose value is a plain scalar (Bool/Number/String) -
-- shared by UpstreamServer's "server" parameters and Resolver's, which
-- have the exact same shape: "key=value", or a bare keyword when the
-- value is true. Proxy's own parameters allow richer shapes
-- (Array/Object) and so validate/render separately (checkProxyParam/
-- renderProxyParam below).
checkIsRawValue :: Key -> Value -> Parser ()
checkIsRawValue k v = case v of
  Bool _   -> pure ()
  Number _ -> pure ()
  String _ -> pure ()
  _        -> fail ("parameter \"" <> Key.toString k <> "\" must be a bool, number, or string")

-- | Renders one parameter: a bare keyword when true (e.g. "backup"),
-- omitted entirely when false (e.g. a Value of Bool False), or "key=value"
-- for anything else. Value shapes other than Bool/Number/String are
-- rejected by checkIsRawValue above, so this is total in practice.
renderRawKeyValue :: Key -> Value -> [Text]
renderRawKeyValue k (Bool True)  = [ Key.toText k ]
renderRawKeyValue _ (Bool False) = []
renderRawKeyValue k (Number n)   = [ Key.toText k <> "=" <> T.pack (show (truncate n :: Integer)) ]
renderRawKeyValue k (String s)   = [ Key.toText k <> "=" <> s ]
renderRawKeyValue _ _            = []

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
  { address    :: Text
  , parameters :: KeyMap Value
  } deriving (Show, Generic)

instance FromJSON Resolver where
  parseJSON = withObject "Resolver" $ \o -> do
    addr <- o .: "address"
    let rest = KM.delete "address" o
    itraverse_ checkIsRawValue rest
    pure (Resolver addr (KM.union rest defaultResolverParams))
    where
      defaultResolverParams = KM.fromList
        [ ("ipv6", "off")  -- this project's existing default; nginx's own default is "on"
        ]

instance ToNginxConf Resolver where
  toNginxConf (Resolver { address, parameters }) =
    T.unwords ([ "resolver", address ] <> ifoldMap renderRawKeyValue parameters) <> ";"

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
-- three fields is Maybe - an absent "proxy" key parses to
-- 'emptyProxyParameters', and any directive left empty here is simply
-- omitted from the rendered config, letting nginx fall back to its own
-- built-in default (proxy_http_version, proxy_next_upstream etc. all have
-- one) rather than this code keeping its own copy in sync.
data ProxyParameters = ProxyParameters
  { rawParams    :: KeyMap Value  -- everything but next_upstream/set_header;
                                  -- keys already carry their "proxy_" prefix
  , nextUpstream :: [Text]        -- proxy_next_upstream's space-separated tokens
  , setHeader    :: KeyMap Text   -- proxy_set_header's name->value pairs
  } deriving (Show, Generic)

emptyProxyParameters :: ProxyParameters
emptyProxyParameters = ProxyParameters KM.empty [] KM.empty

-- | Only called (via "parseOptionalProxy" below) when a "proxy" key is
-- actually present - an absent key short-circuits to
-- 'emptyProxyParameters' without ever reaching here.
parseProxyParams :: Object -> Parser ProxyParameters
parseProxyParams given = do
  let normalized = KM.fromList [ (normalizeKey k, v) | (k, v) <- KM.toList given ]
  nextUpstream <- case KM.lookup "proxy_next_upstream" normalized of
    Nothing -> pure []
    Just v  -> parseJSON v
  setHeader <- case KM.lookup "proxy_set_header" normalized of
    Nothing          -> pure KM.empty
    Just (Object hs) -> traverse expectHeaderString hs
    Just _           -> fail "proxy_set_header must be an object of header name/value pairs"
  let rawParams = KM.delete "proxy_set_header" (KM.delete "proxy_next_upstream" normalized)
  itraverse_ checkRawProxyParam rawParams
  pure (ProxyParameters rawParams nextUpstream setHeader)
  where
    normalizeKey k =
      if "proxy_" `T.isPrefixOf` Key.toText k
      then k
      else Key.fromText ("proxy_" <> Key.toText k)

    expectHeaderString (String s) = pure s
    expectHeaderString _ = fail "proxy_set_header values must be strings"

    checkRawProxyParam :: Key -> Value -> Parser ()
    checkRawProxyParam k v = case v of
      String _ -> pure ()
      Number _ -> pure ()
      _        -> fail ("proxy parameter \"" <> Key.toString k <> "\" must be a string or number")

-- | Parses an optional "proxy" object field, defaulting to
-- 'emptyProxyParameters' when the key is absent. Shared by Location's and
-- ServerConfig's FromJSON instances.
parseOptionalProxy :: Object -> Parser ProxyParameters
parseOptionalProxy o = o .:? "proxy" >>= maybe (pure emptyProxyParameters) parseProxyParams

renderProxyBlock :: ProxyParameters -> Text
renderProxyBlock (ProxyParameters raw nextUpstream setHeader) =
  T.intercalate "\n" $
    concatMap renderRawProxyParam (KM.toList raw)
    <> [ "proxy_next_upstream " <> T.unwords nextUpstream <> ";" | not (null nextUpstream) ]
    <> [ "proxy_set_header " <> Key.toText hName <> " \"" <> hValue <> "\";"
       | (hName, hValue) <- KM.toList setHeader
       ]
  where
    renderRawProxyParam (k, String s) = [ Key.toText k <> " " <> s <> ";" ]
    renderRawProxyParam (k, Number n) = [ Key.toText k <> " " <> T.pack (show (truncate n :: Integer)) <> ";" ]
    renderRawProxyParam (_, _) = []

-- | Prefix every line of a (possibly multi-line) rendered sub-block with
-- the given indent - used to embed a shared block (like the proxy params
-- map) at whatever nesting depth the caller is at.
indentLines :: Text -> Text -> Text
indentLines indent block = T.intercalate "\n" (map (indent <>) (T.lines block))

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
-- real record field, the other a KeyMap key).
data UpstreamServer = UpstreamServer
  { address    :: Text  -- "log-processor-backend.service.consul:8080"
  , parameters :: KeyMap Value
  } deriving (Show, Generic)

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
        -- "slow_start" intentionally has no entry: nginx's own default is
        -- "disabled", which is exactly what "absent from this map" means. nginx
        -- also rejects "slow_start" together with "backup" on the same server -
        -- not enforced here, caught by "nginx -t" like any other config error.
        ]

instance ToNginxConf UpstreamServer where
  toNginxConf (UpstreamServer { address, parameters }) =
    (<> ";") $ T.unwords $ [ "server", address ] <> ifoldMap renderRawKeyValue parameters

-- | "name" is shared with Location's and ServerConfig's own KV-key-derived
-- name field below - DuplicateRecordFields allows the same label on all
-- three, and OverloadedRecordDot (u.name) resolves reads via the receiver's
-- type, so there's no need for a per-type prefix here anymore. "resolver"
-- is shared the same way, with Location's and ServerConfig's field below.
data Upstream = Upstream
  { name               :: Text          -- from the KV key, not the JSON body
  , resolver           :: Maybe Resolver
  , servers            :: [UpstreamServer]
  , keepalive          :: Maybe Int
  , keepalive_requests :: Maybe Int
  , keepalive_timeout  :: Maybe Text
  , zone_size          :: Maybe Text    -- "2m"
  } deriving (Show, Generic)

instance FromJSON Upstream where
  parseJSON = withObject "Upstream" $ \o -> Upstream
    <$> pure ""  -- filled in from the KV key path after parsing
    <*> o .:? "resolver"
    <*> o .:  "servers"
    <*> o .:? "keepalive"
    <*> o .:? "keepalive_requests"
    <*> o .:? "keepalive_timeout"
    <*> o .:? "zone_size"

instance ToNginxConf Upstream where
  toNginxConf u = T.unlines $
    [ "upstream " <> u.name <> " {" ]
    <> maybe [] (\r -> [ "  " <> toNginxConf r ]) u.resolver
    <> map (("  " <>) . toNginxConf) (servers u)
    <> maybe [] (\n -> [ "  keepalive " <> T.pack (show n) <> ";" ]) (keepalive u)
    <> maybe [] (\n -> [ "  keepalive_requests " <> T.pack (show n) <> ";" ]) u.keepalive_requests
    <> maybe [] (\t -> [ "  keepalive_timeout " <> t <> ";" ]) u.keepalive_timeout
    <> maybe [] (\z -> [ "  zone " <> u.name <> " " <> z <> ";" ]) u.zone_size
    <> [ "}" ]

-- ===================== Location =====================

data MatchType = MatchExact | MatchPrefixExact | MatchPrefix | MatchRegex | MatchRegexCI
  deriving (Show, Eq, Generic)

instance FromJSON MatchType where
  parseJSON = withText "MatchType" $ \case
    "exact"        -> pure MatchExact         -- "="
    "prefix_exact" -> pure MatchPrefixExact   -- "^~"  (stop regex search, like today's routes)
    "prefix"       -> pure MatchPrefix        -- no modifier
    "regex"        -> pure MatchRegex         -- "~"
    "regex_ci"     -> pure MatchRegexCI       -- "~*"
    other          -> fail $ "unknown matchType: " <> T.unpack other

-- | The three ngx_http_rewrite_module directives valid in server, location,
-- AND if contexts - and per nginx's own docs, the only ones "100% safe"
-- inside "if". Modeled as an ordered list wherever used (Location,
-- ServerConfig, ConditionalResponse below) because nginx evaluates
-- multiple such directives in the same context in the order they're
-- written - e.g. the rewrite module's own docs example:
--   rewrite ^(/download/.*)/media/(.*)\..*$ $1/mp3/$2.mp3 last;
--   rewrite ^(/download/.*)/audio/(.*)\..*$ $1/mp3/$2.ra  last;
--   return  403;
-- Constructor names (Return/Rewrite/Break) don't clash with anything:
-- data constructors and lowercase functions are different namespaces, so
-- "Return" doesn't shadow Prelude's "return" the way a field named bare
-- "return" would have (see ConditionalResponse's old "returnCode", now
-- gone - this replaces it, and Location's old "locReturn"/"LocationReturn"
-- too, both fully subsumed by a single-element list here).
data RewriteFlag = RewriteLast | RewriteBreakFlag | RewriteRedirect | RewritePermanent
  deriving (Show, Eq, Generic)

instance FromJSON RewriteFlag where
  parseJSON = withText "RewriteFlag" $ \case
    "last"      -> pure RewriteLast
    "break"     -> pure RewriteBreakFlag
    "redirect"  -> pure RewriteRedirect
    "permanent" -> pure RewritePermanent
    other       -> fail $ "unknown rewrite flag: " <> T.unpack other

data RewriteModuleDirective
  = Return { code :: Int, value :: Maybe Text }
    -- e.g. {"type":"return","code":403} or
    -- {"type":"return","code":301,"value":"https://example.com"}. The bare
    -- "return URL;" (implicit 302) shorthand isn't modeled - write it
    -- explicitly as code=302 instead, one less Maybe to thread through.
  | Rewrite { regex :: Text, replacement :: Text, flag :: Maybe RewriteFlag }
    -- e.g. {"type":"rewrite","regex":"^/old/(.*)","replacement":"/new/$1","flag":"last"}
  | Break
    -- {"type":"break"}
  deriving (Show, Generic)

instance FromJSON RewriteModuleDirective where
  parseJSON = withObject "RewriteModuleDirective" $ \o -> do
    ty <- o .: "type"
    case (ty :: Text) of
      "return"  -> Return <$> o .: "code" <*> o .:? "value"
      "rewrite" -> Rewrite <$> o .: "regex" <*> o .: "replacement" <*> o .:? "flag"
      "break"   -> pure Break
      other     -> fail ("unknown RewriteModuleDirective \"type\": " <> T.unpack other)

instance ToNginxConf RewriteModuleDirective where
  toNginxConf (Return c v) = "return " <> T.pack (show c) <> maybe "" (" " <>) v <> ";"
  toNginxConf (Rewrite re repl f) =
    "rewrite " <> re <> " " <> repl <> maybe "" ((" " <>) . rewriteFlagText) f <> ";"
    where
      rewriteFlagText RewriteLast      = "last"
      rewriteFlagText RewriteBreakFlag = "break"
      rewriteFlagText RewriteRedirect  = "redirect"
      rewriteFlagText RewritePermanent = "permanent"
  toNginxConf Break = "break;"

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
  parseJSON = withText "AccessDirection" $ \case
    "allow" -> pure Allow
    "deny"  -> pure Deny
    other   -> fail $ "unknown AccessDirection: " <> T.unpack other

data AccessRule = AccessRule
  { direction :: AccessDirection
  , value     :: Text  -- e.g. "10.0.0.0/8", "unix:", or "all"
  } deriving (Show, Generic)

instance FromJSON AccessRule where
  parseJSON = withObject "AccessRule" $ \o -> AccessRule
    <$> o .: "type"
    <*> o .: "value"

instance ToNginxConf AccessRule where
  toNginxConf r = accessDirectionText r.direction <> " " <> r.value <> ";"
    where
      accessDirectionText Allow = "allow"
      accessDirectionText Deny  = "deny"

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
  { condition          :: Text                       -- raw nginx condition, e.g. "$request_method = 'OPTIONS'"
  , extra_headers      :: [(Text, Text)]              -- branch-only add_header pairs - see note above
  , rewrite_directives :: [RewriteModuleDirective]    -- e.g. a single Return; ordered, see that type's doc
  } deriving (Show, Generic)

instance FromJSON ConditionalResponse where
  parseJSON = withObject "ConditionalResponse" $ \o -> ConditionalResponse
    <$> o .:  "condition"
    <*> o .:? "extra_headers" .!= []
    <*> o .:? "rewrite_directives" .!= []

instance ToNginxConf ConditionalResponse where
  toNginxConf c = T.intercalate "\n" $
    [ "if (" <> condition c <> ") {" ]
    <> map (renderHeader "  ") c.extra_headers
    <> map (("  " <>) . toNginxConf) c.rewrite_directives
    <> [ "}" ]

data Location = Location
  { name                 :: Text                    -- from the KV key, see Upstream.name above
  , path                 :: Text                     -- real nginx path, e.g. "/godel/analytics"
  , match                :: MatchType
  , proxy_pass           :: Maybe Text               -- nginx's own full "proxy_pass" target,
                                                      -- scheme included (e.g. "http://backend" or
                                                      -- "https://backend") - not hardcoded to a
                                                      -- scheme here, so a KV entry can point at an
                                                      -- https upstream just as easily.
  , proxy                :: ProxyParameters          -- proxy_http_version/proxy_set_header/
                                                      -- proxy_next_upstream* - only rendered when
                                                      -- proxy_pass is set. Shared with ServerConfig's
                                                      -- field of the same name; see parseProxyParams.
  , rewrite_directives   :: [RewriteModuleDirective]  -- return/rewrite/break, in order. Shared
                                                      -- with ServerConfig's/ConditionalResponse's
                                                      -- field of the same name.
  , access_log           :: Bool
  , extra_includes       :: [Text]                   -- static, Nix-managed file paths
  , extra_headers        :: [(Text, Text)]           -- extra add_header name/value pairs (e.g. CORS).
                                                      -- Shared with ServerConfig's field of the same
                                                      -- name below - same DuplicateRecordFields deal
                                                      -- as "name".
  , resolver             :: Maybe Resolver            -- valid here too (ngx_http_core_module).
                                                      -- Shared with Upstream's/ServerConfig's field
                                                      -- of the same name.
  , conditional_responses :: [ConditionalResponse]    -- e.g. CORS preflight handling; see
                                                      -- ConditionalResponse's own doc comment
  , access_rules         :: [AccessRule]              -- allow/deny, in order. Shared with
                                                      -- ServerConfig's field of the same name.
  } deriving (Show, Generic)

instance FromJSON Location where
  parseJSON = withObject "Location" $ \o -> Location
    <$> pure ""
    <*> o .:  "path"
    <*> o .:? "match" .!= MatchPrefix
    <*> o .:? "proxy_pass"
    <*> parseOptionalProxy o
    <*> o .:? "rewrite_directives" .!= []
    <*> o .:? "access_log" .!= True
    <*> o .:? "extra_includes" .!= []
    <*> o .:? "extra_headers" .!= []
    <*> o .:? "resolver"
    <*> o .:? "conditional_responses" .!= []
    <*> o .:? "access_rules" .!= []

instance ToNginxConf Location where
  toNginxConf l = T.unlines $
    [ "  location " <> matchModifier (match l) <> path l <> " {" ]
    <> map (("    " <>) . toNginxConf) l.access_rules
    <> map (indentLines "    " . toNginxConf) l.conditional_responses
    <> maybe [] (\p ->
         [ "    proxy_pass " <> p <> ";"
         , indentLines "    " (renderProxyBlock l.proxy)
         ]
       ) l.proxy_pass
    <> maybe [] (\r -> [ "    " <> toNginxConf r ]) l.resolver
    <> map (("    " <>) . toNginxConf) l.rewrite_directives
    <> [ "    access_log off;" | not l.access_log ]
    <> map (\f -> "    include " <> f <> ";") l.extra_includes
    <> map (renderHeader "    ") l.extra_headers
    <> [ "  }" ]
    where
      matchModifier MatchExact       = "= "
      matchModifier MatchPrefixExact = "^~ "
      matchModifier MatchPrefix      = ""
      matchModifier MatchRegex       = "~ "
      matchModifier MatchRegexCI     = "~* "

renderHeader :: Text -> (Text, Text) -> Text
renderHeader indent (hName, hValue) = indent <> "add_header " <> hName <> " \"" <> hValue <> "\" always;"

-- ===================== Server =====================

data Listen = Listen
  { port :: Int
  , ssl  :: Bool
  , ipv6 :: Bool
  } deriving (Show, Generic)

instance FromJSON Listen where
  parseJSON = withObject "Listen" $ \o -> Listen
    <$> o .:  "port"
    <*> o .:? "ssl"  .!= False
    <*> o .:? "ipv6" .!= False

data ServerConfig = ServerConfig
  { name               :: Text          -- from the KV key, see Upstream.name above
  , server_name        :: [Text]        -- nginx's own "server_name name ...;" takes one or
                                          -- more space-separated names/wildcards/regexes; kept
                                          -- as its own required field (not folded into
                                          -- extra_directives) since it's a first-class,
                                          -- always-relevant part of a server block, unlike
                                          -- one-off directives like the removed "hsts".
  , listen             :: [Listen]
  , http2              :: Bool
  , tls_cert_path      :: Maybe Text    -- same file used for cert + key
  , extra_headers      :: [(Text, Text)]  -- extra add_header name/value pairs, site-wide. Shared
                                          -- with Location's field of the same name above.
  , resolver           :: Maybe Resolver  -- valid here too (ngx_http_core_module). Shared
                                          -- with Upstream's/Location's field of the same name.
  , proxy              :: ProxyParameters -- site-wide proxy_http_version/proxy_set_header/
                                          -- proxy_next_upstream*, inherited by every location
                                          -- unless a location sets its own. Shared with Location's
                                          -- field of the same name; empty (nothing rendered) when
                                          -- unset, same as Location's.
  , rewrite_directives :: [RewriteModuleDirective]  -- return/rewrite/break, in order, at the
                                          -- server level. Shared with Location's/
                                          -- ConditionalResponse's field of the same name.
  , access_rules       :: [AccessRule]    -- allow/deny, in order, at the server level. Shared
                                          -- with Location's field of the same name.
  , extra_directives   :: [(Text, Text)]  -- catch-all for any other ngx_http_core_module
                                          -- server-context directive not explicitly modeled
                                          -- above (e.g. "client_max_body_size", "server_tokens",
                                          -- "error_page") - rendered verbatim as "key value;".
                                          -- An ordered assoc list, not a KeyMap, so a directive
                                          -- nginx allows multiple times in one server block
                                          -- (e.g. several "error_page" lines) can appear more
                                          -- than once here too, same reasoning as extra_headers.
  } deriving (Show, Generic)

instance FromJSON ServerConfig where
  parseJSON = withObject "ServerConfig" $ \o -> ServerConfig
    <$> pure ""
    <*> o .:  "server_name"
    <*> o .:  "listen"
    <*> o .:? "http2" .!= False
    <*> o .:? "tls_cert_path"
    <*> o .:? "extra_headers" .!= []
    <*> o .:? "resolver"
    <*> parseOptionalProxy o
    <*> o .:? "rewrite_directives" .!= []
    <*> o .:? "access_rules" .!= []
    <*> o .:? "extra_directives" .!= []

-- Fully assembled server, after collecting its locations/upstreams from KV.
data Server = Server
  { config    :: ServerConfig
  , upstreams :: [Upstream]
  , locations :: [Location]
  } deriving (Show, Generic)

instance ToNginxConf Server where
  toNginxConf (Server cfg ups locs) = T.unlines $
    map toNginxConf ups
    <> [ "server {" ]
    <> map renderListen (listen cfg)
    <> [ "  server_name " <> T.unwords cfg.server_name <> ";" ]
    <> [ "  http2 on;" | http2 cfg ]
    <> maybe [] (\c -> [ "  ssl_certificate " <> c <> ";"
                        , "  ssl_certificate_key " <> c <> ";" ]) cfg.tls_cert_path
    <> map (renderHeader "  ") cfg.extra_headers
    <> map (("  " <>) . toNginxConf) cfg.access_rules
    <> maybe [] (\r -> [ "  " <> toNginxConf r ]) cfg.resolver
    <> [ indentLines "  " (renderProxyBlock cfg.proxy) ]
    <> map (("  " <>) . toNginxConf) cfg.rewrite_directives
    <> [ "  " <> k <> " " <> v <> ";" | (k, v) <- cfg.extra_directives ]
    -- Mechanically derived, not user-set: nginx needs to tell the upstream
    -- which port the client actually connected on.
    <> [ "  proxy_set_header X-Forwarded-Port " <> T.pack (show (port ls)) <> ";"
       | ls <- listen cfg, ssl ls ]
    <> map toNginxConf locs
    <> [ "}" ]
    where
      renderListen (Listen p s i) =
        "  listen " <> (if i then "[::]:" else "0.0.0.0:") <> T.pack (show p)
          <> (if s then " ssl;" else ";")
