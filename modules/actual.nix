# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  cfg = config.actual;
in {
  options.actual = {
    enable = lib.mkEnableOption "Actual Budget";

    port = lib.mkOption {
      type = lib.types.port;
      default = ports.actual.internal;
      description = "Port for Actual Budget web interface";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for Actual Budget to listen on";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/actual";
      description = "Directory for Actual Budget data";
    };
  };

  config = lib.mkIf cfg.enable {
    services.actual = {
      enable = true;
      openFirewall = false;
      settings = {
        port = cfg.port;
        hostname = cfg.hostname;
        dataDir = cfg.dataDir;
        loginMethod = "password";
        allowedLoginMethods = ["password"];
        trustedProxies = ["127.0.0.1" "::1"];
      };
    };

    systemd.services.actual = {
      preStart = lib.mkAfter ''
                  DB_FILE="${cfg.dataDir}/server-files/account.sqlite"
                  if [[ -f "$DB_FILE" ]]; then
                    HAS_AUTH=$(${pkgs.sqlite}/bin/sqlite3 "$DB_FILE" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='auth';" 2>/dev/null || echo 0)
                    if [[ "$HAS_AUTH" -eq 1 ]]; then
                      ${pkgs.sqlite}/bin/sqlite3 "$DB_FILE" <<'EOF'
        INSERT INTO auth (method, display_name, active)
        VALUES ('password', 'Password', 1)
        ON CONFLICT (method) DO UPDATE SET active = 1;

        UPDATE auth SET active = 0
        WHERE method = 'header';
        EOF
                    fi
                  fi
      '';
    };
  };
}
