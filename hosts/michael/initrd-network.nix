# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  lib,
  pkgs,
  ...
}: let
  keys = import (lib.custom.relativeToRoot "data/keys.nix");
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  network = import ./network.nix;
in {
  # Provision a dedicated initrd host key on test/activation (fresh installs also create it in
  # scripts/install_host, and stage-1/lanzaboote fails loudly if missing during direct switch/boot).
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
