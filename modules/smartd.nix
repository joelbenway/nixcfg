# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  pkgs,
  ...
}: let
  cfg = config.smartd;
  useFleetNotify = cfg.notifications.fleetNotify && (config.notify.client.enable or false);

  smartdNotifyScript = pkgs.writeShellApplication {
    name = "smartd-fleet-notify";
    runtimeInputs =
      [config.notify.client.package]
      ++ lib.optional cfg.notifications.wall pkgs.util-linux;
    text = ''
      set -euo pipefail
      FAILTYPE="''${SMARTD_FAILTYPE:-Alert}"
      DEVICE="''${SMARTD_DEVICE:-disk}"
      BODY="''${SMARTD_FULLMESSAGE:-''${SMARTD_MESSAGE:-SMART warning detected on ${hostname}}}"
      fleet-notify \
        --best-effort \
        --topic fleet-alerts \
        --priority high \
        --tags warning,cd \
        --title "[${hostname}] SMART: ''${FAILTYPE} (''${DEVICE})" \
        -- "''${BODY}"
      ${lib.optionalString cfg.notifications.wall ''
        printf 'Problem detected with disk: %s\n%s\n' "''${SMARTD_DEVICESTRING:-$DEVICE}" "$BODY" | wall 2>/dev/null || true
      ''}
    '';
  };

  fleetExecOpt = lib.optionalString useFleetNotify "-m <nomailer> -M exec ${smartdNotifyScript}/bin/smartd-fleet-notify";

  tempOpt = lib.optionalString (cfg.temperature.diff > 0 || cfg.temperature.info > 0 || cfg.temperature.crit > 0) "-W ${toString cfg.temperature.diff},${toString cfg.temperature.info},${toString cfg.temperature.crit}";

  standbyOpt = lib.optionalString (cfg.standbyMode != null && cfg.standbyMode != "") "-n ${cfg.standbyMode}";

  scheduleOpt = lib.optionalString (cfg.shortTestSchedule != "" || cfg.longTestSchedule != "") (let
    scheds = lib.concatStringsSep "|" (
      lib.optional (cfg.shortTestSchedule != "") cfg.shortTestSchedule
      ++ lib.optional (cfg.longTestSchedule != "") cfg.longTestSchedule
    );
  in "-s (${scheds})");

  defaultOpts = lib.concatStringsSep " " (lib.filter (s: s != "") [
      fleetExecOpt
      "-a"
      "-o on"
      "-S on"
      standbyOpt
      scheduleOpt
      tempOpt
    ]
    ++ cfg.extraDirectives);

  diskHealthPkg = pkgs.writeShellApplication {
    name = "disk-health";
    runtimeInputs = with pkgs; [
      smartmontools
      nvme-cli
      util-linux
      gawk
      gnugrep
    ];
    text = builtins.readFile ../pkgs/disk-health/disk-health.sh;
  };
in {
  options.smartd = {
    enable = lib.mkEnableOption "smartd disk health monitoring daemon and smartmontools";

    autodetect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically monitor all connected SATA and NVMe storage devices";
    };

    shortTestSchedule = lib.mkOption {
      type = lib.types.str;
      default = "S/../.././02";
      description = "smartd schedule expression for daily short self-tests (e.g. S/../.././02 for 02:00)";
    };

    longTestSchedule = lib.mkOption {
      type = lib.types.str;
      default = "L/../../7/04";
      description = "smartd schedule expression for weekly long self-tests (e.g. L/../../7/04 for Sundays at 04:00)";
    };

    standbyMode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "standby,q";
      description = "Skip routine polling when disk is in low-power standby mode (e.g. 'standby,q' or null to disable)";
    };

    temperature = {
      diff = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Log changes in temperature of this many degrees Celsius or more (0 to disable)";
      };
      info = lib.mkOption {
        type = lib.types.int;
        default = 55;
        description = "Informational temperature threshold in Celsius (0 to disable)";
      };
      crit = lib.mkOption {
        type = lib.types.int;
        default = 65;
        description = "Critical temperature threshold in Celsius that triggers an alert (0 to disable)";
      };
    };

    notifications = {
      fleetNotify = lib.mkOption {
        type = lib.types.bool;
        default = config.notify.client.enable or false;
        description = "Send SMART disk alerts to the fleet-notify bus (ntfy).";
      };
      wall = lib.mkOption {
        type = lib.types.bool;
        default = !(config.notify.client.enable or false);
        description = "Broadcast alert to all terminals via wall";
      };
      mail = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Send email alerts";
        };
        recipient = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "Email recipient for smartd alerts";
        };
      };
    };

    extraDirectives = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra smartd directives appended to each monitored device or DEVICESCAN";
    };

    devices = lib.mkOption {
      type = with lib.types;
        listOf (submodule {
          options = {
            device = lib.mkOption {
              type = str;
              description = "Device path, e.g. /dev/sda or /dev/disk/by-id/...";
            };
            options = lib.mkOption {
              type = separatedString " ";
              default = "";
              description = "Per-device smartd options";
            };
          };
        });
      default = [];
      description = "Explicit list of devices to monitor with custom options";
    };
  };

  config = lib.mkIf cfg.enable {
    services.smartd = {
      enable = true;
      autodetect = cfg.autodetect;
      defaults = {
        autodetected = defaultOpts;
        monitored = defaultOpts;
      };
      devices = cfg.devices;
      notifications = {
        wall.enable = !useFleetNotify && cfg.notifications.wall;
        x11.enable = false;
        systembus-notify.enable = false;
        mail = {
          enable = !useFleetNotify && cfg.notifications.mail.enable;
          recipient = cfg.notifications.mail.recipient;
        };
      };
    };

    systemd.services.smartd.serviceConfig = {
      Restart = "on-failure";
      RestartSec = "30s";
    };

    environment.systemPackages = with pkgs; [
      smartmontools
      nvme-cli
      diskHealthPkg
    ];

    # Persist smartd state across reboots on impermanence systems
    impermanence.directories = lib.mkIf (config.impermanence.enable or false) [
      "/var/lib/smartmontools"
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/smartmontools 0755 root root -"
    ];
  };
}
