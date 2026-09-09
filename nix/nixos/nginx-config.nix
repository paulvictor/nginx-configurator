# NixOS service module wiring a Consul agent watch to nginx-configurator:
# render -> test -> swap `current` -> reload. Does not start/manage nginx.
#
# Reload runs as the unprivileged "consul" user via `systemctl reload`,
# authorized by a narrow polkit rule below rather than a bare signal send.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nginx-config;

  # Symlinked as `.main` inside each generation directory so its relative
  # includes resolve correctly with no per-invocation templating needed.
  nginxTestConfTemplate = pkgs.writeText "nginx-config-watch-test.conf" ''
    # nginx-config-watch's own test harness - not the real production config.
    events {}
    pid /tmp/nginx-config-watch-test.pid;
    error_log /dev/null;
    http {
      access_log off;
      include servers/*.conf;
      include upstreams/*.conf;
    }
  '';

  watchScript = pkgs.writeShellApplication {
    name = "nginx-config-watch";
    runtimeInputs = [ cfg.package config.services.nginx.package pkgs.coreutils pkgs.systemd ];
    text = ''
      # Consul only logs watch handler output at debug level, unreliably -
      # send our own stderr straight to the journal instead.
      exec 2> >(exec systemd-cat -t nginx-config-watch)

      # Consul pipes the keyprefix watch payload to stdin, passed straight through.
      if ! new_gen="$(nginx-configurator --conf-dir "${cfg.confDir}")"; then
        echo "nginx-config-watch: nginx-configurator failed (decode error or no servers) - not touching current" >&2
        exit 1
      fi

      # Test the new generation directly, before `current` is touched.
      ln -sf "${nginxTestConfTemplate}" "$new_gen/.main"
      if ! nginx -t -c "$new_gen/.main"; then
        echo "nginx-config-watch: nginx -t failed against new generation $new_gen - not swapping current" >&2
        exit 1
      fi

      ln -sfn "$new_gen" "${cfg.confDir}/current"
      systemctl reload nginx.service
    '';
  };

  watchSpecFile = (pkgs.formats.json { }).generate "nginx-config-watch.json" {
    log_level = "debug";
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
      description = "The nginx-configurator package.";
    };

    keyPrefix = lib.mkOption {
      type = lib.types.str;
      default = "nginx/conf/";
      description = "The Consul KV key prefix to watch.";
    };

    confDir = lib.mkOption {
      type = lib.types.str;
      description = "Path to the nginx conf directory and the `current` symlink.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Owned by "consul" (writes generations/current), readable by nginx's
    # own group (reads them) - setgid so nested content this creates
    # inherits the nginx group too, not consul's own primary group.
    systemd.tmpfiles.rules = [
      "d ${cfg.confDir} 02750 consul ${config.services.nginx.group} -"
    ];

    # Changing this file doesn't restart Consul on its own.
    services.consul.extraConfigFiles = [ (toString watchSpecFile) ];

    # Lets the "consul" agent user reload nginx.service, nothing broader.
    security.polkit.enable = lib.mkDefault true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "nginx.service" &&
            action.lookup("verb") == "reload" &&
            subject.user == "consul") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
