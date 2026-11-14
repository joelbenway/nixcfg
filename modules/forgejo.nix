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

    pam = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Linux PAM host authentication for Forgejo";
      };

      emailDomain = lib.mkOption {
        type = lib.types.str;
        default = "benway.me";
        description = "Default email domain for PAM auto-registered users";
      };

      adminUser = lib.mkOption {
        type = lib.types.str;
        default = "joel";
        description = "Linux username to automatically grant site administrator privileges";
      };
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
          DISABLE_REGISTRATION = lib.mkDefault false;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          SHOW_REGISTRATION_BUTTON = false;
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

    # 2. Forgejo systemd service ordering and namespace hardening
    systemd.services.forgejo-secrets = {
      after = lib.optionals (config.impermanence.enable or false) ["var-lib-forgejo.mount"];
      wants = lib.optionals (config.impermanence.enable or false) ["var-lib-forgejo.mount"];
      serviceConfig = {
        StateDirectory = "forgejo forgejo/custom forgejo/custom/conf forgejo/data";
        StateDirectoryMode = "0750";
        ReadWritePaths = lib.mkForce [cfg.dataDir];
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}/custom/conf ${cfg.dataDir}/data"
          "+${pkgs.coreutils}/bin/chown -R forgejo:forgejo ${cfg.dataDir}"
          "+${pkgs.coreutils}/bin/chmod -R 0750 ${cfg.dataDir}"
        ];
      };
    };

    systemd.services.forgejo = {
      after = lib.optionals (config.impermanence.enable or false) ["var-lib-forgejo.mount"];
      wants = lib.optionals (config.impermanence.enable or false) ["var-lib-forgejo.mount"];
      preStart = lib.mkIf cfg.pam.enable (let
        exe = "${cfg.package}/bin/forgejo";
      in
        lib.mkAfter ''
          config='${cfg.dataDir}/custom/conf/app.ini'

          # Ensure Linux PAM authentication source exists
          if ! ${exe} admin auth list --config "$config" --work-path '${cfg.dataDir}' 2>/dev/null | grep -q "Linux PAM"; then
            ${exe} admin auth add-pam \
              --config "$config" \
              --work-path '${cfg.dataDir}' \
              --name "Linux PAM" \
              --service-name "forgejo" \
              --email-domain "${cfg.pam.emailDomain}" \
              --active
          fi

          # Ensure admin user exists and is linked to PAM
          if ! ${exe} admin user list --config "$config" --work-path '${cfg.dataDir}' 2>/dev/null | grep -q "${cfg.pam.adminUser}"; then
            ${exe} admin user create \
              --config "$config" \
              --work-path '${cfg.dataDir}' \
              --username "${cfg.pam.adminUser}" \
              --email "${cfg.pam.adminUser}@${cfg.pam.emailDomain}" \
              --admin \
              --random-password
          fi

          PAM_ID=$(${pkgs.sqlite}/bin/sqlite3 '${cfg.dataDir}/data/forgejo.db' "SELECT id FROM login_source WHERE type = 4 LIMIT 1;" 2>/dev/null || true)
          if [ -n "$PAM_ID" ]; then
            ${pkgs.sqlite}/bin/sqlite3 '${cfg.dataDir}/data/forgejo.db' \
              "UPDATE user SET login_type = 4, login_source = $PAM_ID, login_name = '${cfg.pam.adminUser}', is_admin = 1 WHERE name = '${cfg.pam.adminUser}';" 2>/dev/null || true
          fi
        '');
    };

    # Enable Linux PAM service for Forgejo
    security.pam.services.forgejo = lib.mkIf cfg.pam.enable {};

    # Grant forgejo user membership in shadow group so PAM can verify /etc/shadow
    users.users.forgejo.extraGroups = lib.mkIf cfg.pam.enable ["shadow"];

    # 3. Forgejo Actions Runner Daemon
    systemd.services.forgejo-runner = lib.mkIf cfg.runner.enable {
      description = "Forgejo Actions Runner";
      wantedBy = ["multi-user.target"];
      after =
        ["network.target" "forgejo.service" "podman.socket"]
        ++ lib.optionals (config.impermanence.enable or false) [
          "var-lib-forgejo-runner.mount"
          "var-lib-forgejo.mount"
        ];
      wants =
        ["forgejo.service"]
        ++ lib.optionals (config.impermanence.enable or false) ["var-lib-forgejo-runner.mount"];
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
      "d ${cfg.dataDir} 0750 forgejo forgejo -"
      "d ${cfg.dataDir}/custom 0750 forgejo forgejo -"
      "d ${cfg.dataDir}/custom/conf 0750 forgejo forgejo -"
      "d ${cfg.dataDir}/data 0750 forgejo forgejo -"
      "z ${cfg.dataDir} 0750 forgejo forgejo -"
      "d ${cfg.backupDir} 0750 forgejo forgejo -"
      "d /var/lib/forgejo-runner 0750 root root -"
    ];
  };
}
