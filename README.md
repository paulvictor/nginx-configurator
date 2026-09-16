# nginx-configurator + ngnix

Turns Consul KV data into nginx config. `server {}`/`upstream {}` blocks
(each server carrying its own nested `location {}` blocks) live as JSON
in Consul KV instead of static nginx config files; this repo provides
both the renderer and a typed way to author that JSON.

Two halves:
- **`nginx-configurator`** (Haskell) - a small CLI that reads a Consul
  `keyprefix` watch payload on stdin and renders it into a fresh,
  timestamped directory of `.conf` files. It only renders - it never runs
  `nginx -t`, reloads nginx, or swaps any `current` symlink; that's left
  to whatever invokes it (see `services.nginx-config` below).
- **`ngnix`** (Nix) - a NixOS-style module system, `nix/modules/`, that
  mirrors the Haskell side's JSON schema (`Types.hs`) option-for-option,
  so config can be authored as typed Nix instead of hand-written JSON,
  with `nginx -t`-equivalent typos (missing fields, wrong shapes) caught
  at `nix eval` time instead of at deploy time.

## Repo layout

- `nginx-configurator/` - the Haskell package (`app/`, `test/`, the
  `.cabal` file).
- `nix/modules/` - the `ngnix` schema, one file per `Types.hs` type.
- `nix/ngnix.nix` - the entrypoint tying the schema to the Haskell
  package (`ast`/`configFile`/`generated`).
- `nix/nixos/nginx-config.nix` - a NixOS module wiring a Consul agent
  watch to render → test → swap → reload.
- `flake-parts/` - flake outputs (auto-imported, one file per concern).
- `templates/terranix-consul/` - a `nix flake init` template: populate
  Consul KV from `ngnix` config via terranix + the Terraform Consul
  provider.

## Quickstart

Build/run the renderer directly:

```
nix build .#nginx-configurator
echo '[{"Key":"servers/web","Value":"<base64 JSON>"}, ...]' \
  | nix run .# -- --conf-dir /tmp/out
```

Author config in Nix instead of hand-written JSON:

```nix
ngnix.settings.servers.web = {
  server_name = [ "example.com" ];
  listen = [{ port = 80; }];
  locations = [{ path = "/"; proxy_pass.upstream = "app-0"; }];
};
ngnix.settings.upstreams.app-0.servers = [
  { address = "app-0.service.consul:8080"; }
];
```
then `flake.lib.ngnix.generated { inherit pkgs; modules = [ ./that-file.nix ]; }`
builds real `.conf` files for inspection, or `.configFile`/`.ast` for
just the JSON/attrset.

Deploy: `nixosModules.nginx-config` (`services.nginx-config.enable = true;`)
registers a Consul watch that renders/tests/swaps on every KV change - see
its own option docs. Populate the KV data itself with
`nix flake init -t github:paulvictor/nginx-configurator` (the
`terranix-consul` template) or any other means (`consul kv put`,
another Terraform provider, etc.) - the schema doesn't care how the KV
gets written, only its shape.

## More detail

- `DESIGN.md` - full design rationale, decision-by-decision, both halves.
- `MEMORY.md` - terse decisions log for whoever (human or agent) picks
  this repo up next.
