{ lib, ... }:
with lib;
with types;
{
  options.upstreams = mkOption {
    type = attrsOf (submodule {
      options = {
        resolver = mkOption {
          type = nullOr (submodule ./resolver.nix);
          default = null;
          description = "Valid here too (ngx_http_core_module).";
        };

        servers = mkOption {
          type = listOf (submodule ./upstream_server.nix);
          description = ''nginx's own "server address [parameters];" entries.'';
        };

        keepalive = mkOption {
          type = nullOr int;
          default = null;
        };

        keepalive_requests = mkOption {
          type = nullOr int;
          default = null;
        };

        keepalive_timeout = mkOption {
          type = nullOr str;
          default = null;
        };

        zone_size = mkOption {
          type = nullOr str;
          default = null;
          description = ''e.g. "2m".'';
        };
      };
    });
    default = { };
    description = ''
      Consul KV upstreams/$name entries, same name-as-key convention as
      servers.
    '';
  };
}
