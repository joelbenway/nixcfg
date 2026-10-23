# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel-cpu-only];

  nix.settings.system-features = [
    "gccarch-ivybridge"
  ];
}
