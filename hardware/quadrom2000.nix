# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  inputs,
  ...
}: {
  imports = [inputs.nixos-hardware.nixosModules.common-gpu-nvidia-nonprime];

  hardware = {
    nvidia = {
      # The open source driver does not support Maxwell GPUs.
      open = false;
      package = config.boot.kernelPackages.nvidiaPackages.legacy_535;
    }; # nvidia
  }; # hardware
}
