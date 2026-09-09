{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}

-- | Rendering: turning already-parsed 'Types' values into nginx config
-- text. Kept separate from "Types.hs" (which owns parsing - JSON in,
-- typed values out) so that file doesn't also have to hold every type's
-- rendering logic alongside its data declaration and 'FromJSON' instance -
-- "Types.hs" was getting too big.
module NginxConf
  ( NginxConf (..)
  ) where

import Control.Lens
import Data.Aeson (Key, Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Strict.Lens (packed)

import Types

-- | Anything that can turn itself into a fragment of nginx config text,
-- regardless of where in the KV tree (or the assembled config) it came from.
class NginxConf a where
  toNginxConf :: a -> Text

-- ===================== shared rendering helpers =====================

-- | Renders one parameter: a bare keyword when true (e.g. "backup"),
-- omitted entirely when false (e.g. a Value of Bool False), or "key=value"
-- for anything else. Value shapes other than Bool/Number/String are
-- rejected at parse time by Types.hs's checkIsRawValue, so this is total
-- in practice. Shared by Resolver's and UpstreamServer's instances below.
renderRawKeyValue :: Key -> Value -> [Text]
renderRawKeyValue k = \case
  Bool True -> [ Key.toText k ]
  Number n  -> [ Key.toText k <> "=" <> (truncate n :: Integer) ^. re _Show.packed ]
  String s  -> [ Key.toText k <> "=" <> s ]
  _         -> []

-- | Prefix every line of a (possibly multi-line) rendered sub-block with
-- the given indent - used to embed a shared block (like the proxy params
-- map) at whatever nesting depth the caller is at.
indentLines :: Text -> Text -> Text
indentLines indent block = T.intercalate "\n" ((indent <>) <$> T.lines block)

renderHeader :: Text -> (Text, Text) -> Text
renderHeader indent (hName, hValue) = indent <> "add_header " <> hName <> " \"" <> hValue <> "\" always;"

-- | Renders a 'ProxyParameters' value - each raw entry is its OWN nginx
-- statement ("key value;"), plus "proxy_next_upstream"/"proxy_set_header"
-- rendered from their own typed fields (see 'ProxyParameters' in
-- Types.hs for why those two get dedicated fields instead of staying in
-- the raw map). Shared by Location's and ServerConfig's instances below.
renderProxyBlock :: ProxyParameters -> Text
renderProxyBlock params =
  T.intercalate "\n" $
    concatMap renderRawProxyParam (KM.toList (params ^. rawParams))
    <> [ "proxy_next_upstream " <> T.unwords nextUp <> ";" | not (null nextUp) ]
    <> [ "proxy_set_header " <> Key.toText hName <> " \"" <> hValue <> "\";"
       | (hName, hValue) <- KM.toList (params ^. setHeader)
       ]
  where
    nextUp = params ^. nextUpstream

    renderRawProxyParam (k, String s) = [ Key.toText k <> " " <> s <> ";" ]
    renderRawProxyParam (k, Number n) = [ Key.toText k <> " " <> (truncate n :: Integer) ^. re _Show.packed <> ";" ]
    renderRawProxyParam (_, _) = []

-- ===================== Resolver / UpstreamServer =====================

instance NginxConf Resolver where
  toNginxConf (Resolver addr params) =
    T.unwords ([ "resolver", addr ] <> ifoldMap renderRawKeyValue params) <> ";"

instance NginxConf UpstreamServer where
  toNginxConf (UpstreamServer addr params) =
    (<> ";") $ T.unwords $ [ "server", addr ] <> ifoldMap renderRawKeyValue params

-- ===================== Upstream =====================

-- | Unlike 'ServerConfig' below, an upstream's name genuinely is rendered
-- (nginx's own "upstream <name> {"/"zone <name> ...;"), so this instance
-- reaches into both `named ^. name` and `named ^. config` directly.
instance NginxConf (Named UpstreamConfig) where
  toNginxConf named = T.unlines $
    [ "upstream " <> named ^. name <> " {" ]
    <> maybe [] (\r -> [ "  " <> toNginxConf r ]) (cfg ^. resolver)
    <> (("  " <>) . toNginxConf <$> cfg ^. servers)
    <> maybe [] (\n -> [ "  keepalive " <> n ^. re _Show.packed <> ";" ]) (cfg ^. keepalive)
    <> maybe [] (\n -> [ "  keepalive_requests " <> n ^. re _Show.packed <> ";" ]) (cfg ^. keepaliveRequests)
    <> maybe [] (\t -> [ "  keepalive_timeout " <> t <> ";" ]) (cfg ^. keepaliveTimeout)
    <> maybe [] (\z -> [ "  zone " <> named ^. name <> " " <> z <> ";" ]) (cfg ^. zoneSize)
    <> [ "}" ]
    where cfg = named ^. config

-- ===================== Location =====================

instance NginxConf RewriteModuleDirective where
  toNginxConf (Return c v) = "return " <> c ^. re _Show.packed <> maybe "" (" " <>) v <> ";"
  toNginxConf (Rewrite rgx repl f) =
    "rewrite " <> rgx <> " " <> repl <> maybe "" ((" " <>) . rewriteFlagText) f <> ";"
    where
      rewriteFlagText Last      = "last"
      rewriteFlagText Break     = "break"
      rewriteFlagText Redirect  = "redirect"
      rewriteFlagText Permanent = "permanent"
  toNginxConf BreakDirective = "break;"

instance NginxConf AccessRule where
  toNginxConf r = accessDirectionText (r ^. direction) <> " " <> r ^. value <> ";"
    where
      accessDirectionText Allow = "allow"
      accessDirectionText Deny  = "deny"

instance NginxConf ConditionalResponse where
  toNginxConf c = T.intercalate "\n" $
    [ "if (" <> c ^. condition <> ") {" ]
    <> (renderHeader "  " <$> c ^. extraHeaders)
    <> (("  " <>) . toNginxConf <$> c ^. rewriteDirectives)
    <> [ "}" ]

instance NginxConf Location where
  toNginxConf l = T.unlines $
    [ "  location " <> matchModifier (l ^. match) <> l ^. path <> " {" ]
    <> (("    " <>) . toNginxConf <$> l ^. accessRules)
    <> (indentLines "    " . toNginxConf <$> l ^. conditionalResponses)
    <> maybe [] (\p ->
         [ "    proxy_pass " <> p <> ";"
         , indentLines "    " (renderProxyBlock (l ^. proxy))
         ]
       ) (l ^. proxyPass)
    <> (("    " <>) . toNginxConf <$> l ^. rewriteDirectives)
    <> [ "    access_log off;" | not (l ^. accessLog) ]
    <> ((\f -> "    include " <> f <> ";") <$> l ^. extraIncludes)
    <> (renderHeader "    " <$> l ^. extraHeaders)
    <> [ "    " <> k <> " " <> v <> ";" | (k, v) <- l ^. extraDirectives ]
    <> [ "  }" ]
    where
      matchModifier Exact       = "= "
      matchModifier PrefixExact = "^~ "
      matchModifier Prefix      = ""
      matchModifier Regex       = "~ "
      matchModifier RegexCI     = "~* "

-- ===================== Server =====================

-- | Unlike 'UpstreamConfig' above, a server's name is never rendered (see
-- 'Named'\'s own doc comment in Types.hs) - `named ^. name` never appears
-- here, only `cfg = named ^. config`.
instance NginxConf (Named ServerConfig) where
  toNginxConf named = T.unlines $
    [ "server {" ]
    <> (renderListen <$> cfg ^. listen)
    <> [ "  server_name " <> T.unwords (cfg ^. serverName) <> ";" ]
    <> [ "  http2 on;" | cfg ^. http2 ]
    <> maybe [] (\c -> [ "  ssl_certificate " <> c <> ";"
                        , "  ssl_certificate_key " <> c <> ";" ]) (cfg ^. tlsCertPath)
    <> (renderHeader "  " <$> cfg ^. extraHeaders)
    <> (("  " <>) . toNginxConf <$> cfg ^. accessRules)
    <> [ indentLines "  " (renderProxyBlock (cfg ^. proxy)) ]
    <> (("  " <>) . toNginxConf <$> cfg ^. rewriteDirectives)
    <> [ "  " <> k <> " " <> v <> ";" | (k, v) <- cfg ^. extraDirectives ]
    -- Mechanically derived, not user-set: nginx needs to tell the upstream
    -- which port the client actually connected on.
    <> [ "  proxy_set_header X-Forwarded-Port " <> ls ^. port.re _Show.packed <> ";"
       | ls <- cfg ^. listen, ls ^. ssl ]
    <> (toNginxConf <$> cfg ^. locations)
    <> [ "}" ]
    where
      cfg = named ^. config

      renderListen :: Listen -> Text
      renderListen ls =
        "  listen " <> (if ls ^. ipv6 then "[::]:" else "0.0.0.0:") <> ls ^. port.re _Show.packed
          <> (if ls ^. ssl then " ssl;" else ";")
