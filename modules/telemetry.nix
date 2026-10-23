# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.telemetry;
in {
  options.telemetry = {
    enable = lib.mkEnableOption "Network telemetry and flow monitoring via ntopng with zero SSD wear";

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["any"];
      description = "List of network interfaces to monitor (e.g. WAN and VLAN interfaces)";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Web UI HTTP port for ntopng";
    };

    localNetworks = lib.mkOption {
      type = lib.types.str;
      default = "192.168.77.0/24=skylab,192.168.62.0/24=skynet,192.168.69.0/24=iot,192.168.1.0/24=mgmt,100.64.0.0/10=tailscale";
      description = "Comma-separated list of local CIDR networks mapped to names for top-talker categorization";
    };

    ntopngRamSize = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "Size limit of the tmpfs RAM disk for ntopng timeseries and cache (/var/lib/ntopng)";
    };

    redisRamSize = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      description = "Size limit of the tmpfs RAM disk for redis (/var/lib/redis-ntopng)";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Zero SSD Wear: Mount RAM disks (tmpfs) for both ntopng and redis state directories
    fileSystems."/var/lib/redis-ntopng" = {
      fsType = "tmpfs";
      options = [
        "nosuid"
        "nodev"
        "noatime"
        "size=${cfg.redisRamSize}"
        "mode=0700"
      ];
    };

    fileSystems."/var/lib/ntopng" = {
      fsType = "tmpfs";
      options = [
        "nosuid"
        "nodev"
        "noatime"
        "size=${cfg.ntopngRamSize}"
        "mode=0700"
      ];
    };

    # 2. Configure Redis purely in-memory (no disk snapshots or append-only log writes)
    services.redis.servers.ntopng = {
      save = [];
      appendOnly = false;
    };

    # 3. Configure ntopng service
    services.ntopng = {
      enable = true;
      httpPort = cfg.port;
      interfaces = cfg.interfaces;
      extraConfig = ''
        --local-networks="${cfg.localNetworks}"
        --dns-mode=0
      '';
    };

    # Ensure systemd creates the state directory with correct permissions on the tmpfs
    systemd.services.ntopng.serviceConfig.StateDirectory = "ntopng";
    systemd.services.ntopng.serviceConfig.StateDirectoryMode = "0700";

    # 4. Restrict Web UI port access strictly to Tailscale interface
    networking.firewall.extraInputRules = ''
      # Allow ntopng Web UI strictly on Tailscale
      iifname "tailscale0" tcp dport ${toString cfg.port} accept
    '';

    # 5. CLI utility packages
    environment.systemPackages = [
      pkgs.ntopng
      pkgs.redis
    ];
  };
}
