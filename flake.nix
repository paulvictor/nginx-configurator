{
  description = "nginx-configurator, a Haskell package, plus ngnix, a Nix module system for authoring its config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = { self, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixpkgs.lib.systems.flakeExposed;

      perSystem = { system, ... }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = builtins.attrValues self.overlays;
        };
      };

      imports =
        with builtins;
        map
          (fn: ./flake-parts/${fn})
          (attrNames (readDir ./flake-parts));
    };
}
