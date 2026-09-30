{lib, ...}: {
  relativeToRoot = lib.path.append ../.;

  scanFiles = path:
    map (f: (path + "/${f}")) (
      builtins.attrNames (
        lib.attrsets.filterAttrs (
          name: type:
            (type == "regular")
            && (name != "default.nix")
            && (lib.strings.hasSuffix ".nix" name)
        ) (builtins.readDir path)
      )
    );
}
