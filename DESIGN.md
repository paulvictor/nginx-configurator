# nginx-lb-render: design notes

## Context

nginx was originally a static, log-processor-specific proxy: one hardcoded
`virtualHosts.alb` with the log-processor's routes baked into Nix
(`modules/nginx/logprocessor.nix`), plus a small `confd` job rendering a
handful of `map $host ...` blocks from Consul KV. The goal of this package
is to make nginx a general-purpose, Consul-KV-driven load balancer instead:
whole `server {}` / `location {}` / `upstream {}` definitions become data
that lives in Consul KV as JSON, and this program compiles them into nginx
config files. The log-processor's routes become just one more site defined
this way, not a special case baked into the module.

This program (the "renderer") deliberately does only one job: fetch +
decode + write files. It never runs `nginx -t`, never reloads nginx, and
never swaps any symlink - see "What's deliberately NOT done yet" below.

## KV layout

`servers` and `upstreams` are two separate, flat, top-level KV entities -
one complete JSON value per key, no further nesting into separate KV
entries:

```
servers/$server      -- Server's own JSON fields, flat, plus a sibling "locations": [Location JSON, ...]
upstreams/$upstream   -- Upstream JSON
```

`$server`/`$upstream` are opaque slug names taken from the KV key path and
become each value's own `"name"` field (see below). The nested
`"locations"` is a plain JSON array, not an object keyed by name - a
`Location` has no name field at all (nothing consumes one), and the real,
user-visible path (e.g. `/foo/bar`) is a field *inside* the
Location's own JSON body - so keying the array by an invented per-location
name would only be busywork for whoever's writing these into Consul KV.

This is a deliberate change from an earlier three-level layout
(`servers/$server/config`, `servers/$server/upstreams/$upstream/config`,
`servers/$server/locations/$location/config`, one Haskell record per KV
key, assembled back together in a fold - see "Deferred ideas" below for
why that fold existed). Two decisions drove the current shape:
- **`upstreams` promoted to its own top-level entity, not nested under a
  server.** nginx's `upstream {}` is genuinely an `http`-scope construct,
  referenced by name from *any* server/location via `proxy_pass
  http://name;` - it was never actually server-scoped, that was a modeling
  artifact of the original KV layout. Promoting it costs nothing in
  validation: `Location.proxy_pass`/`ServerConfig.proxy` already reference
  an upstream by an *unchecked* `Text` name, with no compile/parse-time
  link to a specific `Upstream` value - a typo'd name only ever surfaced at
  `nginx -t`, same as today. This also means an upstream can now be shared
  across multiple servers, which the old per-server nesting couldn't
  express at all.
- **A server's own settings and its `locations` collapsed into one flat KV
  value, with no `"config"` wrapper key.** A Nix module upstream of Consul
  (see "Deferred ideas") is expected to do the config+locations merge
  before anything reaches Consul, using NixOS's own module-merge
  semantics - once that merge already happened once, in Nix, there's
  nothing left to reassemble from multiple KV entries. Every entry -
  server or upstream - now independently decodes to one complete value;
  see `decodeKvEntry` below. `ServerConfig`'s own `FromJSON`
  instance reads its settings fields straight off the same top-level
  object that also holds `"locations"` (aeson ignores JSON keys a parser
  doesn't ask for, same leniency policy as everywhere else in this
  codebase), so a `"config"` sub-object would only exist to satisfy an
  artificial separation with no nginx-directive meaning of its own -
  dropped. This is still true at the Haskell level too, just one level up:
  `Server`/`Upstream` are each `Named` (see "Types.hs: parsing and
  rendering" below) specialized over `ServerConfig`/`UpstreamConfig`, and
  `ServerConfig` carries every one of its settings fields directly
  alongside `locations :: [Location]` - no further internal split.

JSON keys inside each blob are nginx's own snake_case directive/parameter
names (`server_name`, `keepalive_requests`, `proxy_http_version`, ...), not
camelCase - this avoids a translation layer and means a directive nginx
supports that isn't explicitly modeled here often doesn't need a code
change at all (see "raw KeyMap params" below).

## Types.hs and NginxConf.hs: parsing and rendering

`Types.hs` owns parsing - data declarations, `FromJSON` instances, and the
lenses (`makeFieldsNoPrefix`/`makeLenses`) generated for them. `NginxConf.hs`
owns rendering - the `NginxConf` typeclass and every instance of it, plus
the handful of pure `X -> Text` helpers (`renderRawKeyValue`,
`renderProxyBlock`, `indentLines`, `renderHeader`) only rendering needs.
Split into two files once `Types.hs` had grown to hold both a full data
model and a full renderer for it - each type's declaration/`FromJSON`
instance no longer has to sit next to its rendering logic to be
understood, and either side can be read on its own.

- **`NginxConf` typeclass** (`toNginxConf :: a -> Text`) - every type
  knows how to render itself; rendering doesn't care whether a fragment
  came from a server-level or upstream-level context.

- **`Named a = Named { name :: Text, config :: a }`, with `Server =
  Named ServerConfig` and `Upstream = Named UpstreamConfig`.** Both a
  server's and an upstream's own name always come from the same place -
  the Consul KV key - never from anywhere else in the JSON body (see "KV
  layout" above) - so rather than each of `ServerConfig`/`UpstreamConfig`
  hand-rolling an identical `name :: Text` field, both are just `Named`
  specialized over their own settings type, sharing one `HasName`/
  `HasConfig` pair (from `makeFieldsNoPrefix`) instead of two independent
  ones. `Named` has no `FromJSON` instance of its own - a `Named` value is
  only ever built directly, by `Main.hs`'s `decodeKvEntry` (which already
  knows the name from the KV key it just classified) or, in tests, by
  wrapping a decoded `ServerConfig`/`UpstreamConfig` with a name of the
  test's choosing. `Server`'s name is never rendered (see `NginxConf.hs`'s
  `NginxConf (Named ServerConfig)` instance, which never reaches for
  `named ^. name`) - nginx's `server {}` has no such directive, what
  renders is the separate `server_name` field - while `Upstream`'s name
  genuinely is (`upstream <name> {`, `zone <name> ...;`), so `NginxConf
  (Named UpstreamConfig)`'s instance uses both `named ^. name` and
  `named ^. config`.

- **`decodeKvEntry :: Value -> Parser (Either Server Upstream)`, in
  `Main.hs`** - decodes one raw Consul KV array element (`{"Key": ...,
  "Value": <base64>}`) straight into a `Server` (`Left`) or `Upstream`
  (`Right`), with no dedicated wrapper type for "which one this is" -
  `Either` already models that with no information loss (a batch decodes
  via plain `traverse (parseEither decodeKvEntry)`, then splits into
  `([Server], [Upstream])` via `Data.Either.partitionEithers`, both
  straight from `base`, not hand-rolled). Lives in `Main.hs`, not
  `Types.hs`: it used to have to live in a shared module, since Cabal
  requires every `main-is` file (both the executable's `Main.hs` and the
  test-suite's `Spec.hs`) to declare `module Main`, and a component can
  only have one `Main`, so `app/Main.hs`'s content can never be added to
  the test-suite's `other-modules`. Now that `test/Spec.hs` builds its
  `Server`/`Upstream` fixtures directly (see "Testing" below) instead of
  routing them through `decodeKvEntry`, that constraint no longer applies,
  and `decodeKvEntry` moved to sit next to its only remaining callers,
  `decodeKvBatch`'s two fetch functions (see "Consul KV fetch: stdin vs.
  HTTP" below).
  - Classifies by the key's own last two path segments as a plain,
    non-backtracking `case` (deliberately *not* `Alternative`/`<|>`
    trying "is it a server" then falling back to "is it an upstream"):
    checked against aeson's actual `Parser`/`Alternative` source, `mplus a
    b` discards `a`'s failure message entirely and reruns `b` from
    scratch, which would silently swallow a legitimate
    `ServerConfig`/`UpstreamConfig` schema-validation failure on a
    correctly-classified key (e.g. a `servers/$name` entry missing
    `"listen"` would misreport as "not a valid upstream" instead of the
    actual, useful `key "listen" not found`).
  - The `"Value"` -> settings-type step is one composed
    Traversal/Fold, no monadic glue: `ix "Value"._String.re
    utf8.folding B64.decode.to decodeStrict._Just` - `ix` (KeyMap's own
    `Ixed` instance, no need to wrap the object as a `Value` the way
    `key` would require) gets the JSON string's `Text`, `re utf8` flips
    it to a `ByteString`, `folding B64.decode` base64-decodes it
    (`Either String` is already `Foldable`), `to decodeStrict` JSON-decodes
    those bytes straight into the target settings type via its own
    `FromJSON` instance, and `_Just` unwraps the resulting `Maybe`. This
    project is opinionated towards reading from Consul, so a missing
    `"Value"` or invalid base64/JSON just reports the same generic
    `"invalid \"Value\""` rather than a specific reason per failure mode.
  - Still fails fast, by design (deferred: per-entry leniency).
    `traverse (parseEither decodeKvEntry)` aborts the whole batch at the
    first entry that fails to decode - a stray non-server/non-upstream
    key under the watched prefix, or a genuinely malformed value,
    currently skips the whole render rather than just that one entry.
    Reintroducing per-entry leniency (so one bad entry doesn't block
    every other one) is a deferred idea - an accumulating Applicative
    ("Validation"-style) rather than plain `Either`/`Parser`, not
    implemented yet.

- **Raw `KeyMap Value` params, not individual typed fields**, for anything
  where nginx's own parameter set might grow and JSON keys already match
  nginx's own names 1:1: `UpstreamServer.parameters`, `Resolver.parameters`,
  and `ProxyParameters.rawParams` (see below). Two rendering shapes exist
  for these maps:
  - `renderRawKeyValue` (shared by `UpstreamServer`/`Resolver`): renders a
    bare keyword when a bool is `true` (e.g. `backup`), omits it when
    `false`, otherwise `key=value` - all params of ONE directive
    (`server address key=value ...;` / `resolver address key=value ...;`).
  - `renderProxyBlock`/`parseProxyParams` (`Location`/`ServerConfig`'s
    `proxy` field, a `ProxyParameters`): each raw entry is its OWN nginx
    statement (`key value;`), keys missing the `proxy_` prefix get it
    added automatically (so both `http_version` and `proxy_http_version`
    work as JSON keys). `next_upstream` and `set_header` are pulled out
    into their own typed fields rather than staying in the raw map - see
    `ProxyParameters` below.

- **Mandatory fields pulled out of the generic map when nginx's own syntax
  requires a positional (non key=value) argument**: `Resolver.address` and
  `UpstreamServer.address` are both real record fields, not KeyMap entries,
  because nginx's syntax for both (`resolver address ...;` /
  `server address ...;`) has that value as a bare positional argument, not
  `key=value`.

- **`ProxyParameters` on `Location`/`ServerConfig`, no field ever `Maybe`,
  and no built-in defaults kept in this code at all.** `ProxyParameters`
  has three fields: `rawParams :: KeyMap Value` (everything except the two
  below, keys already carrying their `proxy_` prefix), `nextUpstream ::
  [Text]` (`proxy_next_upstream`'s space-separated tokens - its own field
  because nginx's syntax for it doesn't fit the generic `key value;`
  shape), and `setHeader :: KeyMap Text` (`proxy_set_header`'s name->value
  pairs). An absent `proxy` key parses to `emptyProxyParameters` (all three
  fields empty) via `parseOptionalProxy`, rather than `Nothing` - there's
  nothing to unwrap at any call site. A previous version of this code kept
  a `defaultProxyParams` table (`proxy_http_version 1.1`, etc.) merged in
  at either parse or render time; it was removed because every value in
  that table was already nginx's own built-in default for that directive
  (confirmed against nginx's docs) - omitting a directive entirely gets
  identical behavior from nginx itself, so `renderProxyBlock` only ever
  emits what was actually specified. When nothing was specified,
  `renderProxyBlock`/`indentLines` render to an empty `Text`, which still
  shows up as one blank line in the surrounding `T.unlines` output (an
  earlier `nullProxyParameters` guard suppressed that line specifically,
  but was removed as not worth the extra function for a blank line nginx
  itself ignores). Keeping a hand-maintained copy of nginx's defaults was
  redundant at best and a silent drift risk at worst (nginx has already
  changed at least one of these defaults across versions).

- **`Location.proxy_pass` carries nginx's own full `proxy_pass` target,
  scheme included** (e.g. `"http://backend"` or `"https://backend"`), not
  just a bare upstream name with a scheme hardcoded onto it at render time.
  This is why it stays outside `ProxyParameters` as its own plain field
  (also because it's the one proxy-module directive that's location-only,
  not valid at the server level - see the top of the Proxy section in
  `Types.hs`): the KV entry itself decides whether a location proxies to
  plain HTTP or TLS upstream, not this code.

- **Ordered-list-of-tagged-variants pattern**, used for anything where
  nginx evaluates multiple directives of the same kind in the order
  they're written (order-sensitive, can't be a `Map` or unordered
  collection):
  - `RewriteModuleDirective = Return {..} | Rewrite {..} | Break`, tagged by
    a JSON `"type"` field. Replaces an earlier `LocationReturn`/`locReturn`
    design. Shared as `rewrite_directives :: [RewriteModuleDirective]` on
    `Location`, `ServerConfig`, and `ConditionalResponse`.
  - `AccessRule = AccessRule { direction :: AccessDirection, value :: Text }`
    where `AccessDirection = Allow | Deny` - modeled as a bare enum (like
    `MatchType`/`RewriteFlag`) plus a separate `value` field, rather than
    embedding the value in each constructor. `value` is intentionally a
    free-form string (address/CIDR/`unix:`/`all`) - not validated further,
    `nginx -t` is the real validator. Shared as `access_rules` on `Location`
    and `ServerConfig`.

- **`ServerConfig.extra_directives :: [(Text, Text)]`** - a catch-all for
  the rest of `ngx_http_core_module`'s server-context directives not
  explicitly modeled (`client_max_body_size`, `server_tokens`,
  `error_page`, ...), rendered verbatim as `key value;`. An ordered assoc
  list rather than a `KeyMap`, same reasoning as `extra_headers`/
  `rewrite_directives`/`access_rules` above: nginx allows some directives
  (e.g. `error_page`) more than once in the same `server {}` block, which a
  one-value-per-key map can't represent. Server-context only for now (not
  shared with `Location`) since the immediate need was core-module
  directives that only make sense once per server. This is also why
  `ServerConfig` no longer has a dedicated `hsts :: Maybe Text` field: HSTS
  is just one `add_header` call
  (`("add_header", "Strict-Transport-Security \"...\" always")`), fully
  expressible as one `extra_directives` entry with no special-cased
  rendering logic of its own - a purpose-built field for one specific
  header wasn't worth keeping once the generic mechanism could say the
  same thing.

- **`ServerConfig.server_name :: [Text]`, not `Text`, and deliberately kept
  as its own required field rather than folded into `extra_directives`.**
  nginx's own `server_name name ...;` takes one or more space-separated
  names/wildcards/regexes, so a single `Text` couldn't represent more than
  one - confirmed against nginx's own `ngx_http_core_module` docs, which
  also confirm `server_name` defaults to `""` (i.e. it's actually optional
  in real nginx). It stays mandatory and first-class here anyway, unlike
  `hsts`: `server_name` is a defining property of every server block this
  project renders (not a one-off directive someone might reasonably
  forget), so requiring it in the KV entry catches a missing/omitted name
  at parse time rather than silently producing a nameless server block.

- **`DuplicateRecordFields` + `OverloadedRecordDot`** everywhere a field
  name (`name`, `resolver`, `proxy`, `extra_headers`, `rewrite_directives`,
  `access_rules`) is genuinely the same concept across multiple types
  (`Upstream`/`Location`/`ServerConfig`) - no per-type prefixing needed,
  `value.field` resolves by the receiver's type.

- **Single-use helper functions are `where`-local to their one call site**
  (not top-level) - e.g. `accessDirectionText` lives inside `AccessRule`'s
  `toNginxConf`, `matchModifier` inside `Location`'s, `rewriteFlagText`
  inside just the `Rewrite` equation of `RewriteModuleDirective`'s
  `toNginxConf`, `checkRawProxyParam`/`expectHeaderString`/`normalizeKey`
  inside `parseProxyParams`, the various `defaultXParams` inside their one
  consuming `FromJSON` instance (`Resolver`'s and `UpstreamServer`'s -
  `ProxyParameters` no longer has one, see above). Only genuinely shared
  helpers (`checkIsRawValue`, `renderRawKeyValue`, `parseProxyParams`,
  `parseOptionalProxy`, `emptyProxyParameters`,
  `renderProxyBlock`, `indentLines`, `renderHeader` - each used at 2+ call
  sites) stay at module top level.

- **`itraverse_`/`ifoldMap`** (from `indexed-traversable`'s
  `Data.Foldable.WithIndex`, since `KeyMap` has a `FoldableWithIndex Key`
  instance) used wherever a `KeyMap Value`'s keys are needed alongside its
  values (for error messages, or to render `key=value`), instead of
  round-tripping through `KM.toList`/tuples. Renaming/remapping keys (e.g.
  `parseProxyParams`'s `proxy_` prefix normalization) can NOT use
  `itraverse`/`ifoldMap`/`imap` - those preserve a container's existing
  keys and only transform/fold values; renaming keys requires rebuilding
  the container via `KM.fromList`, which is why that one step is still a
  list comprehension even though the adjacent validation step next to it
  uses `itraverse_`.

- **No `rejectUnknownFields`** - extra/unrecognized JSON fields are
  silently ignored everywhere (aeson's default), by explicit choice: an
  earlier attempt at strict unknown-field rejection was reverted because
  parsing should not fail just because a KV blob has stray fields.

## Main.hs: fetch, decode, render

- **One invocation mode**: `main` runs as the handler of a
  `consul watch -type=keyprefix` on the servers/upstreams prefix - the
  prefix lives in the watch definition, never as a flag of this program.
  That watch can be either a standalone `consul watch ...` process or a
  `"watches"` stanza in the agent's own config (e.g. `consul.json`) -
  both are the same underlying Consul watch mechanism and spawn the
  handler identically (a JSON array of KV entries, or `null` for zero
  matches, piped to its stdin), so this program works unmodified under
  either. Fires both for every KV change AND once immediately at
  registration (agent startup, for the config-stanza form), since a
  blocking-query-based watch has no prior index to wait on the first time
  it runs and so fires unconditionally as soon as it's registered (this
  is what makes a separate "pre-start `ExecStartPre`" invocation
  unnecessary: `nginx.service` just orders itself after the render this
  first, automatic firing produces - e.g. via a systemd path unit gating
  on the "current" symlink a swap step produces - rather than this
  program needing a second invocation mode of its own).

- **One-shot, not long-running.** Consul's agent holds the persistent
  watch; it spawns this program fresh on every detected change (and once
  at startup, see above) and waits for it to exit. This program has no
  internal loop/poll/listen - `main` is just parse args -> get bytes ->
  decode -> one render -> exit.

- **`main` reads stdin directly (`LBS.getContents`), no wrapper
  function.** This is the exact bytes Consul hands a `keyprefix` watch
  handler (a JSON array of KV entries, or the literal JSON value `null`
  when nothing currently matches the watched prefix - see `decodeKvBatch`
  below), no network fetch at all. Reading stdin can't itself fail the
  way a network fetch can, so there's no `Either`-wrapping "fetch bytes"
  function to speak of - just `body <- LBS.getContents` inline in `main`.
  An earlier version of this program instead had a `fetchBytesStdin`/
  `fetchBytesHttp` pair - the latter an authoritative
  `GET /v1/kv/<prefix>?recurse=true` against Consul's own HTTP API, kept
  side by side as a swappable alternative in case stdin-trusting turned
  out to be a problem, both wrapped in `IO (Either T.Text LBS.ByteString)`
  so either could be swapped in behind one call site. The HTTP path was
  deliberately removed once the only remaining justification for it
  - resilience against a missed watch invocation - turned out to be far
  narrower than it first looked: a Consul agent *restart* doesn't lose
  anything (it just re-registers the same watch, which fires again
  immediately, see "One invocation mode" above); the only real gap is the
  handler process itself dying mid-invocation (OOM-killed, crashes, a
  disk-write failure) with no further KV write and no agent restart
  afterward - narrow enough not to justify a second fetch path and the
  `--consul-addr`/`--kv-prefix` CLI surface (and `http-conduit`/
  `http-types` dependencies) it required. Once only the stdin path was
  left, the `Either`-wrapping - which only ever existed to let a fallible
  HTTP fetch and an infallible stdin read share one signature - had
  nothing left to justify it either, so it went too.

- **`decodeKvBatch :: LBS.ByteString -> Either T.Text ([Server],
  [Upstream])`** - decodes the raw bytes read off stdin into every
  `Server`/`Upstream` among them. Decodes as `Maybe [Value]`, not
  `[Value]` outright: Consul's own `keyprefix` watch handler sends the
  literal JSON value `null` (not an empty array) when nothing currently
  matches the watched prefix - verified against a real running agent, and
  initially missed, since it first surfaced as a bug (a legitimate "zero
  entities" render was misreported as an unparseable-response failure).
  `concat` on the resulting `Maybe [Value]` folds `Nothing` to `[]` and
  `Just vs` to `vs` for free, since `Maybe` is already `Foldable`. A
  `Left` means we couldn't make sense of the body AT ALL (unparseable
  JSON, or some element failing `decodeKvEntry`), and is deliberately NOT
  a crash (no `ioError`/uncaught exception). `main` prints it to stderr
  and skips rendering entirely. Rationale for why a crash is worse here
  than in most programs: as a watch handler, an uncaught exception is not
  meaningfully different from a clean non-zero exit (Consul just logs it
  and moves on, no automatic retry) - but it IS worse than a clean,
  informative stderr message plus exit code for whoever's tailing
  Consul's own logs.

- **`main` separately refuses to render when `servers` comes back empty**,
  even though that's a fully legitimate `decodeKvBatch` result (see
  above - a `null`/zero-match payload is not a decode error). A server
  block is what nginx actually listens on; an upstream on its own binds
  nothing. Rendering a generation with zero servers - and letting a
  symlink-swap script put it live - would mean nginx no longer listens on
  any of its configured ports, which is a far worse failure mode than
  just not producing a new generation at all. Zero *upstreams* alone is
  fine and renders normally (a server may simply not proxy to one). This
  check is intentionally separate from `decodeKvBatch`'s own `Left`/
  `Right` distinction - it does NOT change what counts as a decode error,
  it's a second, render-time guard on top of a successful decode.

- **One file per server/upstream, not one shared file.**
  `renderGeneration` writes each server to its own `servers/<name>.conf`
  and each upstream to its own `upstreams/<name>.conf`, both inside a
  fresh `<conf-dir>/<timestamp>/` directory (`%Y%m%d%H%M%S`,
  filesystem-safe and lexicographically sortable) - never touching
  `<conf-dir>` itself or any earlier generation. Two subdirectories rather
  than one flat directory since a server and an upstream can legitimately
  share a name; nginx doesn't care which file an `upstream {}`/`server {}`
  block physically lives in, only that both end up `include`d somewhere
  under the `http` context. This was a deliberate move away from an
  earlier single-shared-file design (`generated.conf`, staged as `.new`,
  backed up as `.bak`, renamed into place): one file per entity means an
  unrelated server/upstream's render doesn't touch/rewrite one that didn't
  change, and it's easier to debug (`ls conf.d/<timestamp>/servers/` gives
  a legible per-server view). Trade-off accepted: this does NOT give
  per-entity *validation* isolation (`nginx -t` still validates the fully
  merged config regardless of file layout - one bad server still fails
  validation for everyone), and it introduces an orphan-cleanup problem
  that a single shared file didn't have (see below).

- **stdout is reserved for exactly one thing**: on success, `main` prints
  ONLY the new generation directory's path to stdout (`putStrLn genDir`) -
  meant to be captured directly (`genDir=$(nginx-lb-render ...)`) by
  whatever wrapper does the symlink swap. Every diagnostic (warnings from
  decoding/assembly, the "rendered N server(s) to ..." confirmation, the
  `Left` fetch-failure message) goes to stderr instead.

## What's deliberately NOT done yet

This program stops at "write the new generation directory and print its
path" - on purpose, matching the confd `check_cmd`/`reload_cmd` and
consul-template `exec` idiom already used elsewhere in this repo for TLS
cert rotation (render -> validate -> reload). None of the following is
implemented, and is left to whatever wraps this binary:

1. **The symlink swap + test + reload/revert flow.** nginx's `nginx.conf`
   should `include <stable-path>/current/*.conf;`, where `current` is a
   symlink, not a real directory. The wrapper's job:
   - Atomically repoint `current` at the new generation directory (create
     a new symlink under a temp name, `rename()` it over `current` -
     POSIX guarantees that rename is atomic, so nginx never observes a
     half-swapped state).
   - Run `nginx -t`. This is also the safety net for `tlsCertPath`
     (`app/Types.hs`): nginx opens every `ssl_certificate`/
     `ssl_certificate_key` path while building the SSL context, so a
     missing or corrupt/mismatched cert-key pair at that fixed path (see
     "TLS cert paths" below) fails the test with the path named in the
     error, before anything reloads. It does NOT catch an expired cert
     (no `notBefore`/`notAfter` check at load time - that's a client-side
     TLS-handshake concern), a broken chain of trust, or a `server_name`/
     SAN mismatch - those are outside `nginx -t`'s scope entirely.
   - On failure: repoint `current` back to the previous generation
     (untouched on disk) - nginx never reloaded, so live traffic was never
     affected.
   - On success: `nginx -s reload` / `systemctl reload nginx`.
   This is why stdout is reserved for just the path - so this wrapper can
   trivially capture it.

2. **Pruning old generation directories.** Nothing currently deletes a
   generation directory once a newer one replaces it as `current`'s
   target - disk usage grows unboundedly over time. Whatever does the
   symlink swap should also prune generations older than N, or older than
   the one still referenced by a `.bak`-equivalent rollback target.

3. **A hard timeout around the whole invocation.** Today there's no
   explicit timeout in this code - `main`'s `LBS.getContents` on stdin
   blocks until Consul closes the pipe, and there's no
   `System.Timeout.timeout` wrapping anything. As the watch handler, a
   hung invocation blocks that specific watch indefinitely (Consul doesn't
   impose its own timeout on exec-style handlers). Recommended fix is at
   the invocation layer (`timeout 20s` in the watch's own `args`), not
   inside this program.

4. **KV seeding/bootstrap** for the log-processor's existing routes - a
   manual, later step, not automated by anything here.

## TLS cert paths

Certs are generated/rotated by Vault Agent, entirely independently of
this program - `tlsCertPath` (`app/Types.hs`) is just an opaque `Text`
this program renders verbatim into `ssl_certificate`/
`ssl_certificate_key`; it never generates, validates, or manages the
file itself. Deliberately **not** timestamped the way `--conf-dir`'s own
generations are:

- Each cert lives at one **fixed** path (e.g. `$prefix/certs/<name>/
  server.pem`), decided once when a server's KV entry is first written,
  and never changes again. Vault Agent's own `template` stanza already
  overwrites that fixed destination atomically (temp file + `rename()`)
  on every renewal - the same atomicity guarantee a timestamped-
  generation-plus-`current`-symlink scheme exists to provide, so adding
  that scheme on top of Vault Agent's own atomic writes would be
  redundant complexity, not an additional safety property.
- This keeps the two systems fully decoupled: a pure cert rotation never
  requires a new Consul KV write or a re-render through this program at
  all - just `nginx -s reload` (nginx caches loaded certs at startup/
  reload, so it needs that nudge to pick up new bytes at the same path,
  even though the path itself never moved). That reload is Vault Agent's
  own `exec` post-template hook's job, same idiom as this repo's other
  confd/consul-template TLS rotation flows.
- The trade-off accepted by *not* giving certs their own timestamped-
  generation-plus-rollback scheme: no automatic revert if a renewed cert
  turns out to be bad. `nginx -t` (see "What's deliberately NOT done
  yet" above) does catch a missing or corrupt/mismatched file at that
  fixed path, but not an expired-but-otherwise-valid one - that's on
  Vault Agent's own renewal correctness and/or external monitoring, not
  something either this program or the reload step surfaces.
- If per-cert rollback ever becomes a real requirement, the fix is
  `$prefix/certs/<name>/<timestamp>/` plus a `$prefix/certs/<name>/
  current` symlink **per cert name**, rotated independently of every
  other cert (unlike `--conf-dir`'s single shared timestamp, which has to
  cover the whole server/upstream batch atomically - individual certs
  have no equivalent "must all change together" constraint, so batching
  them under one shared timestamp would only add unnecessary churn).

## Deferred ideas (discussed, explicitly not pursued now)

- **Eliminating the old fold-based grouping via per-entity files -
  partially superseded, see below.** The original thought experiment:
  since `Upstream`'s and `Location`'s `NginxConf` instances are already
  fully self-contained (no dependency on `Server`), you *could* split
  every entity - servers, upstreams, AND locations - into its own KV
  entry/file and let nginx's own `include` globs do the assembly, with
  zero grouping in Haskell. What actually happened is narrower:
  `upstreams` got promoted to its own top-level KV entity/file (see "KV
  layout" above), but `locations` did NOT - they still arrive nested
  inside their server's single KV value and render into that server's one
  file. The full per-entity-files version was still rejected for the
  reason below (locations tripling the orphan-cleanup problem for no
  upstream-sharing benefit, since a location genuinely IS server-scoped in
  nginx, unlike an upstream); the old fold was eliminated anyway, but via
  the *other* deferred idea below (the Nix-side merge), not via
  per-entity KV files.

- **A Nix module system to do the config+locations merge entirely
  upstream of Consul KV - underway.** If different Nix modules could each
  contribute a `location`/server-level setting (Nix's own module-merge
  semantics - list concatenation, `mkMerge`/priorities for scalars - the
  same pattern NixOS's own `services.nginx.virtualHosts` already uses
  across modules), the fully-merged per-server value could be serialized
  to JSON and pushed to Consul KV as one key per server, collapsing the
  KV layout down to flat top-level entities. The Haskell side of this is
  now done (see "KV layout" and "Types.hs and NginxConf.hs" above - the
  old fold-based assembly is gone, since nothing arrives split across
  multiple KV entries anymore). NOT yet done: the actual Nix module
  (option schema,
  the module-merge wiring itself) and the mechanism that
  pushes the merged JSON to Consul KV - both intentionally out of scope
  for the KV-flattening work and left for later, separate work.

- **Relative paths in nginx's `include`don't help with per-entity files.**
  Confirmed via nginx's own docs (`-p`/`--prefix`): a relative path (no
  leading `/`) in ANY config directive, no matter how deeply nested the
  `include` chain, resolves against nginx's single global prefix path, NOT
  relative to the directory of the file containing the directive. So a
  per-server skeleton file can't portably say `include locations/*.conf;`
  and have it scope to its own subdirectory - every server's rendered file
  would need its own distinguishing absolute (or prefix-relative) path
  baked in regardless, which is the same "each piece needs to know which
  server it belongs to" problem grouping already solves.

## Testing

`test/Spec.hs` is a proper cabal `test-suite` (`cabal test`, or `nix
build`/`nix flake check`, which runs it as part of the package's checkPhase)
- not a standalone `nix-shell`-shebang script. There's no separate library
component: the test suite just recompiles `Types`/`NginxConf` alongside
`Spec.hs` via `other-modules`, since splitting them into a library only
to share them with one test suite wasn't worth the extra stanza.

Every fixture and inline JSON payload is built as an aeson `Value` via
`object`/`.=` (which construct their underlying `KeyMap` via `KM.fromList`)
rather than as hand-escaped JSON text - `decodeOrFail` works directly on
`Value`s (via `parseEither parseJSON`), so there's no string-escaping to
get wrong and no redundant JSON-parsing round-trip for values that are
already in memory as Haskell data. `decodeServerEntry`/
`decodeUpstreamEntry` build a `Server`/`Upstream` fixture directly -
`Named nm <$> decodeOrFail body` - rather than going through
`decodeKvEntry`'s Consul KV envelope (base64, `"Key"` parsing): that
envelope is `Main.hs`'s own concern, not something these config-generation
tests need to re-exercise, and building `Named` directly is possible
precisely because `Named` has no `FromJSON` instance to route around in
the first place.

Coverage is deliberately scoped to **nginx config generation** - decode
failure modes (missing fields, invalid base64, unrecognized KV key
shapes, and so on) are not tested at all; aeson's own parser already
fails loudly on invalid JSON, and `decodeKvEntry` itself lives in
`Main.hs` now, entirely outside what `test/Spec.hs` touches. Coverage
includes rendering edge cases like the CORS-preflight
`ConditionalResponse` example, `ProxyParameters`' typed `next_upstream`/
`set_header` handling, and the "nothing rendered when `proxy` is unset"
case. Worked-example fixtures use deliberately generic names
(`foo`/`bar`/`backend`, `dns-server-1`) rather than the log-processor's
real route names, to keep the tests self-explanatory independent of that
history. `Main.hs`'s own IO layer (`main`'s stdin read,
`decodeKvEntry`'s KV-envelope decoding, `renderGeneration`'s filesystem
writes) is NOT covered by `test/Spec.hs` at all - no tests exercise that
behavior end-to-end today.
