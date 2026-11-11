# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: {
  imports = [
    ../common/workstation.nix
    (lib.custom.relativeToRoot "hardware/coffeelake.nix")
  ];

  disko.devices = (import ./disks.nix {inherit lib;}).disko.devices;
}
