# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
  cfgAgent = config.beszel.agent;
  cfgHub = config.beszel.hub;

  beszelQueryPkg = import (lib.custom.relativeToRoot "pkgs/beszel-query") {inherit pkgs;};
  yamlFormat = pkgs.formats.yaml {};

  hubConfigYaml = yamlFormat.generate "beszel-config.yml" {
    systems =
      map (sys: {
        inherit (sys) name host port;
      })
      cfgHub.systems;
  };

  dataDirMountUnit = "${lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" cfgHub.dataDir)}.mount";

  seedHubDataScript = pkgs.writeShellScript "beszel-hub-seed" ''
    set -euo pipefail
    DATA_DIR="${cfgHub.dataDir}/beszel_data"
    install -d -m 0700 -o beszel-hub -g beszel-hub "$DATA_DIR"
    ${lib.optionalString (cfgHub.keyFile != null) ''
      if [ -r "${toString cfgHub.keyFile}" ]; then
        install -m 0600 -o beszel-hub -g beszel-hub "${toString cfgHub.keyFile}" "$DATA_DIR/id_ed25519"
      fi
    ''}
    ${lib.optionalString (cfgHub.systems != []) ''
      install -m 0640 -o beszel-hub -g beszel-hub "${hubConfigYaml}" "$DATA_DIR/config.yml"
    ''}
  '';
in {
  options.beszel = {
    agent = {
      enable = lib.mkEnableOption "Beszel host monitoring agent";

      port = lib.mkOption {
        type = lib.types.port;
        default = ports.beszel.agent;
        description = "TCP port the Beszel agent listens on (firewalled to tailscale0 and Skylab LAN)";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        default = keys.beszelHub or "";
        description = "SSH ed25519 public key of the Beszel hub authorized to poll this agent";
      };

      smartmon = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable standby-aware S.M.A.R.T. disk monitoring via smartctl";
      };

      smartInterval = lib.mkOption {
        type = lib.types.str;
        default = "12h";
        description = "Polling interval for S.M.A.R.T. checks (respects -n standby)";
      };

      systemd = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable systemd unit monitoring and journal log inspection";
      };

      gpuCollectors = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Explicit GPU collectors to pass via GPU_COLLECTOR (empty keeps nixpkgs auto-detection)";
      };

      extraFilesystems = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional mount points or devices for EXTRA_FILESYSTEMS (supports __Label suffix)";
      };

      diskUsageCache = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional DISK_USAGE_CACHE duration (e.g. '1h') to prevent waking standby HDDs";
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Additional environment variables passed to beszel-agent";
      };
    };

    hub = {
      enable = lib.mkEnableOption "Beszel central monitoring hub";

      domain = lib.mkOption {
        type = lib.types.str;
        default = "metrics.benway.me";
        description = "Public/LAN domain name under which Beszel Hub is exposed via reverse proxy";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = ports.beszel.internal;
        description = "Internal loopback HTTP port for Beszel Hub";
      };

      tailscalePort = lib.mkOption {
        type = lib.types.port;
        default = ports.beszel.tailscale;
        description = "Tailscale HTTPS reverse-proxy port for Beszel Hub";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/beszel-hub";
        description = "Persistent data directory for Beszel Hub state (contains beszel_data/)";
      };

      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to the agenix-decrypted ed25519 private key seeded as beszel_data/id_ed25519";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to agenix env file with initial hub credentials (USER_EMAIL, USER_PASSWORD)";
      };

      hermesEnvFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to agenix env file with read-only Beszel API credentials for Hermes/beszel-query";
      };

      systems = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Display name of the monitored system";
            };
            host = lib.mkOption {
              type = lib.types.str;
              description = "Hostname, IP, or Tailscale FQDN reachable from the hub";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = ports.beszel.agent;
              description = "Beszel agent TCP port on the target host";
            };
          };
        });
        default = [];
        description = "Declarative list of systems seeded into beszel_data/config.yml";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfgAgent.enable {
      services.beszel.agent = {
        enable = true;
        openFirewall = false;
        smartmon.enable = cfgAgent.smartmon;
        environment =
          {
            PORT = toString cfgAgent.port;
            SKIP_SYSTEMD = !cfgAgent.systemd;
            SKIP_SYSTEMD_LOGS = !cfgAgent.systemd;
          }
          // lib.optionalAttrs (cfgAgent.publicKey != "") {
            KEY = cfgAgent.publicKey;
          }
          // lib.optionalAttrs cfgAgent.smartmon {
            SMART_INTERVAL = cfgAgent.smartInterval;
          }
          // lib.optionalAttrs (cfgAgent.gpuCollectors != []) {
            GPU_COLLECTOR = cfgAgent.gpuCollectors;
          }
          // lib.optionalAttrs (cfgAgent.extraFilesystems != []) {
            EXTRA_FILESYSTEMS = lib.concatStringsSep "," cfgAgent.extraFilesystems;
          }
          // lib.optionalAttrs (cfgAgent.diskUsageCache != null) {
            DISK_USAGE_CACHE = cfgAgent.diskUsageCache;
          }
          // cfgAgent.extraEnvironment;
      };

      networking.firewall = {
        interfaces."tailscale0".allowedTCPPorts = [cfgAgent.port];
        extraInputRules = lib.mkIf config.networking.nftables.enable ''
          iifname "tailscale0" tcp dport ${toString cfgAgent.port} accept
          ip saddr 192.168.77.0/24 tcp dport ${toString cfgAgent.port} accept
        '';
        extraCommands = lib.mkIf (!config.networking.nftables.enable) ''
          iptables -A nixos-fw -s 192.168.77.0/24 -p tcp --dport ${toString cfgAgent.port} -j nixos-fw-accept
        '';
        extraStopCommands = lib.mkIf (!config.networking.nftables.enable) ''
          iptables -D nixos-fw -s 192.168.77.0/24 -p tcp --dport ${toString cfgAgent.port} -j nixos-fw-accept 2>/dev/null || true
        '';
      };
    })

    (lib.mkIf cfgHub.enable {
      users.users.beszel-hub = {
        isSystemUser = true;
        group = "beszel-hub";
        home = cfgHub.dataDir;
        description = "Beszel monitoring hub service user";
      };

      users.groups.beszel-hub = {};

      services.beszel.hub = {
        enable = true;
        host = "127.0.0.1";
        port = cfgHub.port;
        dataDir = cfgHub.dataDir;
        environmentFile = cfgHub.environmentFile;
        environment = {
          APP_URL = "https://${cfgHub.domain}";
          SHARE_ALL_SYSTEMS = "true";
          CHECK_UPDATES = "false";
        };
      };

      systemd.services.beszel-hub = {
        after = lib.optionals (config.impermanence.enable or false) [dataDirMountUnit];
        wants = lib.optionals (config.impermanence.enable or false) [dataDirMountUnit];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          PrivateUsers = lib.mkForce false;
          User = "beszel-hub";
          Group = "beszel-hub";
          ExecStartPre = lib.mkBefore ["+${seedHubDataScript}"];
        };
      };

      systemd.tmpfiles.rules = [
        "d ${cfgHub.dataDir} 0750 beszel-hub beszel-hub -"
      ];

      impermanence.directories = lib.mkIf (config.impermanence.enable or false) [
        cfgHub.dataDir
      ];

      environment.systemPackages = [
        beszelQueryPkg
      ];

      systemd.services.hermes-agent = lib.mkIf ((config.hermes.enable or false) && cfgHub.hermesEnvFile != null) {
        environment.BESZEL_ENV_FILE = toString cfgHub.hermesEnvFile;
      };
    })
  ];
}
