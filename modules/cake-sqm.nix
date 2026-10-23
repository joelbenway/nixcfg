# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cake-sqm;
in {
  options.cake-sqm = {
    enable = lib.mkEnableOption "Cake SQM (Smart Queue Management) to eliminate bufferbloat";

    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp3s0";
      description = "WAN (external) physical interface name";
    };

    ifbInterface = lib.mkOption {
      type = lib.types.str;
      default = "ifb-wan";
      description = "IFB (Intermediate Functional Block) pseudo-device name for ingress shaping";
    };

    downloadBandwidth = lib.mkOption {
      type = lib.types.str;
      default = "275mbit";
      description = "Ingress (download) bandwidth target for Cake SQM";
    };

    uploadBandwidth = lib.mkOption {
      type = lib.types.str;
      default = "45mbit";
      description = "Egress (upload) bandwidth target for Cake SQM";
    };

    diffserv = lib.mkOption {
      type = lib.types.enum ["diffserv3" "diffserv4" "besteffort"];
      default = "diffserv4";
      description = "Diffserv queue tier configuration for prioritization (e.g. voice/gaming/bulk)";
    };

    ackFilter = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable ACK filtering on egress to optimize asymmetric connections";
    };

    rtt = lib.mkOption {
      type = lib.types.str;
      default = "100ms";
      description = "Target RTT for Cake's internal CoDel queue delay calculations";
    };

    extraEgressArgs = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra parameters to append to the egress Cake qdisc command";
    };

    extraIngressArgs = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra parameters to append to the ingress Cake qdisc command";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [
      "ifb"
      "sch_cake"
      "act_mirred"
      "cls_matchall"
    ];

    systemd.services.cake-sqm = {
      description = "Cake Smart Queue Management (SQM) on WAN Interface";
      after = [
        "network.target"
        "sys-subsystem-net-devices-${cfg.wanInterface}.device"
      ];
      wants = [
        "sys-subsystem-net-devices-${cfg.wanInterface}.device"
      ];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.iproute2
        pkgs.kmod
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        WAN="${cfg.wanInterface}"
        IFB="${cfg.ifbInterface}"

        echo "Initializing Cake SQM: WAN=$WAN (egress: ${cfg.uploadBandwidth}), IFB=$IFB (ingress: ${cfg.downloadBandwidth})..."

        # 1. Clean existing root qdiscs and filters safely
        tc qdisc del dev "$WAN" root 2>/dev/null || true
        tc qdisc del dev "$WAN" parent ffff: 2>/dev/null || true
        tc qdisc del dev "$IFB" root 2>/dev/null || true
        ip link set dev "$IFB" down 2>/dev/null || true
        ip link delete dev "$IFB" 2>/dev/null || true

        # 2. Configure Egress (Upload)
        ACK_FLAG=""
        if [ "${lib.boolToString cfg.ackFilter}" = "true" ]; then
          ACK_FLAG="ack-filter"
        fi

        echo "Applying Cake SQM egress on $WAN..."
        tc qdisc replace dev "$WAN" root cake \
          bandwidth ${cfg.uploadBandwidth} \
          ${cfg.diffserv} \
          dual-srchost \
          nat \
          $ACK_FLAG \
          rtt ${cfg.rtt} \
          ${cfg.extraEgressArgs}

        # 3. Configure Ingress (Download) via IFB pseudo-device
        echo "Creating IFB device $IFB..."
        ip link add name "$IFB" type ifb 2>/dev/null || true
        ip link set dev "$IFB" up

        echo "Redirecting $WAN ingress traffic to $IFB..."
        tc qdisc add dev "$WAN" handle ffff: ingress
        tc filter add dev "$WAN" parent ffff: matchall action mirred egress redirect dev "$IFB"

        echo "Applying Cake SQM ingress on $IFB..."
        tc qdisc replace dev "$IFB" root cake \
          bandwidth ${cfg.downloadBandwidth} \
          ${cfg.diffserv} \
          dual-dsthost \
          nat \
          ingress \
          rtt ${cfg.rtt} \
          ${cfg.extraIngressArgs}

        echo "Cake SQM successfully configured and active."
      '';

      preStop = ''
        WAN="${cfg.wanInterface}"
        IFB="${cfg.ifbInterface}"

        echo "Removing Cake SQM from $WAN and $IFB..."
        tc qdisc del dev "$WAN" root 2>/dev/null || true
        tc qdisc del dev "$WAN" parent ffff: 2>/dev/null || true
        tc qdisc del dev "$IFB" root 2>/dev/null || true
        ip link set dev "$IFB" down 2>/dev/null || true
        ip link delete dev "$IFB" 2>/dev/null || true
        echo "Cake SQM teardown complete."
      '';
    };

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "cake-status" ''
        echo "=================== Egress (Upload) on ${cfg.wanInterface} ==================="
        ${pkgs.iproute2}/bin/tc -s qdisc show dev ${cfg.wanInterface}
        echo ""
        echo "=================== Ingress (Download) on ${cfg.ifbInterface} ==================="
        ${pkgs.iproute2}/bin/tc -s qdisc show dev ${cfg.ifbInterface}
      '')
      (pkgs.writeShellScriptBin "cake-test" ''
        TARGET="''${1:-1.1.1.1}"
        echo "Measuring baseline RTT to $TARGET (5 pings)..."
        ${pkgs.iputils}/bin/ping -c 5 "$TARGET"
        echo ""
        echo "Cake SQM Statistics:"
        ${pkgs.iproute2}/bin/tc -s qdisc show dev ${cfg.wanInterface}
        echo ""
        ${pkgs.iproute2}/bin/tc -s qdisc show dev ${cfg.ifbInterface}
      '')
    ];
  };
}
