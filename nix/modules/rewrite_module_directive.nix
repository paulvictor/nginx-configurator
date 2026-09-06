{ lib, ... }:
with lib;
with types;
let
  returnDirective = submodule {
    options = {
      type = mkOption {
        type = enum [ "return" ];
        default = "return";
      };
      code = mkOption {
        type = int;
      };
      value = mkOption {
        type = nullOr str;
        default = null;
        description = ''
          The bare "return URL;" (implicit 302) shorthand isn't modeled,
          same as Types.hs - write it explicitly as code=302 instead.
        '';
      };
    };
  };

  rewriteDirective = submodule {
    options = {
      type = mkOption {
        type = enum [ "rewrite" ];
        default = "rewrite";
      };
      regex = mkOption {
        type = str;
      };
      replacement = mkOption {
        type = str;
      };
      flag = mkOption {
        type = nullOr (enum [ "last" "break" "redirect" "permanent" ]);
        default = null;
      };
    };
  };

  breakDirective = submodule {
    options = {
      type = mkOption {
        type = enum [ "break" ];
        default = "break";
      };
    };
  };
in
oneOf [ returnDirective rewriteDirective breakDirective ]
