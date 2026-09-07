{ lib }:
{
  pairListToArray = list:
    map (e: let n = builtins.head (builtins.attrNames e); in [ n e.${n} ]) list;

  # Flattens a `lib.types.attrTag`-authored value (a single-key attrset,
  # e.g. `{ return = { code = 204; }; }`) into the flat, "type"-tagged
  # object aeson's `TaggedObject` sum encoding expects on the Haskell side
  # (`{ type = "return"; code = 204; }`). General across any attrTag-based
  # tagged union in this schema, not specific to any one type - apply it
  # via `apply` on whichever option uses that union as its (listOf'd or
  # bare) type, same as rewrite_module_directive.nix's own
  # `rewrite_directives` options do.
  attrTagToWireShape = tagged:
    let tag = builtins.head (builtins.attrNames tagged);
    in { type = tag; } // tagged.${tag};
}
