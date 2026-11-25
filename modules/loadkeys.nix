# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable session key loading for this user";

      envFile = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = ''
          Path to an EnvironmentFile containing API keys and other variables.
          The file must be in systemd EnvironmentFile format.
        '';
      }; # envFile
    }; # options
  }; # userConfigType
in {
  options.loadkeys = {
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Per user session key loading configuration";
    }; # users
  }; # options.loadkeys

  config = {
    home-manager.users =
      lib.mapAttrs (
        user: cfg: {
          systemd.user.services.loadkeys-import = lib.mkIf (cfg.enable && cfg.envFile != null) {
            Unit = {
              Description = "Service to load session keys for ${user}";
              ConditionPathExists = toString cfg.envFile;
            };
            Service = {
              Type = "oneshot";
              RemainAfterExit = true;
              EnvironmentFile = toString cfg.envFile;
              ExecStart = toString (pkgs.writeShellScript "loadkeys-import-${user}" ''
                vars=()
                while IFS='=' read -r key _ || [ -n "$key" ]; do
                  key="''${key%%#*}"
                  key="''${key// /}"
                  [ -n "$key" ] && vars+=("$key")
                done < "${toString cfg.envFile}"
                if [ "''${#vars[@]}" -gt 0 ]; then
                  exec ${pkgs.systemd}/bin/systemctl --user import-environment "''${vars[@]}"
                fi
              '');
            };
            Install.WantedBy = ["default.target"];
          };
        }
      )
      config.loadkeys.users;
  }; # config
}
