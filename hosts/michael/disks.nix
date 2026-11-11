# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  # ls -l /dev/disk/by-id/
  disks ? ["/dev/disk/by-id/nvme-eui.ace42e001a341a4d2ee4ac0000000001"],
  swapSize ? "16G",
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
