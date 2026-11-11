# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  # ls -l /dev/disk/by-id/
  disks ? ["/dev/disk/by-id/ata-MTFDDAK256MAM-1K1_1350095E2305"],
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
    swapSize = null;
  }
