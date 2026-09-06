{ lib, ... }:
with lib;
with types;
{
  freeformType = attrsOf (oneOf [
    bool
    int
    str
  ]);

  options = {
    address = mkOption {
      type = str;
      description = "The resolver's address, e.g. \"127.0.0.1:53\".";
    };
  };
}
