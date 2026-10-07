# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{pkgs, ...}: {
  services.fprintd = {
    enable = true;
    tod = {
      enable = true;
      driver = pkgs.libfprint-2-tod1-goodix;
    };
  };
}
