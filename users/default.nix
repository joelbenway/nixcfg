# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: {
  imports = lib.custom.scanFiles ./.;

  home-manager.backupFileExtension = "hmbak";
}
