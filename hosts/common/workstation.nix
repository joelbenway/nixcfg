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
  fleetNotifySubTokenFile = lib.custom.relativeToRoot "secrets/fleet-notify-sub.token.age";
  hasFleetNotifySubToken = builtins.pathExists fleetNotifySubTokenFile;
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (lib.custom.relativeToRoot "hardware/alice75.nix")
    (lib.custom.relativeToRoot "hardware/printer.nix")
    (lib.custom.relativeToRoot "hardware/pipewire.nix")
    (lib.custom.relativeToRoot "hardware/r1pro.nix")
  ];

  options.workstation.iommuParam = lib.mkOption {
    type = lib.types.str;
    default = "intel_iommu=on";
    description = "Intel IOMMU kernel parameter for workstation hosts (override e.g. to intel_iommu=on,igfx_off).";
  };

  config = {
    impermanence = {
      enable = true;
      device = "cryptroot";
    };

    age = {
      identityPaths = ["/persist${hostKeyPath}"];
      secrets =
        {
          wifi-environment-variables = {
            file = lib.custom.relativeToRoot "secrets/wifi.env.age";
            mode = "600";
            owner = "root";
            group = "users";
          };
          wifi-guest-environment-variables = {
            file = lib.custom.relativeToRoot "secrets/wifi-guest.env.age";
            mode = "600";
            owner = "root";
            group = "users";
          };
          tailscale-oauth-env = {
            file = lib.custom.relativeToRoot "secrets/tailscale-oauth.env.age";
            name = "tailscale.env";
            mode = "400";
            owner = "root";
            group = "root";
          };
          luks-passphrase = {
            file = lib.custom.relativeToRoot "secrets/${hostname}-luks-passphrase.age";
            name = "${hostname}-luks-passphrase.txt";
            mode = "400";
            owner = "root";
            group = "root";
          };
          nix-builder-ssh = {
            file = lib.custom.relativeToRoot "secrets/nix-builder-ssh.age";
            path = "/root/.ssh/nix-builder";
            mode = "600";
            owner = "root";
            group = "root";
          };
        }
        // lib.optionalAttrs hasFleetNotifySubToken {
          fleet-notify-sub-token = {
            file = fleetNotifySubTokenFile;
            name = "fleet-notify-sub.token";
            mode = "0440";
            owner = "root";
            group = "users";
          };
        };
    };

    notify.client.subscribeTokenFile = lib.mkIf hasFleetNotifySubToken config.age.secrets.fleet-notify-sub-token.path;

    openssh = {
      enable = true;
      inherit hostKeyPath;
    };

    distributed-builds = {
      enable = true;
      keyFile = config.age.secrets.nix-builder-ssh.path;
    };

    plasma.enable = lib.mkDefault true;

    joel.enable = true;

    networkstack = {
      hostName = hostname;
      wifiHome = true;
      wifiLab = true;
      envFiles = [
        config.age.secrets.wifi-environment-variables.path
        config.age.secrets.wifi-guest-environment-variables.path
      ];
    };

    tailscale = {
      enable = true;
      acceptDns = true;
      envFile = config.age.secrets.tailscale-oauth-env.path;
    };

    syncthing.enable = true;

    hardware.bluetooth.enable = true;

    secureboot.enable = true;

    boot = {
      enableContainers = true;
      extraModulePackages = [];
      initrd = {
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
      };
      kernelModules = [
        "kvm-intel"
      ];
      kernelParams = [
        config.workstation.iommuParam
        "mem_sleep_default=deep"
        "tpm_tis.interrupts=0"
      ];
    };

    fileSystems."/var/log".neededForBoot = true;

    tpm = {
      enable = true;
      passwordFile = config.age.secrets.luks-passphrase.path;
      devices = [
        "/dev/disk/by-partlabel/disk-main-swap"
        "/dev/disk/by-partlabel/disk-main-root"
      ];
    };

    auto-update = {
      enable = true;
      dates = "*-*-* 06:15:00";
      randomizedDelaySec = "15m";
      # Workstations/laptops apply user-space updates automatically and notify via fleet-notify when a kernel reboot is ready
      reboot.enable = false;
    };
  };
}
