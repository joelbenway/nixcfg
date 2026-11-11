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
  network = import ./network.nix;
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (lib.custom.relativeToRoot "hardware/alderlake.nix")
    ./dns.nix
    ./initrd-network.nix
    ./remote-unlock.nix
    ./routing.nix
  ];

  impermanence = {
    enable = true;
    device = "cryptroot";
  };

  age = {
    identityPaths = ["/persist${hostKeyPath}"];
    secrets = {
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
      wifi-env = {
        file = lib.custom.relativeToRoot "secrets/wifi.env.age";
        name = "wifi.env";
        mode = "400";
        owner = "root";
        group = "root";
      };
      wifi-guest-env = {
        file = lib.custom.relativeToRoot "secrets/wifi-guest.env.age";
        name = "wifi-guest.env";
        mode = "400";
        owner = "root";
        group = "root";
      };
      pia-env = {
        file = lib.custom.relativeToRoot "secrets/pia.env.age";
        name = "pia.env";
        mode = "400";
        owner = "root";
        group = "root";
      };
    };
  };

  openssh = {
    enable = true;
    hostKeyPath = hostKeyPath;
  };

  distributed-builds = {
    enable = true;
    keyFile = config.age.secrets.nix-builder-ssh.path;
  };

  joel = {
    enable = true;
    desktop = false;
  };

  networkstack = {
    hostName = hostname;
  };

  tailscale = {
    enable = true;
    advertiseExitNode = true;
    advertiseRoutes = ["192.168.77.0/24"];
    envFile = config.age.secrets.tailscale-oauth-env.path;
  };

  firewall = {
    enable = true;
    wanInterface = network.wanInterface;
    vlans = network.vlans;
    extraInternalIPs = [
      "${network.mgmt.subnet}.0/${toString network.mgmt.prefix}"
      "100.64.0.0/10" # Tailscale CGNAT range for exit node NAT masquerade
    ];
  };

  netprov = {
    enable = true;
    networkConfig = network;
  };

  cake-sqm = {
    enable = true;
    wanInterface = network.wanInterface;
    downloadBandwidth = "275mbit";
    uploadBandwidth = "45mbit";
    diffserv = "diffserv4";
    ackFilter = true;
    rtt = "100ms";
  };

  telemetry = {
    enable = true;
    interfaces = [
      network.wanInterface
      network.lanInterface
      network.vlans.skylab.interface
      network.vlans.skynet.interface
      network.vlans.iot.interface
    ];
    port = 3000;
  };

  services.vpn-gateway = {
    enable = true;
    wanInterface = network.wanInterface;
    routedInterfaces = [network.vlans.iot.interface];
    torrentPorts = [51413];
    killSwitch = true;
    providers.pia = {
      enable = true;
      credentialsFile = config.age.secrets.pia-env.path;
      region = "us_chicago";
    };
    providers.proton = {
      enable = false;
    };
  };

  secureboot.enable = true;

  boot = {
    enableContainers = true;
    extraModulePackages = [];
    initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "nvme"
      "usb_storage"
      "uas"
      "usbhid"
      "sd_mod"
      "igc"
      "r8169"
      "8021q"
    ];
    kernelModules = [
      "kvm-intel"
    ];
    kernelParams = [
      "intel_iommu=on"
      "tpm_tis.interrupts=0"
    ];
  };

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = ["/"];
  };

  disko.devices = (import ./disks.nix {inherit lib;}).disko.devices;

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
    dates = "*-*-* 06:00:00";
    randomizedDelaySec = "10m";
    canary = {
      checkDns = true;
      services = [
        "pihole-ftl"
        "unbound"
        "nftables"
        "pia-wireguard"
      ];
    };
    reboot = {
      enable = true;
      window = "03:30";
      hardwareWatchdog = true;
    };
  };
}
