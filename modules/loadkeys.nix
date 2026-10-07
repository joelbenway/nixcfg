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
    systemd.user.services =
      lib.concatMapAttrs (
        user: cfg:
          lib.optionalAttrs cfg.enable {
            "loadkeys-import-${user}" = lib.mkIf (cfg.envFile != null) {
              description = "Service to load session keys for ${user}";
              wantedBy = ["default.target"];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                EnvironmentFile = cfg.envFile;
                ExecStart = pkgs.writeShellScript "loadkeys-import" ''
                  retries=30
                  while [ ! -f "${cfg.envFile}" ] && [ $retries -gt 0 ]; do
                    retries=$((retries - 1))
                    sleep 1
                  done
                  if [ ! -f "${cfg.envFile}" ]; then
                    echo "ERROR: ${cfg.envFile} not found after 30s" >&2
                    exit 1
                  fi
                  vars=()
                  while IFS='=' read -r key _; do
                    key="''${key%%#*}"
                    key="''${key// /}"
                    [ -n "$key" ] && vars+=("$key")
                  done < "${cfg.envFile}"
                  exec ${pkgs.systemd}/bin/systemctl --user import-environment "''${vars[@]}"
                '';
              }; # serviceConfig
            };
          }
      )
      config.loadkeys.users;
  }; # config
}
