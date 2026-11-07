# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  cfg = config.jellyfin;
in {
  options.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin media server";

    port = lib.mkOption {
      type = lib.types.port;
      default = ports.jellyfin.internal;
      description = "Port for the Jellyfin web interface";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the Jellyfin HTTP/HTTPS and discovery ports in the firewall";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      description = "User account under which Jellyfin runs";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      description = "Group under which Jellyfin runs";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "users"
        "video"
        "render"
      ];
      description = "Additional groups for the Jellyfin service user (e.g. users for shared storage, video/render for GPU)";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jellyfin";
      description = "Base data directory for Jellyfin databases, metadata, and configuration";
    };

    configDir = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.dataDir}/config";
      defaultText = lib.literalExpression ''"''${config.jellyfin.dataDir}/config"'';
      description = "Directory containing Jellyfin server configuration files";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/jellyfin";
      description = "Directory for Jellyfin transcodes and cache";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.dataDir}/log";
      defaultText = lib.literalExpression ''"''${config.jellyfin.dataDir}/log"'';
      description = "Directory where Jellyfin logs are stored";
    };

    mediaDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional path to media library directory to ensure mounts are active before service starts";
    };

    hardwareAcceleration = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable hardware acceleration for video transcoding";
      };

      type = lib.mkOption {
        type = lib.types.enum [
          "none"
          "nvenc"
          "vaapi"
          "qsv"
          "amf"
          "v4l2m2m"
          "rkmpp"
        ];
        default = "nvenc";
        description = "Hardware acceleration backend to use";
      };

      device = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Hardware acceleration device path (e.g. /dev/dri/renderD128)";
      };
    };

    package = lib.mkPackageOption pkgs "jellyfin" {};
  };

  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      inherit
        (cfg)
        package
        user
        group
        dataDir
        configDir
        cacheDir
        logDir
        openFirewall
        ;
      hardwareAcceleration = lib.mkIf cfg.hardwareAcceleration.enable {
        enable = true;
        inherit (cfg.hardwareAcceleration) type;
        device =
          if cfg.hardwareAcceleration.device != null
          then cfg.hardwareAcceleration.device
          else if cfg.hardwareAcceleration.type == "nvenc"
          then "/dev/dri/renderD128"
          else null;
      };
    };

    # Enable graphics drivers when hardware acceleration is enabled
    hardware.graphics.enable = lib.mkIf cfg.hardwareAcceleration.enable (lib.mkDefault true);

    # Allow access to Nvidia device nodes in systemd sandbox when using nvenc
    systemd.services.jellyfin = {
      preStart = lib.mkBefore ''
        mkdir -p "${cfg.configDir}" "${cfg.logDir}" "${cfg.cacheDir}"
      '';
      serviceConfig = lib.mkIf (cfg.hardwareAcceleration.enable && cfg.hardwareAcceleration.type == "nvenc") {
        DeviceAllow = [
          "/dev/nvidiactl rw"
          "/dev/nvidia-modeset rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "char-nvidia-frontend rw"
          "char-nvidia-uvm rw"
          "/dev/nvidia0 rw"
        ];
      };
      unitConfig = lib.mkIf (cfg.mediaDir != null) {
        RequiresMountsFor = [cfg.mediaDir];
      };
    };

    # Add extra groups to jellyfin user
    users.users = lib.mkIf (cfg.user == "jellyfin") {
      jellyfin = {
        inherit (cfg) extraGroups;
      };
    };

    # Persist dataDir across reboots when impermanence is enabled
    impermanence.directories = lib.mkIf config.impermanence.enable [
      {
        directory = cfg.dataDir;
        user = cfg.user;
        group = cfg.group;
        mode = "0700";
      }
    ];

    systemd.tmpfiles.rules =
      [
        "d ${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} -"
        "d ${cfg.configDir} 0700 ${cfg.user} ${cfg.group} -"
        "d ${cfg.cacheDir} 0700 ${cfg.user} ${cfg.group} -"
        "d ${cfg.logDir} 0700 ${cfg.user} ${cfg.group} -"
      ]
      ++ lib.optionals config.impermanence.enable [
        "d /persist${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} -"
        "d /persist${cfg.configDir} 0700 ${cfg.user} ${cfg.group} -"
        "Z /persist${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} -"
      ];
  };
}
