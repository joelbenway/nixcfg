# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  nix.settings.system-features = [
    "gccarch-alderlake"
  ];

  boot.kernelParams = [
    "i915.enable_guc=2"
    "i915.enable_fbc=1"
    "i915.enable_psr=0"
  ];

  hardware.intelgpu.vaapiDriver = "intel-media-driver";
}
