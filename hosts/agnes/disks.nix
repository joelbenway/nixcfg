# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  # ls -l /dev/disk/by-id/
  disks ? ["/dev/disk/by-id/nvme-eui.002538d61144b9a0"],
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
