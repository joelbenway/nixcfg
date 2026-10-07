# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
# nix build .#nixosConfigurations.therese.config.system.build.isoImage
{
  lib,
  pkgs,
  modulesPath,
  self,
  hostname,
  platform,
  inputs,
  ...
}: let
  wifiEnvPath = lib.custom.relativeToRoot "wifi.env";
  hasWifiEnv = builtins.pathExists wifiEnvPath;

  sshKeyPath = lib.custom.relativeToRoot "id_ed25519";
  hasSshKey = builtins.pathExists sshKeyPath;

  filteredSource =
    builtins.filterSource (
      srcpath: type:
        baseNameOf srcpath
        != ".git"
        && baseNameOf srcpath != ".gitignore"
        && type != "symlink"
    )
    self;

  installScript = pkgs.writeShellScriptBin "install" ''
    echo "Installing..."
    if [ -f /etc/id_ed25519 ]; then
      exec bash /iso/nixcfg/hosts/therese/install_flake --key /etc/id_ed25519 "$@"
    else
      exec bash /iso/nixcfg/hosts/therese/install_flake "$@"
    fi
  '';
in {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    (lib.custom.relativeToRoot "modules/networkstack.nix")
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.nixPath = ["nixpkgs=${inputs.nixpkgs}"];
  nixpkgs.hostPlatform = platform;

  users.users.nixos = {
    openssh.authorizedKeys.keys = let keys = import (lib.custom.relativeToRoot "data/keys.nix"); in [keys.joel];
  }; # users.users.nixos

  networkstack = {
    hostName = hostname;
    wifiHome = hasWifiEnv;
    envFile =
      if hasWifiEnv
      then wifiEnvPath
      else null;
  }; #networkstack

  environment.etc = lib.mkIf hasSshKey {
    "id_ed25519" = {
      source = sshKeyPath;
      mode = "0444";
    };
  };

  isoImage.contents = [
    {
      source = filteredSource;
      target = "/nixcfg";
    }
  ];

  environment.systemPackages = with pkgs; [
    age
    btrfs-progs
    disko
    git
    installScript
    jq
    sbctl
    util-linux
  ];
}
