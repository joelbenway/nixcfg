# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{
  config,
  pkgs,
  inputs,
  lib,
  platform,
  ...
}: let
  nixAccessTokensFile = lib.custom.relativeToRoot "secrets/nix-access-tokens.conf.age";
  hasNixAccessTokens = builtins.pathExists nixAccessTokensFile;
  fleetNotifyPubTokenFile = lib.custom.relativeToRoot "secrets/fleet-notify-pub.token.age";
  hasFleetNotifyPubToken = builtins.pathExists fleetNotifyPubTokenFile;
in {
  imports = [
    inputs.agenix.nixosModules.default
    {
      environment.systemPackages = [inputs.agenix.packages.${platform}.default];
    }
  ];

  age.secrets =
    lib.optionalAttrs hasNixAccessTokens {
      nix-access-tokens = {
        file = nixAccessTokensFile;
        name = "nix-access-tokens.conf";
        mode = "0440";
        owner = "root";
        group = "wheel";
      };
    }
    // lib.optionalAttrs hasFleetNotifyPubToken {
      fleet-notify-pub-token = {
        file = fleetNotifyPubTokenFile;
        name = "fleet-notify-pub.token";
        mode = "0440";
        owner = "root";
        group = "wheel";
      };
    };

  nixpkgs.hostPlatform = platform;

  system.stateVersion = "23.11";
  nixpkgs.config.allowUnfree = true;
  users.mutableUsers = false;

  nix = {
    settings = {
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      http-connections = 128;
      max-substitution-jobs = 128;
      extra-substituters = [
        "https://cache.numtide.com"
        "https://nix-community.cachix.org"
        "https://numtide.cachix.org"
      ];
      extra-trusted-public-keys = [
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
      ];
    }; # settings

    nixPath = ["nixpkgs=${inputs.nixpkgs}"];

    extraOptions = lib.mkIf hasNixAccessTokens ''
      !include ${config.age.secrets.nix-access-tokens.path}
    '';

    gc = {
      automatic = true;
      randomizedDelaySec = "14m";
      options = "--delete-older-than 60d";
      persistent = true;
    }; # gc
  }; # nix

  boot.loader.systemd-boot.configurationLimit = 20;

  # Set your time zone.
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";

  security = {
    polkit.enable = true;
    sudo.extraConfig = ''
      Defaults env_keep += "SSH_AUTH_SOCK"
    '';
  };

  environment.systemPackages = with pkgs; [
    age
    btop
    curl
    dnsutils
    htop
    nh
    p7zip
    ripgrep
    sbctl
    tmux
    tree
    vim
    wget
  ];

  services = {
    libinput.enable = true;
    pcscd.enable = true;
  }; # services

  smartd.enable = true;

  notify.client = {
    enable = true;
    publishTokenFile = lib.mkIf hasFleetNotifyPubToken config.age.secrets.fleet-notify-pub-token.path;
  };

  beszel.agent = {
    enable = true;
    smartmon = true;
    smartInterval = "12h";
    systemd = true;
  };
}
