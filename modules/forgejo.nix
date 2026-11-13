# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  cfg = config.forgejo;
in {
  options.forgejo = {
    enable = lib.mkEnableOption "Forgejo self-hosted software forge and Actions runner";

    package = lib.mkPackageOption pkgs "forgejo" {};

    domain = lib.mkOption {
      type = lib.types.str;
      default = "git.benway.me";
      description = "Domain name for Forgejo web interface";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = ports.forgejo.internal;
      description = "Internal HTTP port for Forgejo";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = ports.forgejo.ssh;
      description = "SSH port for Git operations";
    };

    tailscalePort = lib.mkOption {
      type = lib.types.port;
      default = ports.forgejo.tailscale;
      description = "Tailscale port for Forgejo reverse proxy";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/forgejo";
      description = "State directory for Forgejo data, repositories, and SQLite database";
    };

    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/storage/backups/forgejo";
      description = "Directory for automated daily compressed dumps";
    };

    runner = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Forgejo Actions runner daemon";
      };

      labels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "native:host"
          "docker:docker://docker.io/node:20-bookworm"
        ];
        description = "Runner labels for Forgejo Actions";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Forgejo Web & Git Service
    services.forgejo = {
      enable = true;
      inherit (cfg) package;
      stateDir = cfg.dataDir;

      database = {
        type = "sqlite3";
        createDatabase = true;
        path = "${cfg.dataDir}/data/forgejo.db";
      };

      dump = {
        enable = true;
        interval = "04:30";
        type = "tar.zst";
        backupDir = cfg.backupDir;
      };

      settings = {
        DEFAULT = {
          APP_NAME = "Joel's Forge";
        };

        server = {
          DOMAIN = cfg.domain;
          ROOT_URL = "https://${cfg.domain}/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = cfg.port;

          # Built-in SSH daemon on dedicated port
          START_SSH_SERVER = true;
          SSH_PORT = cfg.sshPort;
          SSH_LISTEN_PORT = cfg.sshPort;
          SSH_DOMAIN = cfg.domain;
        };

        service = {
          DISABLE_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = false;
        };

        actions = {
          ENABLED = true;
        };

        session = {
          COOKIE_SECURE = true;
        };
      };
    };

    # 2. Forgejo Actions Runner Daemon
    systemd.services.forgejo-runner = lib.mkIf cfg.runner.enable {
      description = "Forgejo Actions Runner";
      wantedBy = ["multi-user.target"];
      after = ["network.target" "forgejo.service" "podman.socket"];
      wants = ["forgejo.service"];
      path = with pkgs; [
        bash
        coreutils
        curl
        gawk
        git
        gnugrep
        gnused
        jq
        nix
        podman
        util-linux
        cfg.package
        pkgs.forgejo-runner
      ];
      environment = {
        HOME = "/var/lib/forgejo-runner";
        DOCKER_HOST = "unix:///run/podman/podman.sock";
      };
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/var/lib/forgejo-runner";
        StateDirectory = "forgejo-runner";
        Restart = "always";
        RestartSec = "10s";
        ExecStartPre = pkgs.writeShellScript "forgejo-runner-setup" ''
          set -euo pipefail
          STATE_DIR="/var/lib/forgejo-runner"
          CONFIG_FILE="$STATE_DIR/config.yaml"

          if [ ! -f "$CONFIG_FILE" ]; then
            echo "Generating default runner configuration..."
            ${pkgs.forgejo-runner}/bin/forgejo-runner generate-config > "$CONFIG_FILE"
          fi

          if [ ! -f "$STATE_DIR/.runner" ]; then
            echo "Registering Forgejo runner with instance..."
            TOKEN=""
            for i in $(seq 1 30); do
              if TOKEN=$(${pkgs.util-linux}/bin/runuser -u forgejo -- ${cfg.package}/bin/forgejo actions generate-runner-token \
                --config ${cfg.dataDir}/custom/conf/app.ini \
                --work-path ${cfg.dataDir} 2>/dev/null | tail -1 | tr -d '\r\n '); then
                if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
                  break
                fi
              fi
              echo "Waiting for Forgejo database to be ready (attempt $i/30)..."
              sleep 2
            done

            if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
              ${pkgs.forgejo-runner}/bin/forgejo-runner register \
                --no-interactive \
                --instance "http://127.0.0.1:${toString cfg.port}" \
                --token "$TOKEN" \
                --name "${config.networking.hostName}-runner" \
                --labels "${lib.concatStringsSep "," cfg.runner.labels}" \
                --config "$CONFIG_FILE"
              echo "Runner registered successfully."
            else
              echo "WARNING: Could not obtain runner registration token."
            fi
          fi
        '';
        ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /var/lib/forgejo-runner/config.yaml";
      };
    };

    # Enable Podman with Docker socket compatibility when container labels are declared
    virtualisation.podman = lib.mkIf (cfg.runner.enable && lib.any (l: lib.hasInfix ":docker" l) cfg.runner.labels) {
      enable = true;
      dockerSocket.enable = true;
      dockerCompat = true;
    };

    # Open firewall for Git SSH port
    networking.firewall.allowedTCPPorts = [
      cfg.sshPort
    ];

    # Impermanence: persist Forgejo data and runner state across reboots
    impermanence.directories = lib.mkIf (config.impermanence.enable or false) [
      cfg.dataDir
      "/var/lib/forgejo-runner"
    ];

    # Ensure backup directory and state directory permissions exist
    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0750 forgejo forgejo -"
      "d /var/lib/forgejo-runner 0750 root root -"
    ];
  };
}
