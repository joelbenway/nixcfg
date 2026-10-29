# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.actual;
  plaidCfg = cfg.plaid;
in {
  imports = [
    inputs.gone-to-plaid.nixosModules.default
    (lib.mkAliasOptionModule ["actual" "gone-to-plaid"] ["actual" "plaid"])
  ];

  options.actual = {
    enable = lib.mkEnableOption "Actual Budget";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5006;
      description = "Port for Actual Budget web interface";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for Actual Budget to listen on";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/actual";
      description = "Directory for Actual Budget data";
    };

    plaid = {
      enable = lib.mkEnableOption "gone-to-plaid Actual Budget sync bridge";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8085;
        description = "Port for the gone-to-plaid web dashboard and API";
      };

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/gone-to-plaid";
        description = "Directory for gone-to-plaid SQLite database and sync state";
      };

      syncInterval = lib.mkOption {
        type = lib.types.str;
        default = "4h";
        description = "Interval or systemd calendar expression for automatic ledger sync passes";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
        default = null;
        description = ''
          Optional path to an EnvironmentFile containing secrets:
          - PLAID_CLIENT_ID
          - PLAID_ENV (sandbox, production, or development)
          - PLAID_SANDBOX_SECRET (used when PLAID_ENV=sandbox)
          - PLAID_PRODUCTION_SECRET (used when PLAID_ENV=production)
          - PLAID_SECRET (fallback / single secret)
          - ACTUAL_SERVER_URL
          - ACTUAL_PASSWORD
          - ACTUAL_SYNC_ID
          - ACTUAL_ENCRYPTION_PASSWORD
        '';
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to open the web dashboard port in the firewall";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.actual = {
        enable = true;
        openFirewall = false;
        settings = {
          port = cfg.port;
          hostname = cfg.hostname;
          dataDir = cfg.dataDir;
          loginMethod = "header";
          allowedLoginMethods = ["header" "password"];
          trustedProxies = ["127.0.0.1" "::1"];
          trustedAuthProxies = ["127.0.0.1/32" "::1/128"];
        };
      };
    })

    (lib.mkIf plaidCfg.enable {
      assertions = [
        {
          assertion = cfg.enable;
          message = "actual.plaid requires actual.enable = true";
        }
      ];

      services.gone-to-plaid = {
        enable = true;
        port = plaidCfg.port;
        dataDir = plaidCfg.dataDir;
        syncInterval = plaidCfg.syncInterval;
        environmentFile = plaidCfg.environmentFile;
      };

      networking.firewall.allowedTCPPorts = lib.mkIf plaidCfg.openFirewall [
        plaidCfg.port
      ];

      # Persist data directory across reboots when impermanence is enabled
      impermanence.directories = lib.mkIf config.impermanence.enable [
        plaidCfg.dataDir
      ];

      # Ensure dataDir exists with correct ownership and permissions
      systemd.tmpfiles.rules = [
        "d ${plaidCfg.dataDir} 0750 plaid-sync plaid-sync -"
      ];
    })
  ];
}
