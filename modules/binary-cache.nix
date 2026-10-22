# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
  cfg = config.binary-cache;
in {
  options.binary-cache = {
    server = {
      enable = lib.mkEnableOption "Harmonia binary cache server";
      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
        description = "Port for Harmonia binary cache to listen on";
      };
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Open the binary cache port in the firewall";
      };
      signKeyPath = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = "Path to private signing key for the binary cache";
      };
    };

    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable substitution from local fleet binary cache";
      };
      substituters = lib.mkOption {
        type = with lib.types; listOf str;
        default = [
          "http://zita.home:5000"
        ];
        description = "List of local binary cache substituter URLs";
      };
      trustedPublicKeys = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
        description = "Public keys trusted to sign binaries from local substituters";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.server.enable {
      services.harmonia.cache = {
        enable = true;
        settings = {
          bind = "[::]:${toString cfg.server.port}";
        };
        signKeyPaths = lib.optional (cfg.server.signKeyPath != null) cfg.server.signKeyPath;
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.server.openFirewall [cfg.server.port];
    })

    (lib.mkIf cfg.client.enable {
      nix.settings = {
        extra-substituters = lib.filter (url: !lib.hasInfix "zita" url || !cfg.server.enable) cfg.client.substituters;
        extra-trusted-public-keys = cfg.client.trustedPublicKeys;
        connect-timeout = lib.mkDefault 5;
      };
    })
  ];
}
