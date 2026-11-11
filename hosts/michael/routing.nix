# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: let
  network = import ./network.nix;
  vlanList = builtins.attrValues network.vlans;
  allInternalInterfaces = [network.lanInterface network.oob.interface] ++ (map (v: v.interface) vlanList);
in {
  networking = {
    useDHCP = false;
    dhcpcd.extraConfig = "nohook resolv.conf";
    nameservers = [
      "127.0.0.1" # Local Pi-hole + Unbound root recursive resolver
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

        # Allow trusted internal zones (skylab + mgmt) to route to Tailscale
        iifname {"${network.vlans.skylab.interface}", "${network.lanInterface}"} oifname "tailscale0" accept

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

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          # Masquerade traffic from trusted internal zones forwarded to Tailscale so devices without Tailscale can reach Tailscale nodes
          oifname "tailscale0" ip saddr 192.168.0.0/16 masquerade;
        }
      '';
    };
  };
}
