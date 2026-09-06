let
  ghcVersion = "ghc910";
in
{
  flake.overlays.nginx-configurator = final: prev: {
    nginx-configurator = final.haskell.packages.${ghcVersion}.callCabal2nix "nginx-configurator"
      (final.nix-gitignore.gitignoreSource [ ] ../nginx-configurator)
      { };
  };

  perSystem = { pkgs, ... }:
    let
      haskellPackages = pkgs.haskell.packages.${ghcVersion};
    in
    {
      devShells.default = haskellPackages.shellFor {
        packages = _: [ pkgs.nginx-configurator ];
        withHoogle = true;

        nativeBuildInputs = with haskellPackages; [
          cabal-install
          ghcid
        ];
      };
    };
}
