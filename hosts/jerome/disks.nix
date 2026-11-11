# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  # ls -l /dev/disk/by-id/
  disks ? ["/dev/disk/by-id/nvme-nvme.1c5c-4b4a43424e343030373131363042363056-5348475033312d31303030474d-00000001"],
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
