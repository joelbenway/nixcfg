# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  pkgs,
  ...
}: let
  cfg = config.auto-update;
  tailnet = config.tailscale.tailnet or "gentoo-humboldt.ts.net";
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  deployKeySecretFile = lib.custom.relativeToRoot "secrets/github-secrets-deploy-key.age";
  hasDeployKeySecret = builtins.pathExists deployKeySecretFile;

  # Write status.json helper script
  writeStatusScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-write-status";
    runtimeInputs = with pkgs; [coreutils jq];
    text = ''
      export AUTO_UPDATE_STATE_DIR="${cfg.stateDir}"
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      exec ${../pkgs/auto-update/write-status.sh} "$@"
    '';
  };

  # Host-specific canary check script
  canaryScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-canary";
    runtimeInputs = with pkgs; [
      bind.dnsutils
      coreutils
      glibc.bin
      systemd
    ];
    text = ''
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      export CANARY_SERVICES="${lib.concatStringsSep " " cfg.canary.services}"
      export CANARY_CHECK_DNS="${lib.boolToString cfg.canary.checkDns}"
      exec ${../pkgs/auto-update/canary.sh} "$@"
    '';
  };

  # Post-boot verification & bootctl default promotion script
  bootVerifyScript = pkgs.writeShellApplication {
    name = "nixos-boot-verify";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      systemd
      canaryScript
      writeStatusScript
    ];
    text = ''
      export AUTO_UPDATE_STATE_DIR="${cfg.stateDir}"
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      exec ${../pkgs/auto-update/boot-verify.sh} "$@"
    '';
  };

  # Main auto-update execution script
  updateScript = pkgs.writeShellApplication {
    name = "nixos-auto-update";
    runtimeInputs =
      (with pkgs; [
        coreutils
        findutils
        git
        gnugrep
        gnused
        jq
        nix
        nixos-rebuild
        openssh
        systemd
        util-linux
        canaryScript
        writeStatusScript
      ])
      ++ lib.optional (config.tpm.enable or false) pkgs.cryptsetup;
    text = ''
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      export AUTO_UPDATE_STATE_DIR="${cfg.stateDir}"
      export AUTO_UPDATE_ZITA_HOST="${cfg.zitaHost}"
      export AUTO_UPDATE_REPO_URL="${cfg.repoUrl}"
      export AUTO_UPDATE_SECRETS_REPO_URL="${cfg.secretsRepoUrl}"
      export AUTO_UPDATE_DEPLOY_KEY_PATH="${
        if cfg.secretsDeployKeyPath != null
        then toString cfg.secretsDeployKeyPath
        else ""
      }"
      export AUTO_UPDATE_GIT_MIRROR="${lib.boolToString cfg.gitMirror.enable}"
      export AUTO_UPDATE_HERMES_ENABLE="${lib.boolToString (config.hermes.enable or false)}"
      export AUTO_UPDATE_HERMES_LEAF="${config.hermes.runtimeLeafPath or "/var/lib/hermes/agent-env.nix"}"
      export AUTO_UPDATE_CACHE_WARMER="${lib.boolToString cfg.cacheWarmer.enable}"
      export AUTO_UPDATE_CACHE_WARMER_HOSTS="${lib.concatStringsSep " " cfg.cacheWarmer.hosts}"
      export AUTO_UPDATE_TPM_ENABLE="${lib.boolToString (config.tpm.enable or false)}"
      export AUTO_UPDATE_REBOOT_ENABLE="${lib.boolToString cfg.reboot.enable}"
      export AUTO_UPDATE_REBOOT_WINDOW="${cfg.reboot.window}"
      exec ${../pkgs/auto-update/auto-update.sh} "$@"
    '';
  };

  # Tiny HTTP status server script (serves status.json on tailscale0:9105)
  statusServerScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-status-server";
    runtimeInputs = with pkgs; [python3];
    text = ''
      exec python3 ${../pkgs/auto-update/status-server.py} "${cfg.stateDir}/status.json" "${toString cfg.statusServer.port}"
    '';
  };

  # KDE Plasma desktop notification poller script for workstations
  desktopNotifyScript = pkgs.writeShellApplication {
    name = "fleet-health-notify";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      libnotify
    ];
    text = ''
      export FLEET_NOTIFY_TAILNET="${tailnet}"
      export FLEET_NOTIFY_PORT="${toString cfg.statusServer.port}"
      export FLEET_NOTIFY_HOSTS="${lib.concatStringsSep " " cfg.desktopNotifications.monitoredHosts}"
      exec ${../pkgs/auto-update/desktop-notify.sh} "$@"
    '';
  };
in {
  options.auto-update = {
    enable = lib.mkEnableOption "Declarative NixOS fleet auto-update with canary rollback and TPM reboot guard";

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/joelbenway/nixcfg.git";
      description = "Upstream Git repository URL for nixcfg.";
    };

    secretsRepoUrl = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:joelbenway/nixos-secrets.git";
      description = "Upstream Git repository URL for the private nixos-secrets submodule.";
    };

    zitaHost = lib.mkOption {
      type = lib.types.str;
      default = "zita.skylab.home";
      description = "Hostname of Zita for secondary Git remote and binary cache.";
    };

    secretsDeployKeyPath = lib.mkOption {
      type = with lib.types; nullOr (either path str);
      default =
        if hasDeployKeySecret
        then config.age.secrets.github-secrets-deploy-key.path
        else null;
      description = "Path to the read-only SSH deploy key for fetching nixos-secrets.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixos-auto-update";
      description = "Persistent directory storing the local nixcfg checkout and status.json.";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:00:00";
      description = "Systemd OnCalendar schedule for running nixos-auto-update.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Randomized delay before starting nixos-auto-update.";
    };

    gitMirror = {
      enable = lib.mkEnableOption "Serve nixcfg and nixos-secrets read-only over git:// on tailscale0:9418";
    };

    cacheWarmer = {
      enable = lib.mkEnableOption "Pre-build fleet host closures into local Nix store for Harmonia";
      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["michael" "francis" "agnes" "jerome"];
        description = "Hostnames whose system closures should be pre-built after updating this host.";
      };
    };

    reboot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically schedule a reboot during the maintenance window when kernel/initrd changes and TPM safety passes.";
      };
      window = lib.mkOption {
        type = lib.types.str;
        default = "03:30";
        description = "Time of day (HH:MM) to schedule unattended kernel reboots.";
      };
      hardwareWatchdog = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Configure systemd runtime and reboot hardware watchdog timers for automatic reset on kernel hang.";
      };
    };

    canary = {
      services = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Critical systemd services that must be active for canary verification to pass.";
      };
      checkDns = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Verify local DNS resolution (@127.0.0.1) during canary checks.";
      };
    };

    statusServer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose /var/lib/nixos-auto-update/status.json on tailscale0 for desktop notifications.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = ports.autoUpdate.internal;
        description = "TCP port on tailscale0 for status.json HTTP server.";
      };
    };

    desktopNotifications = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.plasma.enable or false;
        description = "Poll fleet status.json endpoints and show native KDE Plasma notifications when human attention is needed.";
      };
      monitoredHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["michael" "zita" "francis" "agnes" "jerome"];
        description = "Fleet hosts to poll for attended reboot or rollback alerts.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        updateScript
        canaryScript
        bootVerifyScript
      ];

      impermanence.directories = lib.optionals (config.impermanence.enable or false) [
        cfg.stateDir
      ];

      age.secrets = lib.mkIf hasDeployKeySecret {
        github-secrets-deploy-key = {
          file = deployKeySecretFile;
          mode = "0400";
          owner = "root";
          group = "root";
        };
      };

      systemd.services.nixos-auto-update = {
        description = "Declarative NixOS Auto-Update with Canary Rollback and TPM Guard";
        after = ["network-online.target" "tailscaled.service"];
        wants = ["network-online.target"];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updateScript}/bin/nixos-auto-update";
        };
      };

      systemd.timers.nixos-auto-update = {
        description = "Timer for Declarative NixOS Auto-Update";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.dates;
          RandomizedDelaySec = cfg.randomizedDelaySec;
          Persistent = true;
        };
      };

      systemd.services.nixos-boot-verify = {
        description = "Verify post-boot health canaries and promote bootctl oneshot entry to default";
        wantedBy = ["multi-user.target"];
        after =
          ["network-online.target"]
          ++ (map (s:
            if lib.hasSuffix ".socket" s || lib.hasSuffix ".service" s
            then s
            else "${s}.service")
          cfg.canary.services);
        wants = ["network-online.target"];
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${bootVerifyScript}/bin/nixos-boot-verify";
        };
      };
    }

    (lib.mkIf cfg.reboot.hardwareWatchdog {
      systemd.settings.Manager = {
        RuntimeWatchdogSec = "30s";
        RebootWatchdogSec = "2m";
      };
    })

    (lib.mkIf cfg.statusServer.enable {
      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [cfg.statusServer.port];
      networking.firewall.extraInputRules = ''
        iifname "tailscale0" tcp dport ${toString cfg.statusServer.port} accept
        ip saddr 192.168.0.0/16 tcp dport ${toString cfg.statusServer.port} accept
      '';

      systemd.services.nixos-auto-update-status = {
        description = "Expose NixOS Auto-Update status.json over Tailscale";
        after = ["network.target" "tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${statusServerScript}/bin/nixos-auto-update-status-server";
          Restart = "always";
          RestartSec = "5s";
          DynamicUser = true;
          ReadOnlyPaths = [cfg.stateDir];
        };
      };
    })

    (lib.mkIf cfg.gitMirror.enable {
      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [9418];
      networking.firewall.extraInputRules = ''
        iifname "tailscale0" tcp dport 9418 accept
        ip saddr 192.168.0.0/16 tcp dport 9418 accept
      '';

      systemd.services.nixos-auto-update-git-mirror = {
        description = "Read-only Git daemon serving nixcfg and nixos-secrets on Tailscale";
        after = ["network.target" "tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.git}/bin/git daemon --reuseaddr --export-all --base-path=${cfg.stateDir} ${cfg.stateDir}";
          Restart = "always";
          RestartSec = "5s";
          DynamicUser = true;
          ReadOnlyPaths = [cfg.stateDir];
        };
      };
    })

    (lib.mkIf cfg.desktopNotifications.enable {
      systemd.user.services.fleet-health-notify = {
        description = "Notify KDE Plasma desktop when a NixOS fleet host requires an attended reboot or rolled back";
        after = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${desktopNotifyScript}/bin/fleet-health-notify";
        };
      };

      systemd.user.timers.fleet-health-notify = {
        description = "Periodic check for NixOS fleet health alerts in active desktop session";
        wantedBy = ["graphical-session.target"];
        timerConfig = {
          OnStartupSec = "45s";
          OnUnitActiveSec = "30m";
        };
      };
    })
  ]);
}
