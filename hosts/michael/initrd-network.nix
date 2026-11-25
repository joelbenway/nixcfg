# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  network = import ./network.nix;
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
          Name = network.vlans.skylab.interface;
          Kind = "vlan";
        };
        vlanConfig.Id = network.vlans.skylab.id;
      };
      networks."10-lan-trunk" = {
        matchConfig.Name = network.lanInterface;
        networkConfig = {
          VLAN = [network.vlans.skylab.interface];
          Address = "${network.mgmt.routerIp}/${toString network.mgmt.prefix}";
        };
      };
      networks."20-skylab" = {
        matchConfig.Name = network.vlans.skylab.interface;
        networkConfig = {
          Address = "${network.vlans.skylab.routerIp}/${toString network.vlans.skylab.prefix}";
        };
      };
      networks."30-oob" = {
        matchConfig.Name = network.oob.interface;
        networkConfig = {
          Address = "${network.oob.routerIp}/${toString network.oob.prefix}";
        };
      };
    };
  };
}
