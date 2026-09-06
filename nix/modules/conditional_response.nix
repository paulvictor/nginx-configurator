{ lib, ... }:
with lib;
with types;
let
  rewriteModuleDirective = import ./rewrite_module_directive.nix { inherit lib; };
in
{
  options = {
    condition = mkOption {
      type = str;
      description = ''Raw nginx condition, e.g. "$request_method = 'OPTIONS'".'';
    };

    extra_headers = mkOption {
      type = attrListOf str;
      default = [ ];
      description = "Branch-only add_header pairs - see the note above.";
    };

    rewrite_directives = mkOption {
      type = listOf rewriteModuleDirective;
      default = [ ];
      description = ''
        Ordered - e.g. a single "return". nginx evaluates multiple such
        directives in the same context in the order they're written.
      '';
    };
  };
}
