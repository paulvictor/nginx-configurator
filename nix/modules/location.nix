{ lib, ... }:
with lib;
with types;
let
  common = import ./common.nix { inherit lib; };
  helpers = import ./helpers.nix { inherit lib; };
  rewriteModuleDirective = import ./rewrite_module_directive.nix { inherit lib; };
in
{
  options = {
    path = mkOption {
      type = str;
      description = ''Real nginx path, e.g. "/foo/bar".'';
    };

    match = mkOption {
      type = enum [ "exact" "prefix_exact" "prefix" "regex" "regex_ci" ];
      default = "prefix";
      description = ''
        "exact" -> "=", "prefix_exact" -> "^~" (stop regex search),
        "prefix" -> no modifier, "regex" -> "~", "regex_ci" -> "~*".
      '';
    };

    proxy_pass = mkOption {
      type = nullOr (submodule {
        options = {
          scheme = mkOption {
            type = enum [ "http" "https" ];
            default = "http";
          };
          upstream = mkOption {
            type = str;
            description = ''
              The upstream name to proxy to - a key present in the
              top-level "upstreams" attrset.
            '';
          };
        };
      });
      default = null;
      description = ''
        nginx's own "proxy_pass" directive takes one bare string (e.g.
        "proxy_pass http://backend;") - Types.hs deliberately deviates
        from that and keeps "scheme"/"upstream" as separate fields all
        the way through; NginxConf composes the literal directive text.
      '';
    };

    proxy = mkOption {
      type = submodule ./proxy_parameters.nix;
      default = { };
      description = ''
        proxy_http_version/proxy_set_header/proxy_next_upstream* - only
        rendered when proxy_pass is set.
      '';
    };

    rewrite_directives = mkOption {
      type = listOf rewriteModuleDirective.type;
      default = [ ];
      apply = map rewriteModuleDirective.toWireShape;
      description = "return/rewrite/break, in order.";
    };

    access_log = mkOption {
      type = bool;
      default = true;
      description = "Whether to log this location's requests.";
    };

    extra_includes = mkOption {
      type = listOf str;
      default = [ ];
      description = "Static, Nix-managed file paths.";
    };

    extra_headers = mkOption {
      type = attrListOf str;
      default = [ ];
      apply = helpers.pairListToArray;
      description = "Extra add_header name/value pairs (e.g. CORS).";
    };

    conditional_responses = mkOption {
      type = listOf (submodule ./conditional_response.nix);
      default = [ ];
      description = "e.g. CORS preflight handling.";
    };

    access_rules = mkOption {
      type = listOf (submodule common.accessRule);
      default = [ ];
      description = "allow/deny, in order.";
    };

    extra_directives = mkOption {
      type = attrListOf str;
      default = [ ];
      apply = helpers.pairListToArray;
      description = ''
        Catch-all for any other ngx_http_core_module location-context
        directive not explicitly modeled above, rendered verbatim as "key
        value;". An ordered attribute list (list format: [{"error_page" =
        "404 /404.html";} ...], not the attrset format), so a directive
        nginx allows multiple times in one location block can appear more
        than once here too - same shape as ServerConfig's own
        extra_directives.
      '';
    };
  };
}
