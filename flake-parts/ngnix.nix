{
  flake.lib.ngnix = import ../nix/ngnix.nix;
  flake.lib.ngnixModule = ../nix/modules/mixin.nix;
}
