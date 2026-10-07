# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.netprov;

  networkJsonFile = pkgs.writeText "network.json" (builtins.toJSON cfg.networkConfig);

  pythonEnv = pkgs.python3.withPackages (ps:
    with ps; [
      requests
      paramiko
    ]);

  netprovPkg = pkgs.writeScriptBin "netprov" ''
    #!${pkgs.bash}/bin/bash
    export NETPROV_CONFIG="''${NETPROV_CONFIG:-/etc/netprov/network.json}"
    exec ${pythonEnv}/bin/python3 ${../pkgs/netprov/netprov.py} "$@"
  '';
in {
  options.netprov = {
    enable = lib.mkEnableOption "netprov network infrastructure provisioning tool";
    networkConfig = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Declared network topology (interfaces, switch, AP)";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [netprovPkg];

    environment.etc."netprov/network.json" = {
      source = networkJsonFile;
      mode = "0644";
    };
  };
}
