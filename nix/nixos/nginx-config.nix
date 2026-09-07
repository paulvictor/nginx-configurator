# A real NixOS service module - unlike nix/modules/*.nix (pure, pkgs-free
# option schema mirroring Types.hs), this one uses pkgs/config to wire a
# Consul agent watch (https://developer.hashicorp.com/consul/docs/automate/watch)
# to nginx-configurator: render -> test the new path -> swap `current` ->
# reload. Deliberately does NOT start/manage nginx itself - a real running
# nginx (however it's set up) is entirely the deployer's own concern; this
# module only needs `nginx -t`/`nginx -s reload` as plain binary
# invocations, which is why the `-t` step uses its own self-contained stub
# `http{}` config rather than assuming a real nginx.conf exists anywhere.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nginx-config;

  # Everything here is static except the new generation's path (only known
  # at runtime, once nginx-configurator has actually rendered it) - so this
  # is a real derivation holding a template, with `@NEW_GEN@` substituted
  # in by the watch script below via `sed`. The `pid` path is fixed rather
  # than per-invocation-unique - `nginx -t` doesn't need a *unique* pid
  # path across invocations, just a *writable* one: contrary to the
  # initial assumption, `-t` does try to open the pid path (confirmed by
  # testing - a genuinely nonexistent parent directory fails the test with
  # "open() ... failed"), it just never actually starts the daemon or
  # leaves the pid file meaningfully populated, so a fixed path under
  # `/tmp` is fine.
  nginxTestConfTemplate = pkgs.writeText "nginx-config-watch-test.conf" ''
    events {}
    pid /tmp/nginx-config-watch-test.pid;
    error_log /dev/null;
    http {
      access_log off;
      include @NEW_GEN@/upstreams/*.conf;
      include @NEW_GEN@/servers/*.conf;
    }
  '';

  watchScript = pkgs.writeShellApplication {
    name = "nginx-config-watch";
    runtimeInputs = [ cfg.package pkgs.nginx pkgs.coreutils pkgs.gnused ];
    text = ''
      # Consul passes the keyprefix watch payload on stdin, unmodified.
      if ! new_gen="$(nginx-configurator --conf-dir "${cfg.confDir}")"; then
        echo "nginx-config-watch: nginx-configurator failed (decode error or no servers) - not touching current" >&2
        exit 1
      fi

      # nginx has nothing else to test against here (this module never
      # starts/manages a real nginx), so test a config that includes only
      # the new generation directly - BEFORE `current` is touched, so
      # `current` never points at untested config even transiently.
      test_conf="$(mktemp)"
      trap 'rm -f "$test_conf"' EXIT
      sed "s#@NEW_GEN@#$new_gen#g" "${nginxTestConfTemplate}" > "$test_conf"

      if ! nginx -t -c "$test_conf"; then
        echo "nginx-config-watch: nginx -t failed against new generation $new_gen - not swapping current" >&2
        exit 1
      fi

      ln -sfn "$new_gen" "${cfg.confDir}/current.tmp"
      mv -T "${cfg.confDir}/current.tmp" "${cfg.confDir}/current"
      nginx -s reload
    '';
  };

  watchSpecFile = (pkgs.formats.json { }).generate "nginx-config-watch.json" {
    watches = [{
      type = "keyprefix";
      prefix = cfg.keyPrefix;
      args = [ "${watchScript}/bin/nginx-config-watch" ];
    }];
  };
in
{
  options.services.nginx-config = {
    enable = lib.mkEnableOption "the nginx-configurator Consul watch integration";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nginx-configurator;
      description = ''
        The nginx-configurator package. Requires this flake's own
        `overlays.nginx-configurator` to already be applied to `pkgs`.
      '';
    };

    keyPrefix = lib.mkOption {
      type = lib.types.str;
      default = "nginx/conf/";
      description = ''
        The Consul KV key prefix to watch - matches the convention already
        used by nix/ngnix.nix's kvBatchJq and the terranix example
        ("nginx/conf/servers/<name>"/"nginx/conf/upstreams/<name>").
      '';
    };

    consulAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Address of the Consul server this node's own client agent should
        join (fed into `services.consul.extraConfig.retry_join`) - only
        meaningful when this module also enables the local agent
        (`services.consul.enable`, on by default). A watch registered via
        an agent's own config file always runs against that same local
        agent - there's no separate "remote address" for the watch itself.
      '';
    };

    confDir = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to the nginx conf directory - both nginx-configurator's own
        `--conf-dir` target (where timestamped generations are written)
        and where the `current` symlink lives.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.consul.enable = lib.mkDefault true;

    services.consul.extraConfig.retry_join =
      lib.mkIf (cfg.consulAddress != null) [ cfg.consulAddress ];

    # NOTE: extraConfigFiles is documented by nixpkgs' own services.consul
    # module as NOT triggering a Consul restart when its contents change -
    # a rebuild that changes keyPrefix (or otherwise regenerates this file)
    # may need an explicit `systemctl restart consul` to actually take
    # effect. Matching that documented behavior here rather than forcing
    # a restart ourselves.
    services.consul.extraConfigFiles = [ (toString watchSpecFile) ];
  };
}
