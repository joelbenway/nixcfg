# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
in {
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
          "/persist/etc/ssh/ssh_host_ed25519_key"
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
