{ lib, ... }:
{
  options.ngnix.settings = lib.mkOption {
    type = lib.types.submoduleWith { modules = [ ./servers.nix ./upstreams.nix ]; };
    default = { };
    description = ''
      ngnix's server/upstream configuration, namespaced under
      `ngnix.settings` so it can be mixed into any other module tree (e.g.
      a terranix configuration) without colliding with anything else that
      tree declares. See servers.nix/upstreams.nix (and, ultimately,
      Types.hs) for the schema this mirrors. Unrelated to - and not used
      by - this project's own ast/configFile/generated, which evaluate
      servers.nix/upstreams.nix bare at the top level instead, since they
      fully own that module tree with no foreign-collision risk to guard
      against.
    '';
  };
}
