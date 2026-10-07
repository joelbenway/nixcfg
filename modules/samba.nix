# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.samba = {
    enable = lib.mkEnableOption "Samba Server";
    shares = lib.mkOption {
      default = {};
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      description = "Samba share definitions.";
    }; # shares
  }; # options.samba

  config = lib.mkIf config.samba.enable {
    services.samba = {
      enable = true;
      package = pkgs.samba;
      openFirewall = true;
      settings =
        {
          global = {
            "workgroup" = "WORKGROUP";
            "server string" = "${config.networking.hostName} SMB Server";
            "netbios name" = "${config.networking.hostName}";
            "security" = "user";
            # "hosts allow" = "192.168. 100. 127.0.0.1";
            # "hosts deny" = "0.0.0.0/0";
            "guest account" = "nobody";
            "map to guest" = "bad user";
          }; # global
        }
        // config.samba.shares;
    }; # services.samba

    services.samba-wsdd = {
      enable = true;
      openFirewall = true;
    }; # services.samba-wsdd
  }; # config
}
