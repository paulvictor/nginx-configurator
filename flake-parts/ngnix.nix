{
  flake.lib.ngnix = import ../nix/ngnix.nix;
  flake.lib.ngnixModule = ../nix/modules/mixin.nix;
  # terranix: `resource.consul_keys.nginx` from `ngnix.settings`; see the file.
  flake.lib.ngnixConsulModule = ../nix/modules/consul.nix;
}
