{ lib, ... }:
with lib;
with types;
let
  helpers = import ./helpers.nix { inherit lib; };
in
# Not `oneOf [ returnDirective rewriteDirective breakDirective ]` (each a
# plain submodule) - submodule's own `check` is just `isAttrs x || ...`,
# blind to which fields are actually present, so `either`/`oneOf` always
# dispatches to the *first* alternative whose `check` doesn't reject the
# value outright (always true for every submodule alternative here),
# regardless of the value's own "type" tag. Confirmed by reading
# nixpkgs' lib/types.nix directly: `either`'s merge picks whichever side
# has `headError == null` from `checkDefsForError t.check`, and a
# submodule's `check` never produces an error - so `rewrite`/`break`
# values silently got merged as if they were `return`, only failing much
# later (lazily, when the wrongly-merged value is actually forced) with a
# confusing "option `code` has no value"/"option `flag` does not exist".
#
# `attrTag` is the type nixpkgs itself provides for exactly this shape -
# a genuine tagged union, discriminated by which single attribute name is
# present (`check` here actually inspects that), authored as
# `{ return = { code = 204; }; }` / `{ rewrite = { regex = ...; }; }` /
# `{ break = { }; }`. `toWireShape` (below, re-exporting `helpers.nix`'s
# `attrTagToWireShape` - general across any attrTag-based tagged union,
# nothing here is specific to this one) flattens that back into Types.hs's
# actual JSON shape (`{ type = "return"; code = 204; }`) via `apply` on
# each of this repo's three `rewrite_directives` options
# (servers.nix/location.nix/conditional_response.nix) - same "author an
# ergonomic shape, `apply` converts to the wire shape" pattern already
# used for `proxy_pass`/`extra_headers`.
#
# Tried baking the flattening into this file's own type instead (wrapping
# `merge` so every call site could go back to a bare `listOf
# rewriteModuleDirective`, no `apply` needed anywhere) - doesn't work.
# `evalModules` runs every option through `fixupOptionType`, which - since
# `attrTag`'s `getSubModules` is non-null here (return/rewrite carry real
# submodules) - replaces the type with `opt.type.substSubModules
# opt.options`, and `attrTag`'s own `substSubModules` rebuilds a brand new
# `attrTag {...}` from scratch, silently discarding any `merge` override
# before it's ever used. Confirmed directly: the option's `type.merge`
# still calls the wrapped function right after `mkOption`, but no longer
# does once the option has gone through `lib.evalModules`. `apply` (at
# the option level, per call site) is the mechanism that actually works.
{
  type = attrTag {
    return = mkOption {
      description = "nginx's own \"return\" directive.";
      type = submodule {
        options = {
          code = mkOption {
            type = int;
          };
          value = mkOption {
            type = nullOr str;
            default = null;
            description = ''
              The bare "return URL;" (implicit 302) shorthand isn't modeled,
              same as Types.hs - write it explicitly as code=302 instead.
            '';
          };
        };
      };
    };

    rewrite = mkOption {
      description = "nginx's own \"rewrite\" directive.";
      type = submodule {
        options = {
          regex = mkOption {
            type = str;
          };
          replacement = mkOption {
            type = str;
          };
          flag = mkOption {
            type = nullOr (enum [ "last" "break" "redirect" "permanent" ]);
            default = null;
          };
        };
      };
    };

    break = mkOption {
      description = "nginx's own bare \"break\" directive.";
      type = submodule { options = { }; };
    };
  };

  toWireShape = helpers.attrTagToWireShape;
}
