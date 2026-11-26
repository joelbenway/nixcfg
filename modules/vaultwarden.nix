# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  servicesCatalog = import (lib.custom.relativeToRoot "data/services.nix");
  cfg = config.vaultwarden;
in {
  options.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden password manager";

    domain = lib.mkOption {
      type = lib.types.str;
      default = servicesCatalog.vaultwarden.domain;
      description = "Domain name under which Vaultwarden is reachable";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = ports.vaultwarden.internal;
      description = "Internal HTTP port for Vaultwarden Rocket web server";
    };

    tailscalePort = lib.mkOption {
      type = lib.types.port;
      default = ports.vaultwarden.tailscale;
      description = "Tailscale port for Vaultwarden reverse proxy";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to environment file containing secrets like ADMIN_TOKEN";
    };

    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/storage/backups/vaultwarden";
      description = "Directory for automated persistent SQLite database backups";
    };
  };

  config = lib.mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;
      dbBackend = "sqlite";
      backupDir = cfg.backupDir;
      environmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
      config = {
        DOMAIN = "https://${cfg.domain}";
        SIGNUPS_ALLOWED = false;
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = cfg.port;
        ROCKET_LOG = "critical";
        WEBSOCKET_ENABLED = true;
      };
    };

    # Impermanence: persist Vaultwarden data and order service after bind mount
    impermanence.persistentServices.vaultwarden = {
      directory = "/var/lib/vaultwarden";
    };

    # Ensure backup directory permissions exist
    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0750 vaultwarden vaultwarden -"
    ];
  };
}
