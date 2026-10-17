# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.vpn-gateway;

  piaCaCert = ../data/pia-ca.crt;

  piaWgScript = pkgs.writeShellApplication {
    name = "pia-wireguard";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      iproute2
      iputils
      jq
      wireguard-tools
    ];
    text = ''
      set -euo pipefail

      CRED_FILE="''${1:-}"
      if [[ -n "$CRED_FILE" && -f "$CRED_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CRED_FILE"
      fi

      PIA_USER="''${PIA_USER:-}"
      PIA_PASS="''${PIA_PASS:-}"
      PIA_REGION="''${PIA_REGION:-${cfg.providers.pia.region}}"
      CA_CERT="${piaCaCert}"
      TABLE_ID="${toString cfg.tableId}"
      INTERFACE="${cfg.providers.pia.interface}"

      if [[ -z "$PIA_USER" || -z "$PIA_PASS" ]]; then
        echo "ERROR: PIA_USER and PIA_PASS must be set." >&2
        exit 1
      fi

      cleanup() {
        echo "[*] Cleaning up WireGuard interface $INTERFACE..."
        ip route del default dev "$INTERFACE" table "$TABLE_ID" 2>/dev/null || true
        ip link del dev "$INTERFACE" 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      echo "[*] Authenticating with PIA API for user $PIA_USER..."
      TOKEN_RESPONSE=$(curl -s --max-time 15 --location --request POST \
        'https://www.privateinternetaccess.com/api/client/v2/token' \
        --form "username=$PIA_USER" \
        --form "password=$PIA_PASS")

      PIA_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -er '.token // empty')
      if [[ -z "$PIA_TOKEN" ]]; then
        echo "ERROR: Failed to obtain PIA token: $TOKEN_RESPONSE" >&2
        exit 1
      fi

      echo "[*] Querying server info for region $PIA_REGION..."
      SERVER_JSON=$(curl -s --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/v4' | \
        jq -e --arg reg "$PIA_REGION" '.regions[] | select(.id == $reg)')

      WG_SERVER_IP=$(echo "$SERVER_JSON" | jq -er '.servers.wg[0].ip')
      WG_HOSTNAME=$(echo "$SERVER_JSON" | jq -er '.servers.wg[0].cn')

      echo "[*] Selected PIA endpoint: $WG_HOSTNAME ($WG_SERVER_IP)"

      echo "[*] Generating local WireGuard keys..."
      PRIV_KEY=$(wg genkey)
      PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

      echo "[*] Registering WireGuard public key with $WG_HOSTNAME..."
      WG_RESPONSE=$(curl -s -G --max-time 15 \
        --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
        --cacert "$CA_CERT" \
        --data-urlencode "pt=$PIA_TOKEN" \
        --data-urlencode "pubkey=$PUB_KEY" \
        "https://$WG_HOSTNAME:1337/addKey")

      STATUS=$(echo "$WG_RESPONSE" | jq -r '.status // empty')
      if [[ "$STATUS" != "OK" ]]; then
        echo "ERROR: PIA addKey failed: $WG_RESPONSE" >&2
        exit 1
      fi

      PEER_IP=$(echo "$WG_RESPONSE" | jq -er '.peer_ip')
      SERVER_KEY=$(echo "$WG_RESPONSE" | jq -er '.server_key')
      SERVER_PORT=$(echo "$WG_RESPONSE" | jq -er '.server_port')

      echo "[+] Successfully registered with PIA! Assigned IP: $PEER_IP"

      echo "[*] Configuring $INTERFACE..."
      ip link del dev "$INTERFACE" 2>/dev/null || true
      ip link add dev "$INTERFACE" type wireguard
      echo "$PRIV_KEY" | wg set "$INTERFACE" \
        private-key /dev/stdin \
        peer "$SERVER_KEY" \
        endpoint "$WG_SERVER_IP:$SERVER_PORT" \
        persistent-keepalive 25 \
        allowed-ips 0.0.0.0/0

      ip addr add "$PEER_IP/32" dev "$INTERFACE"
      ip link set mtu 1420 up dev "$INTERFACE"

      echo "[*] Configuring policy routing table $TABLE_ID..."
      ip route replace default dev "$INTERFACE" table "$TABLE_ID"

      echo "[+] WireGuard tunnel $INTERFACE is UP and active on table $TABLE_ID."

      # Connection health check loop
      FAIL_COUNT=0
      while true; do
        sleep 15
        if ! ping -c 1 -W 3 -I "$INTERFACE" 1.1.1.1 &>/dev/null; then
          FAIL_COUNT=$((FAIL_COUNT + 1))
          echo "[!] Health check failed ($FAIL_COUNT/3)..."
          if [[ $FAIL_COUNT -ge 3 ]]; then
            echo "[-] Connection dead. Restarting service..." >&2
            exit 1
          fi
        else
          FAIL_COUNT=0
        fi
      done
    '';
  };
in {
  options.services.vpn-gateway = {
    enable = lib.mkEnableOption "Always-on Policy Routing VPN Gateway";

    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp3s0";
      description = "Physical WAN interface (used for kill-switch leak prevention)";
    };

    routedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of internal interfaces (e.g. IoT VLAN) whose outbound traffic is forced over VPN";
    };

    torrentPorts = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [51413];
      description = "List of BitTorrent / Transmission ports forced over VPN";
    };

    killSwitch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to strictly block VPN-bound traffic from escaping via physical WAN when VPN is down";
    };

    tableId = lib.mkOption {
      type = lib.types.int;
      default = 51820;
      description = "Routing table ID for VPN traffic";
    };

    fwmark = lib.mkOption {
      type = lib.types.int;
      default = 81; # 0x51
      description = "Firewall mark applied to VPN-bound packets";
    };

    providers = {
      pia = {
        enable = lib.mkEnableOption "Private Internet Access (PIA) WireGuard provider";
        credentialsFile = lib.mkOption {
          type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
          default = null;
          description = "Path to environment file containing PIA_USER and PIA_PASS";
        };
        region = lib.mkOption {
          type = lib.types.str;
          default = "us_chicago";
          description = "PIA region ID (e.g. us_chicago, us_east, ca_ontario)";
        };
        interface = lib.mkOption {
          type = lib.types.str;
          default = "wg-pia";
          description = "WireGuard interface name for PIA";
        };
      };

      proton = {
        enable = lib.mkEnableOption "ProtonVPN WireGuard provider (backup for IoT)";
        configFile = lib.mkOption {
          type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
          default = null;
          description = "Path to downloaded ProtonVPN WireGuard .conf file";
        };
        interface = lib.mkOption {
          type = lib.types.str;
          default = "wg-proton";
          description = "WireGuard interface name for ProtonVPN";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Loose reverse path filtering is mandatory for policy routing
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.rp_filter" = 2;
      "net.ipv4.conf.default.rp_filter" = 2;
    };

    # Policy Routing Rules: fwmark -> tableId, with unreachable kill switch
    systemd.services.vpn-policy-routing = {
      description = "VPN Gateway Policy Routing Rules";
      wantedBy = ["multi-user.target"];
      before = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "vpn-policy-routing-start" ''
          ${pkgs.iproute2}/bin/ip rule add fwmark ${toString cfg.fwmark} table ${toString cfg.tableId} priority 1000 2>/dev/null || true
          ${lib.optionalString cfg.killSwitch ''
            ${pkgs.iproute2}/bin/ip rule add fwmark ${toString cfg.fwmark} type unreachable priority 1001 2>/dev/null || true
          ''}
        '';
        ExecStop = pkgs.writeShellScript "vpn-policy-routing-stop" ''
          ${pkgs.iproute2}/bin/ip rule del fwmark ${toString cfg.fwmark} priority 1000 2>/dev/null || true
          ${lib.optionalString cfg.killSwitch ''
            ${pkgs.iproute2}/bin/ip rule del fwmark ${toString cfg.fwmark} priority 1001 2>/dev/null || true
          ''}
        '';
      };
    };

    # PIA WireGuard daemon service
    systemd.services.pia-wireguard = lib.mkIf cfg.providers.pia.enable {
      description = "Private Internet Access (PIA) WireGuard Client";
      after = ["network-online.target" "vpn-policy-routing.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "10s";
        ExecStart = "${piaWgScript}/bin/pia-wireguard ${toString cfg.providers.pia.credentialsFile}";
      };
    };

    # nftables: packet classification, firewall kill-switch, and NAT masquerade
    networking.nftables.tables.vpn-gateway = {
      family = "inet";
      content = ''
        chain prerouting {
          type filter hook prerouting priority mangle; policy accept;

          # Exclude private RFC1918, Tailscale, and broadcast/multicast from VPN
          ip daddr { 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, 224.0.0.0/4, 255.255.255.255 } return;

          # Policy Route: IoT interfaces
          ${lib.concatMapStrings (iface: ''
            iifname "${iface}" meta mark set ${toString cfg.fwmark};
          '')
          cfg.routedInterfaces}

          # Policy Route: BitTorrent / Transmission traffic
          ${lib.concatMapStrings (port: ''
            tcp sport ${toString port} meta mark set ${toString cfg.fwmark};
            udp sport ${toString port} meta mark set ${toString cfg.fwmark};
            tcp dport ${toString port} meta mark set ${toString cfg.fwmark};
            udp dport ${toString port} meta mark set ${toString cfg.fwmark};
          '')
          cfg.torrentPorts}
          tcp dport { 6881-6889 } meta mark set ${toString cfg.fwmark};
          udp dport { 6881-6889 } meta mark set ${toString cfg.fwmark};
        }

        chain forward {
          type filter hook forward priority filter - 1; policy accept;

          # Strict Kill-Switch: Drop VPN-bound traffic attempting to exit physical WAN
          ${lib.optionalString cfg.killSwitch ''
          meta mark ${toString cfg.fwmark} oifname "${cfg.wanInterface}" drop;
          ${lib.concatMapStrings (iface: ''
              iifname "${iface}" oifname "${cfg.wanInterface}" drop;
            '')
            cfg.routedInterfaces}
        ''}
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;

          # Masquerade traffic exiting VPN tunnels
          oifname { "${cfg.providers.pia.interface}", "${cfg.providers.proton.interface}" } masquerade;
        }
      '';
    };
  };
}
