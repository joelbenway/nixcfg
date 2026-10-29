# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  hostKeyPath = "/etc/ssh/ssh_host_ed25519_key";
  network = import ./network.nix;
  piholeGroups = import ./pihole-groups.nix {inherit lib;};
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

  nixpkgs.overlays = [
    (_final: prev: {
      pihole-ftl = prev.pihole-ftl.overrideAttrs (old: {
        env.NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error=unused-but-set-variable";
      });
    })
  ];

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
      zita-luks-passphrase = {
        file = lib.custom.relativeToRoot "secrets/zita-luks-passphrase.age";
        name = "zita-luks-passphrase.txt";
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

  networking = {
    useDHCP = false;
    dhcpcd.extraConfig = "nohook resolv.conf";
    nameservers = [
      "127.0.0.1" # Local Pi-hole + Unbound root recursive resolver
      "9.9.9.9" # Quad9 primary (Swiss privacy foundation, zero-logging)
      "149.112.112.112" # Quad9 secondary
    ];

    networkmanager.unmanaged = [
      network.wanInterface
      network.lanInterface
      network.oob.interface
      "interface-name:${network.lanInterface}.*"
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
      checkReversePath = false;
      filterForward = true;
      # Do not expose ports globally across all interfaces (protects WAN)
      allowedTCPPorts = lib.mkForce [];
      allowedUDPPorts = lib.mkForce [];

      extraInputRules = ''
        # Allow DNS (53) & DHCP (67) on all internal interfaces and Tailscale
        iifname {${lib.concatStringsSep ", " (allInternalInterfaces ++ ["tailscale0"])}} udp dport {53, 67} accept
        iifname {${lib.concatStringsSep ", " (allInternalInterfaces ++ ["tailscale0"])}} tcp dport 53 accept

        # Reject DNS-over-TLS (853) on Tailscale with TCP reset so Android instantly falls back to port 53
        iifname "tailscale0" tcp dport 853 reject with tcp reset;

        # Allow Web UI (80, 443) and SSH (22) only on trusted internal LAN (skylab + mgmt), emergency OOB rescue port, and Tailscale
        iifname {"${network.lanInterface}", "${network.vlans.skylab.interface}", "${network.oob.interface}", "tailscale0"} tcp dport {22, 80, 443} accept

        # Prevent untrusted interfaces from reaching router IPs outside their designated gateway
        iifname "${network.vlans.iot.interface}" ip daddr != "${network.vlans.iot.routerIp}" drop
        iifname "${network.vlans.skynet.interface}" ip daddr != "${network.vlans.skynet.routerIp}" drop
      '';
      extraForwardRules = ''
        # Allow all internal VLANs, management network, and Tailscale exit node to forward outbound to WAN (Internet)
        iifname {${lib.concatStringsSep ", " (allInternalInterfaces ++ ["tailscale0"])}} oifname "${network.wanInterface}" accept

        # skylab (trusted family) -> all other internal zones
        iifname "${network.vlans.skylab.interface}" oifname "${network.vlans.skynet.interface}" accept
        iifname "${network.vlans.skylab.interface}" oifname "${network.vlans.iot.interface}" accept
        iifname "${network.vlans.skylab.interface}" oifname "${network.lanInterface}" accept

        # skynet (guests) -> iot (casting to TVs/speakers)
        iifname "${network.vlans.skynet.interface}" oifname "${network.vlans.iot.interface}" accept

        # Allow Tailscale to access trusted internal zone (skylab)
        iifname "tailscale0" oifname "${network.vlans.skylab.interface}" accept
      '';
    };

    nftables.tables.tailscale-exit = {
      family = "inet";
      content = ''
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          # Transparently redirect all DNS traffic from Tailscale to local Pi-hole
          iifname "tailscale0" meta l4proto { tcp, udp } th dport 53 redirect to :53;
        }

        chain forward {
          type filter hook forward priority filter - 1; policy accept;
          # Clamp TCP MSS for Tailscale exit node traffic in both directions to prevent MTU black holes
          oifname "tailscale0" tcp flags syn tcp option maxseg size set 1220;
          iifname "tailscale0" tcp flags syn tcp option maxseg size set 1220;

          # Reject IPv6 traffic attempting to route from Tailscale to WAN (no IPv6 internet on WAN)
          iifname "tailscale0" oifname "${network.wanInterface}" meta nfproto ipv6 reject with icmpv6 type no-route;
        }
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
          upstreams = ["127.0.0.1#5353"];
          listeningMode = "ALL";
        };
        dhcp = {
          active = true;
          start = "${network.mgmt.subnet}.10";
          end = "${network.mgmt.subnet}.50";
          router = network.mgmt.routerIp;
          netmask = "255.255.255.0";
          leaseTime = "24h";
        };
        misc = {
          dnsmasq_lines =
            [
              # Management LAN interface
              "dhcp-range=tag:${network.lanInterface},${network.mgmt.subnet}.10,${network.mgmt.subnet}.50,255.255.255.0,24h"
              "dhcp-option=tag:${network.lanInterface},option:router,${network.mgmt.routerIp}"
              "dhcp-option=tag:${network.lanInterface},option:dns-server,${network.mgmt.routerIp}"
              "dhcp-option=tag:${network.lanInterface},option:domain-name,${network.mgmt.name}.home"
              "domain=${network.mgmt.name}.home,${network.mgmt.subnet}.0/24"

              # Static reservation for Zyxel AP
              "dhcp-host=80:ea:0b:4b:b2:bb,${network.ap.ip},zyxel-ap,infinite"
            ]
            ++ (lib.concatMap (vlan: [
                "dhcp-range=tag:${vlan.interface},${vlan.subnet}.100,${vlan.subnet}.250,255.255.255.0,24h"
                "dhcp-option=tag:${vlan.interface},option:router,${vlan.routerIp}"
                "dhcp-option=tag:${vlan.interface},option:dns-server,${vlan.routerIp}"
                "dhcp-option=tag:${vlan.interface},option:domain-name,${vlan.name}.home"
                "domain=${vlan.name}.home,${vlan.subnet}.0/24"
              ])
              vlanList)
            ++ [
              # Match WireGuard tunnel MTU (1420) for IoT DHCP clients
              "dhcp-option=tag:${network.vlans.iot.interface},option:mtu,1420"

              # Forward Tailscale MagicDNS queries from Pi-hole to Tailscale Quad-100 resolver
              "server=/${config.tailscale.tailnet}/100.100.100.100"

              # Service CNAMEs pointing to Zita
              "cname=files.benway.me,zita.${config.tailscale.tailnet}"
              "cname=budget.benway.me,zita.${config.tailscale.tailnet}"
              "cname=plaid.benway.me,zita.${config.tailscale.tailnet}"
              "cname=zita.home,zita.${config.tailscale.tailnet}"
            ];
        };
      };
      lists = piholeGroups.allLists;
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
        forward-zone = [
          {
            name = ".";
            forward-addr = [
              "9.9.9.9"
              "149.112.112.112"
            ];
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

  systemd.services.pihole-ftl.wants = ["pihole-ftl-groups.service"];

  systemd.services.pihole-ftl-groups = {
    description = "Pi-hole FTL Group Management Configuration";
    after = ["pihole-ftl-setup.service"];
    wants = ["pihole-ftl-setup.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      User = config.services.pihole-ftl.user;
      Group = config.services.pihole-ftl.group;
    };
    path = with pkgs; [sqlite procps];
    script = let
      gravityDb = config.services.pihole-ftl.settings.files.gravity;
      sqlStatements = lib.concatStringsSep "\n" (
        (lib.mapAttrsToList (name: cat: ''
            INSERT OR IGNORE INTO "group" (name, description, enabled)
            VALUES ('${name}', '${lib.replaceStrings ["'"] ["''"] cat.description}', 1);
          '')
          piholeGroups.categories)
        ++ (lib.mapAttrsToList (name: cat: ''
            INSERT OR IGNORE INTO adlist_by_group (adlist_id, group_id)
            SELECT a.id, g.id FROM adlist a, "group" g
            WHERE g.name = '${name}' AND a.address IN (
              ${lib.concatMapStringsSep ",\n            " (it: "'${it.url}'") cat.lists}
            );
          '')
          piholeGroups.categories)
        ++ [
          ''
            DELETE FROM gravity
            WHERE adlist_id IN (
              SELECT a.id FROM adlist a
              WHERE a.address NOT IN (
                ${lib.concatMapStringsSep ",\n                " (it: "'${it.url}'") piholeGroups.allLists}
              )
            );

            DELETE FROM adlist_by_group
            WHERE adlist_id IN (
              SELECT a.id FROM adlist a
              WHERE a.address NOT IN (
                ${lib.concatMapStringsSep ",\n                " (it: "'${it.url}'") piholeGroups.allLists}
              )
            );

            DELETE FROM adlist
            WHERE address NOT IN (
              ${lib.concatMapStringsSep ",\n              " (it: "'${it.url}'") piholeGroups.allLists}
            );

            DELETE FROM adlist_by_group
            WHERE group_id = 0 AND adlist_id IN (
              SELECT a.id FROM adlist a
              WHERE a.address IN (
                ${lib.concatMapStringsSep ",\n                " (it: "'${it.url}'") piholeGroups.categories.Other.lists}
              )
            );
          ''
        ]
      );
    in ''
      if [ ! -f "${gravityDb}" ]; then
        echo "Gravity database not found at ${gravityDb}, skipping."
        exit 0
      fi

      sqlite3 "${gravityDb}" << 'EOF'
      PRAGMA busy_timeout = 5000;
      ${sqlStatements}
      EOF

      pkill -RTMIN pihole-FTL || true
      echo "Pi-hole groups configured successfully."
    '';
  };

  systemd.services.pihole-gravity-update = {
    description = "Update Pi-hole Gravity blocklists from remote sources";
    after = ["network-online.target" "pihole-ftl.service"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = config.services.pihole-ftl.user;
      Group = config.services.pihole-ftl.group;
      ExecStart = "${config.services.pihole-ftl.piholePackage}/bin/pihole updateGravity";
    };
  };

  systemd.timers.pihole-gravity-update = {
    description = "Weekly update of Pi-hole blocklist domains";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "Sun *-*-* 03:30:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "zita-unlock";
      runtimeInputs = with pkgs; [openssh netcat];
      text = ''
        target="''${1:-zita.home}"
        port="''${2:-2222}"
        keyfile="${config.age.secrets.zita-luks-passphrase.path}"

        if [ ! -r "$keyfile" ]; then
          echo "Error: Passphrase file $keyfile is not readable." >&2
          exit 1
        fi

        echo "Attempting to unlock Zita initrd ($target:$port)..."
        ssh -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o ConnectTimeout=5 \
            -i /etc/ssh/ssh_host_ed25519_key \
            -p "$port" \
            root@"$target" \
            "systemd-tty-ask-password-agent" < "$keyfile"
        echo "Passphrase successfully transmitted to Zita."
      '';
    })
  ];

  systemd.services.zita-auto-unlock = {
    description = "Probe and auto-unlock Zita initrd LUKS";
    path = with pkgs; [openssh netcat];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "zita-auto-unlock-probe" ''
        KEYFILE="${config.age.secrets.zita-luks-passphrase.path}"
        if [ ! -r "$KEYFILE" ]; then
          exit 0
        fi

        for target in "zita.home" "192.168.77.20"; do
          if nc -z -w 2 "$target" 2222 2>/dev/null; then
            echo "Detected Zita initrd SSH at $target:2222. Transmitting LUKS passphrase..."
            ssh -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                -o ConnectTimeout=5 \
                -i /etc/ssh/ssh_host_ed25519_key \
                -p 2222 \
                root@"$target" \
                "systemd-tty-ask-password-agent" < "$KEYFILE" && echo "Unlock command sent." || true
            break
          fi
        done
      '';
    };
  };

  systemd.timers.zita-auto-unlock = {
    description = "Periodic probe to auto-unlock Zita initrd";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "15s";
    };
  };
}
