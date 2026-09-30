{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  nix.settings.system-features = [
    "gccarch-skylake"
  ];

  boot.kernelParams = [
    "i915.enable_guc=2"
    "i915.enable_fbc=1"
    "i915.enable_psr=0"
  ];
}
