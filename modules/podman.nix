# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.podman = {
    enable = lib.mkEnableOption "Enable podman";
  }; # options.podman

  config = lib.mkIf config.podman.enable {
    virtualisation.podman = {
      enable = true;
      autoPrune.enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true; # Required for containers under podman-compose to be able to talk to each other.
    }; # virtualisation.podman

    environment.systemPackages = with pkgs; [
      # distrobox
      podman-compose
      # podman-desktop
    ]; # environment.systemPackages
  }; # config
}
