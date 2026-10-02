{
  config,
  hostname,
  inputs,
  lib,
  modulesPath,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";

  vlanIot = {
    id = 69;
    name = "iot";
    subnet = "192.168.69";
    prefix = 24;
    interface = "eno2.69";
  };

  vlanSkynet = {
    id = 62;
    name = "skynet";
    subnet = "192.168.62";
    prefix = 24;
    interface = "eno2.62";
  };

  vlanSkylab = {
    id = 77;
    name = "skylab";
    subnet = "192.168.77";
    prefix = 24;
    interface = "eno2.77";
  };

  vlans = [vlanIot vlanSkynet vlanSkylab];
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (lib.custom.relativeToRoot "hardware/alderlake.nix")
  ];

  impermanence = {
    enable = true;
    device = "cryptroot";
    directories = [
      "/var/lib/pihole"
      "/var/lib/unbound"
    ];
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
    envFile = config.age.secrets.tailscale-oauth-env.path;
  };

  firewall = {
    enable = true;
    wanInterface = "eno1";
    vlans = {
      iot = vlanIot;
      skynet = vlanSkynet;
      skylab = vlanSkylab;
    };
  };

  networking = {
    useDHCP = false;

    vlans = let
      mkVlan = vlan: {
        name = vlan.interface;
        value = {
          id = vlan.id;
          interface = "eno2";
        };
      };
    in
      builtins.listToAttrs (map mkVlan vlans);

    interfaces =
      {
        eno1.useDHCP = true;
      }
      // (let
        mkVlanAddr = vlan: {
          name = vlan.interface;
          value = {
            ipv4.addresses = [
              {
                address = "${vlan.subnet}.1";
                prefixLength = vlan.prefix;
              }
            ];
          };
        };
      in
        builtins.listToAttrs (map mkVlanAddr vlans));

    firewall = {
      filterForward = true;
      extraInputRules = ''
        iifname {${lib.concatStringsSep ", " (map (v: v.interface) vlans)}} tcp dport {53, 80, 443} accept
        iifname {${lib.concatStringsSep ", " (map (v: v.interface) vlans)}} udp dport {53, 67} accept
      '';
      extraForwardRules = ''
        # skylab → skynet
        iifname "${vlanSkylab.interface}" oifname "${vlanSkynet.interface}" accept
        # skylab → iot
        iifname "${vlanSkylab.interface}" oifname "${vlanIot.interface}" accept
        # skynet → iot
        iifname "${vlanSkynet.interface}" oifname "${vlanIot.interface}" accept
      '';
    };
  };

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
      ];
      kernelModules = [];
    };
    kernelModules = [
      "kvm-intel"
    ];
    kernelParams = [
      "intel_iommu=on"
      "tpm_tis.interrupts=0"
    ];
  };

  services = {
    btrfs = {
      autoScrub = {
        enable = true;
        interval = "monthly";
        fileSystems = ["/"];
      };
    };

    pihole-ftl = {
      enable = true;
      openFirewallDNS = true;
      openFirewallDHCP = true;
      settings = {
        dns = {
          upstream = ["127.0.0.1#5353"];
        };
        dhcp = {
          active = true;
          ranges =
            map (vlan: {
              from = "${vlan.subnet}.100";
              to = "${vlan.subnet}.250";
              router = "${vlan.subnet}.1";
              domain = "${vlan.name}.home";
            })
            vlans;
        };
      };
      lists = [
        {
          url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
          type = "block";
          description = "Steven Black's unified hosts file";
          enabled = true;
        }
        {
          url = "https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt";
          type = "block";
          description = "Disconnect simple ad list";
          enabled = true;
        }
        {
          url = "https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt";
          type = "block";
          description = "Disconnect simple tracking list";
          enabled = true;
        }
        {
          url = "https://s3.amazonaws.com/lists.disconnect.me/simple_malware.txt";
          type = "block";
          description = "Disconnect simple malware list";
          enabled = true;
        }
        {
          url = "https://raw.githubusercontent.com/AnonymouseGlobal/blocklist/master/blocklist.txt";
          type = "block";
          description = "Anonymouse ad blocklist";
          enabled = true;
        }
      ];
    };

    pihole-web = {
      enable = true;
      ports = [80];
    };

    unbound = {
      enable = true;
      settings = {
        server = {
          interface = ["127.0.0.1"];
          port = 5353;
          do-ip4 = true;
          do-ip6 = false;
          do-udp = true;
          do-tcp = true;
          harden-dnssec-stripped = true;
          harden-referral-path = true;
          cache-min-ttl = 300;
          cache-max-ttl = 86400;
          prefetch = true;
          num-threads = 4;
        };
      };
    };
  };

  disko.devices = (import ./disks.nix {}).disko.devices;

  fileSystems."/var/log".neededForBoot = true;

  tpm = {
    enable = true;
    passwordFile = config.age.secrets.luks-passphrase.path;
    devices = [
      "/dev/disk/by-partlabel/disk-main-swap"
      "/dev/disk/by-partlabel/disk-main-root"
    ];
  };
}
