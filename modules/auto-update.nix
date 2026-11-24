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
  deployKeySecretFile = lib.custom.relativeToRoot "secrets/github-secrets-deploy-key.age";
  hasDeployKeySecret = builtins.pathExists deployKeySecretFile;

  # Write status.json helper script (and publish actionable transitions to fleet-notify)
  writeStatusScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-write-status";
    runtimeInputs =
      (with pkgs; [bash coreutils jq])
      ++ lib.optional (config.notify.client.enable or false) config.notify.client.package;
    text = ''
      export AUTO_UPDATE_STATE_DIR="${cfg.stateDir}"
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      exec bash ${../pkgs/auto-update/write-status.sh} "$@"
    '';
  };

  # Host-specific canary check script
  canaryScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-canary";
    runtimeInputs = with pkgs; [
      bash
      bind.dnsutils
      coreutils
      glibc.bin
      systemd
    ];
    text = ''
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      export CANARY_SERVICES="${lib.concatStringsSep " " cfg.canary.services}"
      export CANARY_CHECK_DNS="${lib.boolToString cfg.canary.checkDns}"
      exec bash ${../pkgs/auto-update/canary.sh} "$@"
    '';
  };

  # Post-boot verification & bootctl default promotion script
  bootVerifyScript = pkgs.writeShellApplication {
    name = "nixos-boot-verify";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      jq
      systemd
      canaryScript
      writeStatusScript
    ];
    text = ''
      export AUTO_UPDATE_STATE_DIR="${cfg.stateDir}"
      export AUTO_UPDATE_HOST_NAME="${hostname}"
      exec bash ${../pkgs/auto-update/boot-verify.sh} "$@"
    '';
  };

  # Main auto-update execution script
  updateScript = pkgs.writeShellApplication {
    name = "nixos-auto-update";
    runtimeInputs =
      (with pkgs; [
        bash
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
      exec bash ${../pkgs/auto-update/auto-update.sh} "$@"
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
  ]);
}
