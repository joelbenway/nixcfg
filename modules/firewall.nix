{
  config,
  lib,
  ...
}: let
  cfg = config.firewall;
  vlanType = lib.types.submodule {
    freeformType = lib.types.anything;
    options = {
      id = lib.mkOption {
        type = lib.types.int;
        description = "VLAN ID (802.1Q tag)";
      };
      name = lib.mkOption {
        type = lib.types.str;
        description = "VLAN name / domain label";
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        description = "VLAN subnet prefix (e.g. 192.168.69)";
      };
      routerIp = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "VLAN default gateway / router IP";
      };
      prefix = lib.mkOption {
        type = lib.types.int;
        default = 24;
        description = "Subnet prefix length";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        description = "VLAN interface name (e.g. eno2.69)";
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "VLAN description";
      };
      trusted = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this VLAN is trusted";
      };
    };
  };
in {
  options.firewall = {
    enable = lib.mkEnableOption "Home firewall with VLAN routing and NAT";
    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "eno1";
      description = "WAN (upstream) interface name";
    };
    vlans = lib.mkOption {
      type = lib.types.attrsOf vlanType;
      default = {};
      description = "VLAN definitions keyed by name";
    };
    extraInternalIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional internal subnets (CIDR) to masquerade via NAT";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlans != {};
        message = "firewall.vlans must be set when firewall.enable is true";
      }
    ];

    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault true;

    networking = {
      nftables.enable = lib.mkDefault true;
      nat = {
        enable = lib.mkDefault true;
        externalInterface = cfg.wanInterface;
        internalIPs =
          (map (vlan: "${vlan.subnet}.0/${toString vlan.prefix}")
            (builtins.attrValues cfg.vlans))
          ++ cfg.extraInternalIPs;
      };
      firewall = {
        enable = lib.mkDefault true;
        filterForward = lib.mkDefault true;
      };
    };
  };
}
