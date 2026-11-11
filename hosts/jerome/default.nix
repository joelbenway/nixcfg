# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: {
  imports = [
    ../common/workstation.nix
    (lib.custom.relativeToRoot "hardware/laptop.nix")
    (lib.custom.relativeToRoot "hardware/skylake.nix")
  ];

  boot.kernelParams = [
    "intel_iommu=on,igfx_off"
    "mem_sleep_default=deep"
    "tpm_tis.interrupts=0"
  ];

  disko.devices = (import ./disks.nix {inherit lib;}).disko.devices;
}
