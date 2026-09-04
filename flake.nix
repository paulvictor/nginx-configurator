{
  description = "nginx-configurator, a Haskell package";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        haskellPackages = pkgs.haskell.packages.ghc910;

        pname = "nginx-configurator";
        src = pkgs.nix-gitignore.gitignoreSource [] ./.;

        package = haskellPackages.callCabal2nix pname src {};
      in
      {
        packages.${pname} = package;
        packages.default = package;

        apps.${pname} = flake-utils.lib.mkApp { drv = package; };
        apps.default = self.apps.${system}.${pname};

        devShells.default = haskellPackages.shellFor {
          packages = _: [ package ];
          withHoogle = true;

          nativeBuildInputs = with haskellPackages; [
            cabal-install
            ghcid
          ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
