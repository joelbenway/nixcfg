# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  lib,
  pkgs,
  ...
}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
in
  import (lib.custom.relativeToRoot "users/common") {
    inherit lib;
    username = "eliza";
    description = "Eliza Benway";
    isWheel = false;
    authorizedKeys = [keys.joel];
    packages = with pkgs; [
      gcompris
    ];
    extraConfig = {config, ...}: {
      plasma.users = lib.mkIf (config.eliza.desktop && config.plasma.enable) {
        eliza.discover = true;
      };
    }; # extraConfig
  }
