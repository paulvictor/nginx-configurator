{ lib, ... }:
with lib;
with types;
{
  options = {
    address = mkOption {
      type = str;
      description = ''
        e.g. "log-processor-backend.service.consul:8080".
      '';
    };

    parameters = mkOption {
      type = attrsOf (oneOf [
        bool
        int
        str
      ]);
      default = {
        weight = 1;
        resolve = false;
        max_fails = 3;
        fail_timeout = "10s";
        backup = false;
      };
      description = ''
        nginx's own "server" directive parameters, keyed by nginx's own
        parameter names (e.g. "max_fails", "fail_timeout") - no
        camelCase<->snake_case translation to get wrong, and a parameter
        nginx supports that isn't explicitly modeled elsewhere doesn't
        need any code change here.
      '';
    };
  };
}
