# MEMORY.md - for other LLM agents picking up this repo

Concise log of decisions already made, so you don't re-litigate them.
Full rationale lives in `DESIGN.md` (Part 1: `app/`, Part 2: `nix/`) -
this file is just the "what was decided," not the "why" in full.

## Repo layout

- `nginx-configurator/` - the Haskell package (app/, test/, the .cabal
  file, CHANGELOG.md, LICENSE). Moved here from the repo root so the top
  level stays clean; nothing cabal-specific lives outside this directory.
- `nix/modules/` - a Nix module system (NixOS-style options) mirroring
  every type in `nginx-configurator/app/Types.hs`.
- `nix/ngnix.nix` - the actual entrypoint tying the two together (name is
  a portmanteau of nginx + Nix). Assumes `pkgs` already has the overlay
  from this repo's own `flake.nix` applied (`pkgs.nginx-configurator`) -
  has zero Haskell-specific logic of its own.
- `.gitignore` lives only at the top level (not duplicated per-subdir);
  patterns without a leading `/` (e.g. `dist-newstyle/`) so they match at
  any depth.
- `flake.nix` builds the Haskell package via an overlay
  (`overlays.nginx-configurator`), sourced from `./nginx-configurator` via
  `nix-gitignore.gitignoreSourcePure [ "dist-newstyle" ] ./nginx-configurator`
  - deliberately NOT `gitignoreSource` (which requires a real `.gitignore`
    file at that exact path and errors under flakes' restricted
    self-source evaluation if one doesn't exist there).

## `nginx-configurator` (Haskell) - key decisions

- Consul KV: `servers/$name` and `upstreams/$name` are separate, flat,
  top-level entities - one full JSON value per name, no further nesting.
  The name comes from the KV key, never a `"name"` JSON field (`Named`
  wrapper in `Types.hs`).
- `Location`'s `locations` field is a plain JSON array (not an object
  keyed by invented per-location names) - nothing ever reads a
  location's name.
- `decodeKvEntry` lives in `Main.hs`, not `Types.hs` - it moved once
  `test/Spec.hs` stopped needing to route through it (tests build
  `Server`/`Upstream` fixtures directly via `Named`).
- `Main.hs` reads Consul KV JSON **from stdin only** - no HTTP fetch path
  anymore (an earlier `fetchBytesHttp` alternative was deliberately
  removed; see `DESIGN.md` Part 1 for why the "missed watch invocation"
  risk was judged too narrow to justify keeping it). This assumes it's
  invoked as a `consul watch -type=keyprefix` handler (either a
  standalone `consul watch` process or an agent-config `"watches"`
  stanza - both spawn the handler identically).
- `decodeKvBatch` decodes as `Maybe [Value]`, not `[Value]` - Consul's
  own `keyprefix` watch handler sends the literal JSON `null` (not `[]`)
  when nothing currently matches the watched prefix. This was a real bug
  found by testing against a live `consul agent`, not a guess.
- `main` refuses to render (exits 1) if `servers` comes back empty, even
  though that's a legitimate decode result - zero *upstreams* alone is
  fine. Rendering an empty generation and letting a swap script put it
  live would mean nginx listens on nothing.
- No cross-cutting "assertions" mechanism currently validates that a
  `proxy_pass` target is a real upstream name - tried and removed as
  "needs workarounds to get right"; both the Haskell side and the Nix
  side (below) currently leave this unvalidated. Revisit later, don't
  assume it's already handled.
- TLS certs: fixed, non-timestamped path per cert (`tlsCertPath` is one
  opaque string) - Vault Agent overwrites it in place on renewal; this
  program never manages cert files itself. `nginx -t` catches a missing
  or corrupt/mismatched cert-key pair but not an expired one.
- Test coverage is scoped to **nginx config generation only** - decode
  failure modes are not tested; `Main.hs`'s own IO layer (stdin read,
  filesystem writes) is not tested either.

## `nix/modules` (ngnix schema) - key decisions

- Every per-type file is a first-class module: a bare module body
  (`{ lib, ... }: { options = {...}; }`), not a pre-built
  `lib.types.submodule {...}` value - callers wrap it at the point of use
  (`lib.types.submodule ./resolver.nix`). This makes every file
  independently evaluable/documentable via a plain `imports = [...]`,
  which is the whole point (enables per-module doc generation).
- Two exceptions to "first-class module per file":
  - `ServerConfig`/`UpstreamConfig` are anonymous, locally-scoped
    submodules directly inside `servers.nix`'s/`upstreams.nix`'s own
    `attrsOf (submodule {...})` - not their own files, since "servers" IS
    just an attrset of `ServerConfig`s with no standalone reuse case.
  - `RewriteModuleDirective` (the one real sum type) stays one file with
    its three variants (`return`/`rewrite`/`break`) defined inline as
    distinct submodules combined via `types.oneOf` - a discriminated
    union has no single `options` body to expose the way other types do.
- Small types: shared-across-2+-files ones (`AccessRule`) live in
  `common.nix`; single-use ones (`MatchType`, `RewriteFlag`, `Listen`,
  the `proxy_pass` scheme/upstream shape) are inlined at their one use
  site, not given their own file. Plain shared *functions* (not types) go
  in a separate `helpers.nix` instead of `common.nix` - currently just
  `pairListToArray`.
- Option names are the actual JSON keys `Types.hs` reads, NOT the
  Haskell field names (these frequently differ, e.g. `AccessRule`'s
  Haskell field is `_direction` but the JSON key is `"type"`).
- Two different "extra JSON keys" shapes exist, do not conflate:
  `Resolver`/`ProxyParameters` flatten unknown keys onto their own
  object (`freeformType`); `UpstreamServer` nests them under a real
  `"parameters"` key (a normal nested option).
- `extra_headers`/`extra_directives` use `lib.types.attrListOf lib.types.str`
  (nixpkgs' own type for "ordered, same-key-can-repeat" data), not a
  custom pair-submodule. `proxy_pass` is authored as `{scheme; upstream;}`
  (not one opaque string) so `upstream` is at least structured, even
  though nothing currently validates it against `upstreams`.
- Both of the above get converted to `Types.hs`'s actual wire shape
  (`[[name,value],...]` arrays; a single `"scheme://upstream"` string)
  via `apply` on the option itself, NOT a `config` section - a module's
  `config` block can't reference that same option's own merged value
  without infinite recursion; `apply` post-processes the value before
  it's exposed anywhere, which is exactly the tool for "author shape A,
  report shape B."
- `nix/ngnix.nix` returns `{ ast; configFile; generated; }`, but these are
  **three independent functions**, not three pre-computed values - each
  takes the same `{ pkgs, lib ? pkgs.lib, modules ? [ ], specialArgs ? {
  } }`, so callers can use just one without the others (e.g. `ast`/
  `configFile` need no `pkgs.nginx-configurator` at all, only `generated`
  does). `ast` evaluates to the already-wire-ready config; `configFile`
  is that JSON as a real store path (`pkgs.formats.json {}`); `generated`
  is a `pkgs.runCommand` derivation that pipes `configFile`'s JSON
  through one `jq` expression (converting to the raw Consul-KV-batch
  shape, base64 via `@base64`) directly into `pkgs.nginx-configurator`,
  capturing the real rendered `.conf` files as a build output. The
  generation timestamp inside is whatever the Nix sandbox's clock happens
  to be - accepted, since this is for inspection/testing, not a live
  deployment artifact.

## Deferred ideas (not implemented yet, revisit later)

- Validate rendered nginx config as a Nix build-time check, before it ever
  reaches Consul/production - would catch "nginx-configurator emitted an
  invalid config" bugs at build/CI time instead of only discovering them
  when a real nginx tries to reload. Two complementary tools:
  - `nginx -t` - catches syntax/directive-context errors, but needs a
    *complete* wrapper `http {}` config that `include`s every rendered
    `server`/`upstream` fragment (so cross-references like `proxy_pass`
    resolve), and it actually opens `ssl_certificate`/`ssl_certificate_key`
    files - needs either a dummy self-signed cert substituted at the
    configured path, or those two directives stripped/rewritten, for the
    validation pass specifically.
  - `gixy` (confirmed packaged in nixpkgs as `pkgs.gixy`) - pure
    static/AST analysis of the config text, no certs or upstream
    resolution needed at all, so it sidesteps the cert problem entirely.
    Catches a different class of issues (alias traversal, SSRF-prone
    `proxy_pass` with variables, missing `resolver`, header-inheritance
    footguns).
  - Proposed shape: a new function alongside `ast`/`configFile`/
    `generated` in `nix/ngnix.nix` (e.g. `checked`) that builds the
    rendered output, assembles the wrapper config, and fails the Nix
    build if either tool fails.

## Things explicitly tried and rejected

- HTTP-fetch fallback in `Main.hs` (`fetchBytesHttp`) - removed; the
  residual "missed watch invocation" risk it covered turned out to be
  narrow (agent restarts self-heal via the watch's fire-on-register
  behavior).
- Cross-checking `proxy_pass.upstream` against `upstreams` via a NixOS
  `assertions` list - removed; needs workarounds to get right, revisit
  later.
- Merging domain-specific types into `lib.types` (e.g. `lib.types.nginx.*`)
  - rejected: not how nixpkgs itself does this anywhere, requires every
    consumer to use a non-vanilla `lib`, and risks namespace collisions.
    Plain explicit-import files (`common.nix`) do the same job with none
    of the downsides.
- Same idea, retried against `evalModules` specifically: `lib' = lib //
  { someHelper = ...; }; lib'.evalModules {...}` - does NOT thread
  `lib'` to modules. `evalModules`'s own signature is closed (no `...`,
  no `lib` parameter at all) and hardcoded to inject nixpkgs' own
  internal `lib` into every module - confirmed by actually running it
  (`attribute 'someHelper' missing` inside a test module). Plain
  explicit-import files (`helpers.nix`) are the only mechanism that
  actually works.
