# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{...}: {
  imports = [./scanner.nix];
  hardware.sane.drivers.scanSnap.enable = true;
}
