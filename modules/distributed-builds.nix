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

  mkBuildMachine = name: info: {
    hostName = "${name}.${tailnet}";
    system = "x86_64-linux";
    sshUser = "nix-ssh";
    sshKey = cfg.keyFile;
    protocol = "ssh-ng";
    publicHostKey = null;
    supportedFeatures = info.supportedFeatures;
    mandatoryFeatures = [];
    maxJobs = info.maxJobs;
    speedFactor = info.speedFactor;
  };

  otherBuilders = lib.removeAttrs builders [hostname];
in {
  options.distributed-builds = {
    enable = lib.mkEnableOption "distributed Nix builds over Tailscale";

    keyFile = lib.mkOption {
      type = with lib.types; either path str;
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
    ];
    nix = {
      distributedBuilds = true;
      extraOptions = ''
        builders-use-substitutes = true
      '';
      buildMachines = lib.mapAttrsToList mkBuildMachine otherBuilders;
    };

    nix.sshServe = {
      enable = true;
      write = true;
      trusted = true;
      keys = [keys.users.builder];
      protocol = "ssh-ng";
    };

    systemd.tmpfiles.rules = [
      "d /root/.ssh 0700 root root -"
    ];
  };
}
