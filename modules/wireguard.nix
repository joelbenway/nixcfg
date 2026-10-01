{
  config,
  lib,
  ...
}: let
  cfg = config.wireguard;

  peerType = lib.types.submodule {
    options = {
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "Base64 public key of the remote peer";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Endpoint address (host:port) of the peer";
      };
      allowedIPs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "CIDR ranges to route through this peer";
      };
      presharedKeyFile = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = "Path to a file containing the preshared key";
      };
      persistentKeepalive = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = 25;
        description = "Seconds between keepalive packets (null to disable)";
      };
    };
  };

  tunnelType = lib.types.submodule {
    options = {
      privateKeyFile = lib.mkOption {
        type = with lib.types; either path str;
        description = "Path to the WireGuard private key file";
      };
      address = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "IP addresses assigned to this interface";
      };
      dns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "DNS servers to configure for this interface";
      };
      peers = lib.mkOption {
        type = lib.types.listOf peerType;
        default = [];
        description = "Peers linked to this interface";
      };
      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Bring up this interface automatically during boot";
      };
      mtu = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "MTU for the WireGuard interface (null = auto)";
      };
      preUp = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Command called before the interface is brought up";
      };
      postUp = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Command called after the interface is brought up";
      };
      preDown = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Command called before the interface is taken down";
      };
      postDown = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Command called after the interface is taken down";
      };
    };
  };
in {
  options.wireguard = {
    enable = lib.mkEnableOption "WireGuard VPN tunnels";

    tunnels = lib.mkOption {
      type = lib.types.attrsOf tunnelType;
      default = {};
      description = "WireGuard tunnel interfaces (e.g. pia, proton)";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wg-quick.interfaces =
      lib.mapAttrs (name: tunnel: {
        inherit
          (tunnel)
          privateKeyFile
          address
          dns
          autostart
          mtu
          preUp
          postUp
          preDown
          postDown
          ;
        peers =
          map (peer: {
            inherit (peer) publicKey allowedIPs;
            endpoint = peer.endpoint;
            presharedKeyFile = peer.presharedKeyFile;
            persistentKeepalive = peer.persistentKeepalive;
          })
          tunnel.peers;
      })
      cfg.tunnels;
  };
}
