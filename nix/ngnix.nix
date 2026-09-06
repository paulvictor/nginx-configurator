let
  kvBatchJq = ''
    [
      .servers
      | to_entries[]
      | {
          Key: ("nginx/conf/servers/" + .key),
          Value: (.value | tojson | @base64)
        }
    ]
    +
    [
      .upstreams
      | to_entries[]
      | {
          Key: ("nginx/conf/upstreams/" + .key),
          Value: (.value | tojson | @base64)
        }
    ]
  '';

  ast = { pkgs, lib ? pkgs.lib, modules ? [ ], specialArgs ? { } }:
    (lib.evalModules {
      modules =
        modules ++
        [
          ./modules/mixin.nix
          { _module.args = { inherit pkgs; }; }
        ];
      inherit specialArgs;
    }).config.ngnix.settings;

  configFile = args@{ pkgs, ... }:
    (pkgs.formats.json { }).generate "config.json" (ast args);

  generated = args@{ pkgs, ... }:
    pkgs.runCommand "ngnix-generated"
      {
        nativeBuildInputs = [ pkgs.jq pkgs.nginx-configurator ];
      } ''
      mkdir -p "$out"
      jq '${kvBatchJq}' ${configFile args} | nginx-configurator --conf-dir "$out"
    '';
in
{
  inherit ast configFile generated;
}
