{
  description = "nginx-configurator, a Haskell package, plus ngnix, a Nix module system for authoring its config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      pname = "nginx-configurator";

      overlay = final: prev: {
        ${pname} = final.haskell.packages.ghc910.callCabal2nix pname
          (final.nix-gitignore.gitignoreSourcePure [ "dist-newstyle" ] ./nginx-configurator)
          { };
      };
    in
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
          haskellPackages = pkgs.haskell.packages.ghc910;

          package = pkgs.${pname};
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
        }) // {
      overlays.${pname} = overlay;
    };
}
