{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  nix.settings.system-features = [
    "gccarch-ivybridge"
  ];
}
