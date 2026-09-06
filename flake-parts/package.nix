{
  perSystem = { pkgs, config, ... }:
    let
      package = pkgs.nginx-configurator;
    in
    {
      packages.nginx-configurator = package;
      packages.default = package;

      apps.nginx-configurator = {
        type = "app";
        program = "${package}/bin/nginx-configurator";
      };
      apps.default = config.apps.nginx-configurator;

      formatter = pkgs.nixpkgs-fmt;
    };
}
