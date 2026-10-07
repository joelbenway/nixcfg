# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable syncthing for user";
      guiAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0:8384";
        example = "0.0.0.0:8384";
        description = "Address of web GUI";
      }; # guiAddress
    }; # options
  }; # userConfigType
in {
  options.syncthing = {
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Per user configuration";
    }; # users
  }; # options.syncthing

  config = {
    home-manager.users =
      lib.mapAttrs (_: userConfig: {
        services.syncthing = {
          inherit (userConfig) enable;
          extraOptions = [
            "--gui-address=${userConfig.guiAddress}"
          ];
        }; # services.syncthing
      }) # home-manager.users
      
      config.syncthing.users;
  };
}
