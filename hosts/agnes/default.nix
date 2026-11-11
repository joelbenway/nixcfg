# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: {
  imports = [
    ../common/workstation.nix
    (lib.custom.relativeToRoot "hardware/laptop.nix")
    (lib.custom.relativeToRoot "hardware/skylake.nix")
  ];

  disko.devices = (import ./disks.nix {inherit lib;}).disko.devices;
}
