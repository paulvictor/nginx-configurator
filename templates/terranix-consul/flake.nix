{
  description = "Example: populate Consul KV from ngnix config via terranix + the Terraform consul provider";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    terranix = {
      url = "github:terranix/terranix/2.8.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nginx-configurator.url = "github:paulvictor/nginx-configurator";
  };

  outputs = inputs@{ flake-parts, terranix, nginx-configurator, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      imports = [ terranix.flakeModule ];

      # NOTE: terranix 2.8.0's flake-module only wires up flat, un-nested
      # `apps.init`/`apps.apply`/`apps.destroy` (matching its own release
      # notes) for a configuration named exactly "default" - naming it
      # anything else means those apps never get created at all.
      # `apps.default` itself (and so bare `nix run .`) does NOT work at
      # this version regardless of naming - a bug in flake-module.nix's own
      # `config.apps = cfg.terranixConfigurations // ...` (it merges the
      # raw per-configuration submodule - `modules`/`workdir`/`result`/... -
      # directly into `apps.<name>`, not an actual `{type;program;}` app
      # value), confirmed by reading the actual tagged source. Use
      # `nix run .#apply` / `.#init` / `.#destroy` explicitly instead.
      perSystem = { config, system, ... }: {
        # Overlaying `terraform` itself (rather than adding a separately
        # named package) means every internal reference to `pkgs.terraform`
        # - including terranix's own `result.terraformWrapper` default,
        # which hardcodes `runtimeInputs = [ pkgs.terraform ] ++ ...` at
        # this pinned version - transparently gets the plugin-bundled
        # version too. `_module.args` is shared across every module in this
        # flake-parts tree (same mechanism this repo's own root flake.nix
        # uses for its overlay), so this reaches terranix.flakeModule's
        # internals without needing to touch anything there directly.
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              terraform = prev.terraform.withPlugins (p: [ p.hashicorp_consul ]);
            })
          ];
        };

        terranix.terranixConfigurations.default.modules = [
          nginx-configurator.lib.ngnixModule
          ./consul-kv.nix
        ];

        # For inspection - `nix build .#terraform-config && cat result`
        # shows the actual generated config.tf.json without running
        # terraform at all.
        packages.terraform-config =
          config.terranix.terranixConfigurations.default.result.terraformConfiguration;
      };
    };
}
