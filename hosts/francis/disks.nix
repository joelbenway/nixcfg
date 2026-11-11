# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  # ls -l /dev/disk/by-id/
  disks ? ["/dev/disk/by-id/nvme-eui.0000000624041972caf25b04100013c6"],
  swapSize ? "33G",
  lib ? {},
  ...
}: let
  customLib =
    lib.custom
    or (import ../../lib {
      lib = (import <nixpkgs> {}).lib;
    });
in
  customLib.mkBtrfsLuksDisk {
    device = builtins.elemAt disks 0;
    inherit swapSize;
  }
