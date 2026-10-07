# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  modulesPath,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (lib.custom.relativeToRoot "hardware/alice75.nix")
    (lib.custom.relativeToRoot "hardware/printer.nix")
    (lib.custom.relativeToRoot "hardware/pipewire.nix")
    (lib.custom.relativeToRoot "hardware/r1pro.nix")
    (lib.custom.relativeToRoot "hardware/coffeelake.nix")
  ]; # imports

  impermanence = {
    enable = true;
    device = "cryptroot";
  }; # impermanence

  age = {
    identityPaths = ["/persist${hostKeyPath}"];
    secrets = {
      wifi-environment-variables = {
        file = lib.custom.relativeToRoot "secrets/wifi.env.age";
        mode = "600";
        owner = "root";
        group = "users";
      }; # wifi-environment-variables
      wifi-guest-environment-variables = {
        file = lib.custom.relativeToRoot "secrets/wifi-guest.env.age";
        mode = "600";
        owner = "root";
        group = "users";
      }; # wifi-guest-environment-variables
      tailscale-oauth-env = {
        file = lib.custom.relativeToRoot "secrets/tailscale-oauth.env.age";
        name = "tailscale.env";
        mode = "400";
        owner = "root";
        group = "root";
      }; # tailscale-oauth-env
      luks-passphrase = {
        file = lib.custom.relativeToRoot "secrets/${hostname}-luks-passphrase.age";
        name = "${hostname}-luks-passphrase.txt";
        mode = "400";
        owner = "root";
        group = "root";
      }; # luks-passphrase
      nix-builder-ssh = {
        file = lib.custom.relativeToRoot "secrets/nix-builder-ssh.age";
        path = "/root/.ssh/nix-builder";
        mode = "600";
        owner = "root";
        group = "root";
      };
    }; # secrets
  }; # age

  openssh = {
    enable = true;
    inherit hostKeyPath;
  };

  distributed-builds = {
    enable = true;
    keyFile = config.age.secrets.nix-builder-ssh.path;
  };

  joel.enable = true;

  networkstack = {
    hostName = hostname;
    wifiHome = true;
    wifiLab = true;
    envFiles = [
      config.age.secrets.wifi-environment-variables.path
      config.age.secrets.wifi-guest-environment-variables.path
    ];
  }; # networkstack

  tailscale = {
    enable = true;
    envFile = config.age.secrets.tailscale-oauth-env.path;
  }; # tailscale

  llm = {
    enable = true;
    hw = {};
  }; # llm

  hardware.bluetooth.enable = true;

  secureboot.enable = true;

  boot = {
    enableContainers = true;
    extraModulePackages = [];
    initrd = {
      systemd.enable = true;
      availableKernelModules = [
        "xhci_pci"
        "ahci"
        "nvme"
        "usb_storage"
        "uas"
        "usbhid"
        "sd_mod"
        "rtsx_pci_sdmmc"
      ];
      kernelModules = [];
    }; # initrd
    kernelModules = [
      "kvm-intel"
    ];
    kernelParams = [
      "intel_iommu=on"
      "mem_sleep_default=deep"
      "tpm_tis.interrupts=0"
    ];
  }; # boot

  disko.devices = (import ./disks.nix {}).disko.devices;

  fileSystems."/var/log".neededForBoot = true;

  tpm = {
    enable = true;
    passwordFile = config.age.secrets.luks-passphrase.path;
    devices = [
      "/dev/disk/by-partlabel/disk-main-swap"
      "/dev/disk/by-partlabel/disk-main-root"
    ];
  }; # tpm
}
