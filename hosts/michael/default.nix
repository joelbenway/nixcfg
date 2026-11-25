# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  modulesPath,
  ...
}: let
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

  age.secrets = {
    luks-passphrase = {
      file = lib.custom.relativeToRoot "secrets/${hostname}-luks-passphrase.age";
      name = "${hostname}-luks-passphrase.txt";
      mode = "400";
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

  distributed-builds.enable = true;

  joel = {
    enable = true;
    desktop = false;
  };

  networkstack = {
    hostName = hostname;
  };

  tailscale = {
    advertiseExitNode = true;
    advertiseRoutes = ["192.168.77.0/24"];
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

  disko.devices = (import ./disks.nix {inherit lib;}).disko.devices;

  tpm = {
    enable = true;
    passwordFile = config.age.secrets.luks-passphrase.path;
    devices = [
      "/dev/disk/by-partlabel/disk-main-swap"
      "/dev/disk/by-partlabel/disk-main-root"
    ];
  };

  notify.client.onFailureUnits = [
    "pihole-ftl"
    "unbound"
  ];

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
