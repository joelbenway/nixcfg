# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{inputs, ...}: {
  imports = [inputs.nixos-hardware.nixosModules.common-cpu-intel];

  nix.settings.system-features = [
    "gccarch-ivybridge"
  ];
}
