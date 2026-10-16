# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  nix.settings.system-features = [
    "gccarch-skylake"
  ];

  boot.kernelParams = [
    "i915.enable_guc=2"
    "i915.enable_fbc=0"
    "i915.enable_psr=0"
    "i915.enable_dc=0"
  ];

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "i965";
  };
}
