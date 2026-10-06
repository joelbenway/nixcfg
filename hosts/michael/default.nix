{
  config,
  hostname,
  lib,
  modulesPath,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  network = import ./network.nix;
  vlanList = builtins.attrValues network.vlans;
  allInternalInterfaces = [network.lanInterface network.oob.interface] ++ (map (v: v.interface) vlanList);
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
    wanInterface = network.wanInterface;
    vlans = network.vlans;
    extraInternalIPs = [
      "${network.mgmt.subnet}.0/${toString network.mgmt.prefix}"
    ];
  };

  netprov = {
    enable = true;
    networkConfig = network;
  };

  networking = {
    useDHCP = false;
    nameservers = [
      "127.0.0.1" # Local Pi-hole + Unbound root recursive resolver
      "9.9.9.9" # Quad9 primary (Swiss privacy foundation, zero-logging)
      "149.112.112.112" # Quad9 secondary
    ];

    vlans = builtins.listToAttrs (map (vlan: {
        name = vlan.interface;
        value = {
          inherit (vlan) id;
          interface = network.lanInterface;
        };
      })
      vlanList);

    interfaces =
      {
        "${network.wanInterface}".useDHCP = true;
        "${network.lanInterface}".ipv4.addresses = [
          {
            address = network.mgmt.routerIp;
            prefixLength = network.mgmt.prefix;
          }
        ];
        "${network.oob.interface}".ipv4.addresses = [
          {
            address = network.oob.routerIp;
            prefixLength = network.oob.prefix;
          }
        ];
      }
      // (builtins.listToAttrs (map (vlan: {
          name = vlan.interface;
          value = {
            ipv4.addresses = [
              {
                address = vlan.routerIp;
                prefixLength = vlan.prefix;
              }
            ];
          };
        })
        vlanList));

    firewall = {
      filterForward = true;
      # Do not expose ports globally across all interfaces (protects WAN)
      allowedTCPPorts = lib.mkForce [];
      allowedUDPPorts = lib.mkForce [];

      extraInputRules = ''
        # Allow DNS & Web UI on all internal interfaces
        iifname {${lib.concatStringsSep ", " allInternalInterfaces}} tcp dport {53, 80, 443} accept
        iifname {${lib.concatStringsSep ", " allInternalInterfaces}} udp dport {53, 67} accept

        # Allow SSH on trusted internal LAN (skylab + mgmt), emergency OOB rescue port, and Tailscale
        iifname {"${network.lanInterface}", "${network.vlans.skylab.interface}", "${network.oob.interface}", "tailscale0"} tcp dport 22 accept
      '';
      extraForwardRules = ''
        # Allow all internal VLANs and management network to forward outbound to WAN (Internet)
        iifname {${lib.concatStringsSep ", " allInternalInterfaces}} oifname "${network.wanInterface}" accept

        # skylab (trusted family) -> all other internal zones
        iifname "${network.vlans.skylab.interface}" oifname "${network.vlans.skynet.interface}" accept
        iifname "${network.vlans.skylab.interface}" oifname "${network.vlans.iot.interface}" accept
        iifname "${network.vlans.skylab.interface}" oifname "${network.lanInterface}" accept

        # skynet (guests) -> iot (casting to TVs/speakers)
        iifname "${network.vlans.skynet.interface}" oifname "${network.vlans.iot.interface}" accept
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
      openFirewallDNS = false;
      openFirewallDHCP = false;
      settings = {
        dns = {
          upstream = ["127.0.0.1#5353"];
          listeningMode = "ALL";
        };
        dhcp = {
          active = true;
          ranges =
            map (vlan: {
              from = "${vlan.subnet}.100";
              to = "${vlan.subnet}.250";
              router = vlan.routerIp;
              domain = "${vlan.name}.home";
            })
            vlanList;
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

    hnsd = {
      enable = true;
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
        stub-zone = [
          {
            name = ".";
            stub-addr = "127.0.0.1@5354";
          }
        ];
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
