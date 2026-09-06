{ lib }:
{
  pairListToArray = list:
    map (e: let n = builtins.head (builtins.attrNames e); in [ n e.${n} ]) list;
}
