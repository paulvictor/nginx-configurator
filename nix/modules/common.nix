{ lib }:
with lib;
with types;
{
  accessRule = {
    options = {
      type = mkOption {
        type = enum [ "allow" "deny" ];
        description = "allow or deny.";
      };
      value = mkOption {
        type = str;
        description = ''
          A free-form address, CIDR, "unix:", or the literal "all" - not
          validated further here, same as Types.hs: "nginx -t" is the
          real validator.
        '';
      };
    };
  };
}
