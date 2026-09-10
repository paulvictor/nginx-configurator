# A plain terranix module (terranix modules are evaluated the same way any
# NixOS-style module is, via lib.evalModules - see terranix.org's "Modules"
# doc page) - a *sibling* list entry to nginx-configurator's `ngnixModule`
# in flake.nix's `terranix.terranixConfigurations.consul-kv.modules`, not
# something that `imports` it. `config.ngnix.settings` below is available
# here simply because both modules are merged together in the same
# `lib.evalModules` call - no serialization step in between.
{ config, lib, ... }:
{
  # Sample data - replace with your own. Validated against ngnix's own
  # schema (nginx-configurator's nix/modules/servers.nix/upstreams.nix).
  # 3 servers, hand-written to each show a different mix of the schema's
  # optional fields; 30 upstreams, generated below for variety without
  # 30 near-duplicate blocks.
  ngnix.settings = {
    servers = {
      web = {
        server_name = [ "www.example.com" "example.com" ];
        listen = [
          { port = 80; }
        ];
        http2 = true;
        extra_headers = [{ "X-Frame-Options" = "DENY"; }];
        proxy = {
          proxy_next_upstream = [ "error" "timeout" ];
          proxy_set_header.Host = "$host";
        };
        rewrite_directives = [
          { rewrite = { regex = "^/old/(.*)"; replacement = "/new/$1"; flag = "permanent"; }; }
        ];
        access_rules = [
          { type = "allow"; value = "10.0.0.0/8"; }
          { type = "deny"; value = "all"; }
        ];
        extra_directives = [{ client_max_body_size = "10m"; }];
        locations = [
          { path = "/"; proxy_pass = { upstream = "app-0"; }; }
          {
            path = "/api";
            match = "prefix_exact";
            proxy_pass = { upstream = "app-1"; };
            proxy.proxy_set_header."X-Real-IP" = "$remote_addr";
          }
          { path = "/health"; access_log = false; }
          {
            path = "/cors";
            conditional_responses = [{
              condition = "$request_method = 'OPTIONS'";
              extra_headers = [{ "Access-Control-Allow-Origin" = "*"; }];
              rewrite_directives = [{ return = { code = 204; }; }];
            }];
          }
        ];
      };

      api = {
        server_name = [ "api.example.com" ];
        listen = [{ port = 8080; }];
        locations = [
          {
            path = "^/v[0-9]+/.*";
            match = "regex";
            proxy_pass = { upstream = "app-2"; };
          }
          { path = "/internal"; match = "regex_ci"; rewrite_directives = [{ break = { }; }]; }
        ];
      };

      admin = {
        server_name = [ "admin.internal" ];
        listen = [{ port = 8443; }];
        access_rules = [
          { type = "allow"; value = "10.1.0.0/16"; }
          { type = "deny"; value = "all"; }
        ];
        locations = [
          {
            path = "/";
            proxy_pass = { upstream = "app-3"; };
          }
        ];
      };
    };

    upstreams = lib.listToAttrs (map
      (i: {
        name = "app-${toString i}";
        value =
          let
            backendCount = 1 + lib.mod i 3;
            backends = map
              (j: {
                address = "app-${toString i}-${toString j}.service.consul:8080";
                parameters = {
                  weight = 1 + j;
                  resolve = true;
                  max_fails = 2 + lib.mod i 4;
                  fail_timeout = "${toString (5 + lib.mod i 3 * 5)}s";
                  backup = j == backendCount - 1 && backendCount > 1;
                };
              })
              (lib.range 0 (backendCount - 1));
          in
          {
            servers = backends;
            # Every backend above sets resolve = true (this demo models
            # Consul-DNS-style service routing, never static IPs) - resolver
            # and zone_size are both required by nginx whenever any backend
            # does, so unlike keepalive below, these aren't conditional.
            resolver.address = "10.0.0.2:53";
            zone_size = "2m";
          }
          // lib.optionalAttrs (lib.mod i 3 == 0) {
            keepalive = 32;
            keepalive_requests = 100;
            keepalive_timeout = "60s";
          };
      })
      (lib.range 0 29));
  };

  # Adjust to your actual Consul cluster/ACL setup.
  terraform.required_providers.consul = {
    source  = "hashicorp/consul";
    version = "2.23.0";
  };
  provider.consul.address = "127.0.0.1:8500";

  # consul_keys (rather than consul_key_prefix) manages only the exact
  # keys listed here - no prefix-wide pruning, so a renamed/removed server
  # or upstream would otherwise leave its old key behind in Consul; each
  # entry's own `delete = true` below has Terraform actually remove it
  # from Consul instead, whenever that entry disappears from the list (or
  # the whole resource is destroyed). The opposite tradeoff from
  # consul_key_prefix: no "prefix must start empty" restriction, so this
  # can coexist with an already-populated "nginx/conf/" tree with no
  # one-time `terraform import` needed first.
  resource.consul_keys.nginx.key =
    (lib.mapAttrsToList
      (name: cfg: { path = "nginx/conf/servers/${name}"; value = builtins.toJSON cfg; delete = true; })
      config.ngnix.settings.servers)
    ++
    (lib.mapAttrsToList
      (name: cfg: { path = "nginx/conf/upstreams/${name}"; value = builtins.toJSON cfg; delete = true; })
      config.ngnix.settings.upstreams);
}
