# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  lib,
  pkgs,
  ...
}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
in {
  # Ensure existing installations provision a dedicated initrd host key before boot-loader assembly
  system.activationScripts.initrdHostKey = lib.stringAfter ["persist-files"] ''
    if [ ! -f /persist/etc/ssh/initrd_host_ed25519_key ]; then
      ${pkgs.coreutils}/bin/mkdir -p /persist/etc/ssh
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f /persist/etc/ssh/initrd_host_ed25519_key >/dev/null
      ${pkgs.coreutils}/bin/chmod 0600 /persist/etc/ssh/initrd_host_ed25519_key
    fi
  '';

  boot.initrd = {
    kernelModules = ["igc" "8021q"];
    network = {
      enable = true;
      ssh = {
        enable = true;
        port = ports.initrdSsh.ssh;
        authorizedKeys = [
          keys.users.joel
          keys.users.katy
        ];
        hostKeys = [
          "/persist/etc/ssh/initrd_host_ed25519_key"
        ];
        ignoreEmptyHostKeys = true;
      };
    };
    systemd.network = {
      enable = true;
      wait-online.enable = false;
      netdevs."20-skylab" = {
        netdevConfig = {
          Name = "enp4s0.77";
          Kind = "vlan";
        };
        vlanConfig.Id = 77;
      };
      networks."10-lan-trunk" = {
        matchConfig.Name = "enp4s0";
        networkConfig = {
          VLAN = ["enp4s0.77"];
          Address = "192.168.1.1/24";
        };
      };
      networks."20-skylab" = {
        matchConfig.Name = "enp4s0.77";
        networkConfig = {
          Address = "192.168.77.1/24";
        };
      };
      networks."30-oob" = {
        matchConfig.Name = "enp5s0";
        networkConfig = {
          Address = "192.168.99.1/24";
        };
      };
    };
  };
}
