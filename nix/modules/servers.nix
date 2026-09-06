{ lib, ... }:
with lib;
with types;
let
  common = import ./common.nix { inherit lib; };
  helpers = import ./helpers.nix { inherit lib; };
  rewriteModuleDirective = import ./rewrite_module_directive.nix { inherit lib; };

  listen = submodule {
    options = {
      port = mkOption {
        type = int;
      };
      ssl = mkOption {
        type = bool;
        default = false;
      };
      ipv6 = mkOption {
        type = bool;
        default = false;
      };
    };
  };
in
{
  options.servers = mkOption {
    type = attrsOf (submodule {
      options = {
        server_name = mkOption {
          type = listOf str;
          description = ''
            nginx's own "server_name name ...;" takes one or more
            space-separated names/wildcards/regexes.
          '';
        };

        listen = mkOption {
          type = listOf listen;
        };

        http2 = mkOption {
          type = bool;
          default = false;
        };

        tls_cert_path = mkOption {
          type = nullOr str;
          default = null;
          description = ''
            Same file used for cert + key. Should be a fixed, stable path
            that Vault Agent overwrites in place on renewal - see
            DESIGN.md's "TLS cert paths" section.
          '';
        };

        extra_headers = mkOption {
          type = attrListOf str;
          default = [ ];
          apply = helpers.pairListToArray;
          description = "Extra add_header name/value pairs, site-wide.";
        };

        resolver = mkOption {
          type = nullOr (submodule ./resolver.nix);
          default = null;
          description = "Valid here too (ngx_http_core_module).";
        };

        proxy = mkOption {
          type = submodule ./proxy_parameters.nix;
          default = { };
          description = ''
            Site-wide proxy_http_version/proxy_set_header/
            proxy_next_upstream*, inherited by every location unless a
            location sets its own.
          '';
        };

        rewrite_directives = mkOption {
          type = listOf rewriteModuleDirective;
          default = [ ];
          description = "return/rewrite/break, in order, at the server level.";
        };

        access_rules = mkOption {
          type = listOf (submodule common.accessRule);
          default = [ ];
          description = "allow/deny, in order, at the server level.";
        };

        extra_directives = mkOption {
          type = attrListOf str;
          default = [ ];
          apply = helpers.pairListToArray;
          description = ''
            Catch-all for any other ngx_http_core_module server-context
            directive not explicitly modeled above (e.g.
            "client_max_body_size", "server_tokens", "error_page"), rendered
            verbatim as "key value;". An ordered attribute list (list format:
            [{"error_page" = "404 /404.html";} ...], not the attrset format),
            so a directive nginx allows multiple times in one server block
            (e.g. several "error_page" lines) can appear more than once here
            too - same shape as extra_headers even though these are
            directive/value pairs, not headers.
          '';
        };

        locations = mkOption {
          type = listOf (submodule ./location.nix);
          default = [ ];
        };
      };
    });
    default = { };
    description = ''
      Consul KV servers/$name entries - the attrset key IS the name (see
      Named's own doc comment in Types.hs); each value is exactly a
      ServerConfig body, no name field.
    '';
  };
}
