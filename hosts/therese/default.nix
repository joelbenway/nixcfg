# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
# nix build .#nixosConfigurations.therese.config.system.build.isoImage
{
  lib,
  pkgs,
  modulesPath,
  hostname,
  platform,
  inputs,
  ...
}: let
  wifiGuestEnvPath = lib.custom.relativeToRoot "wifi-guest.env";
  hasWifiGuestEnv = builtins.pathExists wifiGuestEnvPath;

  tsBootstrapEnvPath = lib.custom.relativeToRoot "tailscale-oauth-bootstrap.env";
  hasTsBootstrapEnv = builtins.pathExists tsBootstrapEnvPath;

  keys = import (lib.custom.relativeToRoot "data/keys.nix");
in {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    (lib.custom.relativeToRoot "modules/networkstack.nix")
    (lib.custom.relativeToRoot "modules/tailscale.nix")
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.nixPath = ["nixpkgs=${inputs.nixpkgs}"];
  nixpkgs.hostPlatform = platform;

  users.users.root.openssh.authorizedKeys.keys = [keys.joel];
  users.users.nixos.openssh.authorizedKeys.keys = [keys.joel];

  services.getty.helpLine = ''
    Therese Bootstrap Installer
    Connect via SSH or Tailscale from an operator machine to deploy.
  '';

  networkstack = {
    hostName = hostname;
    wifiHome = lib.mkDefault hasWifiGuestEnv;
    wifiIot = lib.mkDefault hasWifiGuestEnv;
    envFiles = lib.optional hasWifiGuestEnv wifiGuestEnvPath;
  }; # networkstack

  tailscale = {
    enable = lib.mkDefault hasTsBootstrapEnv;
    envFile = lib.mkIf hasTsBootstrapEnv tsBootstrapEnvPath;
    tags = ["tag:bootstrap"];
    ephemeral = true;
  };

  environment.systemPackages = with pkgs; [
    age
    btrfs-progs
    curl
    disko
    git
    jq
    rsync
    sbctl
    util-linux
  ];
}
