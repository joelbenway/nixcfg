# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  network = import ./network.nix;
  piholeGroups = import ./pihole-groups.nix {inherit lib;};
  vlanList = builtins.attrValues network.vlans;
in {
  impermanence.directories = [
    "/var/lib/pihole"
    "/var/lib/unbound"
  ];

  nixpkgs.overlays = [
    (_final: prev: {
      pihole-ftl = prev.pihole-ftl.overrideAttrs (old: {
        env.NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " -Wno-error=unused-but-set-variable";
      });
    })
  ];

  services = {
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

              # Never forward plain names (without a dot) to upstream resolvers
              "domain-needed"

              # Never forward reverse lookups for private address ranges upstream
              "bogus-priv"

              # Never forward queries for local domains upstream
              "local=/home/"
              "local=/skylab.home/"
              "local=/skynet.home/"
              "local=/iot.home/"
              "local=/mgmt.home/"

              # Automatically expand simple hostnames to include the domain
              "expand-hosts"

              # Forward Tailscale MagicDNS queries from Pi-hole to Tailscale Quad-100 resolver
              "server=/${config.tailscale.tailnet}/100.100.100.100"
              "server=/100.in-addr.arpa/100.100.100.100"

              # Static DNS host records for trusted LAN infrastructure
              "host-record=zita,zita.skylab.home,zita.home,192.168.77.20"
              "host-record=michael,michael.skylab.home,michael.home,192.168.77.1"

              # Service CNAMEs pointing to Zita on local LAN (reachable with or without Tailscale)
              "cname=files.benway.me,zita.skylab.home"
              "cname=budget.benway.me,zita.skylab.home"
              "cname=plaid.benway.me,zita.skylab.home"
              "cname=jellyfin.benway.me,zita.skylab.home"
              "cname=git.benway.me,zita.skylab.home"
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
          domain-insecure = [
            "home"
            "skylab.home"
            "skynet.home"
            "iot.home"
            "mgmt.home"
            "internal"
            "local"
            config.tailscale.tailnet
          ];
          private-domain = [
            "home"
            "skylab.home"
            "skynet.home"
            "iot.home"
            "mgmt.home"
            "internal"
            "local"
            config.tailscale.tailnet
          ];
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
}
