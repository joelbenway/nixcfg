# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs, ...}: {
  hardware = {
    sane = {
      enable = true;
      extraBackends = [pkgs.sane-airscan];
    }; # sane
  }; # hardware
}
