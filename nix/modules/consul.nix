{ config, lib, ... }:
let
  inherit (config.ngnix.settings) servers upstreams;

  # consul_keys (rather than consul_key_prefix) manages only the exact
  # keys listed here - no prefix-wide pruning, so a renamed/removed server
  # or upstream would otherwise leave its old key behind in Consul; each
  # entry's own `delete = true` has Terraform actually remove it from
  # Consul instead, whenever that entry disappears from the list (or the
  # whole resource is destroyed). The opposite tradeoff from
  # consul_key_prefix: no "prefix must start empty" restriction, so this
  # can coexist with an already-populated "nginx/conf/" tree with no
  # one-time `terraform import` needed first.
  keys = kind: lib.mapAttrsToList
    (name: cfg: {
      path = "${config.ngnix.key_prefix}${kind}/${name}";
      value = builtins.toJSON cfg;
      delete = true;
    });
in
# Importing this module is the switch: it turns `config.ngnix.settings` (read
# from the same module evaluation - the values are already in their final
# wire shape, never feed them back into `ngnixModule` as input) into the
# Terraform `consul_keys.nginx` resource nginx-configurator's watch reads.
# Needs a terranix tree (it defines `resource`); the keys live under
# `ngnix.key_prefix` (mixin.nix).
# Nothing is configured here beyond that: no `depends_on`, no
# `provider.consul` - whoever applies the Terraform does both.
{
  config = lib.mkIf (servers != { } || upstreams != { }) {
    resource.consul_keys.nginx.key = keys "servers" servers ++ keys "upstreams" upstreams;
  };
}
