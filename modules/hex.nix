# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable Hex voice dictation for this user";
      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Autostart Hex with the graphical desktop session";
      };
      installModel = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically download transcription model when online";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "parakeet_v3";
        description = "Transcription model id from `hex model list`";
      };
      shortcut = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "control+option+space";
        description = "Dictation shortcut hotkey";
      };
      language = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "en";
        description = "Dictation language code";
      };
      settings = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Extra settings for Hex";
      };
    };
  };
in {
  options.hex = {
    enable = lib.mkEnableOption "Enable Hex local voice dictation";
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Per-user configuration for Hex voice dictation";
    };
  };

  config = lib.mkIf config.hex.enable {
    home-manager.users =
      lib.mapAttrs (
        _: cfg:
          lib.mkIf cfg.enable {
            programs.hex = {
              inherit (cfg) enable autostart installModel model shortcut language settings;
            };
          }
      )
      config.hex.users;
  };
}
