{ lib, ... }:
with lib;
with types;
{
  freeformType = attrsOf (oneOf [
    int
    str
  ]);

  options = {
    proxy_next_upstream = mkOption {
      type = listOf str;
      default = [ ];
      description = ''
        proxy_next_upstream's space-separated tokens, e.g.
        ["error" "timeout" "http_502"].
      '';
    };

    proxy_set_header = mkOption {
      type = attrsOf str;
      default = { };
      description = "proxy_set_header's name->value pairs.";
    };
  };
}
