# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  hostname,
  ...
}: let
  cfg = config.distributed-builds;
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
  builders = import (lib.custom.relativeToRoot "data/builders.nix");
  tailnet = config.tailscale.tailnet;

  isBuilder = builtins.hasAttr hostname builders;

  mkBuildMachine = name: info: {
    hostName = "${name}.${tailnet}";
    system = "x86_64-linux";
    sshUser = "nix-ssh";
    sshKey = cfg.keyFile;
    protocol = "ssh-ng";
    publicHostKey = keys.hostsBase64.${name} or null;
    supportedFeatures = info.supportedFeatures;
    mandatoryFeatures = [];
    maxJobs = info.maxJobs;
    speedFactor = info.speedFactor;
  };
in {
  options.distributed-builds = {
    enable = lib.mkEnableOption "distributed Nix builds over Tailscale";

    keyFile = lib.mkOption {
      type = with lib.types; nullOr (either path str);
      default = null;
      description = "Path to the SSH private key used to connect to remote builders";
      example = "/run/secrets/nix-builder-ssh";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.tailscale.tailnet != "";
        message = "tailscale.tailnet must be set when distributed-builds is enabled";
      }
      {
        assertion = isBuilder || cfg.keyFile != null;
        message = "distributed-builds.keyFile must be set for client build machines";
      }
    ];

    nix = {
      # Build servers (Michael and Zita) build locally and never delegate to remote machines.
      # Only client hosts distribute builds to the build servers.
      distributedBuilds = !isBuilder;
      extraOptions = lib.mkIf (!isBuilder) ''
        builders-use-substitutes = true
      '';
      buildMachines = lib.mkIf (!isBuilder) (lib.mapAttrsToList mkBuildMachine builders);
    };

    # Only designated build servers accept incoming build jobs over SSH.
    nix.sshServe = {
      enable = isBuilder;
      write = true;
      trusted = true;
      keys = [keys.users.builder];
      protocol = "ssh-ng";
    };

    systemd.tmpfiles.rules = lib.mkIf (!isBuilder) [
      "d /root/.ssh 0700 root root -"
    ];
  };
}
