# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: let
  cfg = config.actual;
in {
  options.actual = {
    enable = lib.mkEnableOption "Actual Budget";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5006;
      description = "Port for Actual Budget web interface";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address for Actual Budget to listen on";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/actual";
      description = "Directory for Actual Budget data";
    };
  };

  config = lib.mkIf cfg.enable {
    services.actual = {
      enable = true;
      openFirewall = true;
      settings = {
        port = cfg.port;
        hostname = cfg.hostname;
        dataDir = cfg.dataDir;
      };
    };
  };
}
