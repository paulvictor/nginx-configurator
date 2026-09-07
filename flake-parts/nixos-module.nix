{
  flake.nixosModules.default = ../nix/nixos/nginx-config.nix;
  flake.nixosModules.nginx-config = ../nix/nixos/nginx-config.nix;
}
