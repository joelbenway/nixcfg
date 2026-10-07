# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  ...
}: {
  options.openssh = {
    enable = lib.mkEnableOption "enable openssh";
    hostKeyPath = lib.mkOption {
      type = with lib.types; nullOr (either path str);
      default = "/etc/ssh/ssh_host_ed25519_key";
      description = "Path to ed25519 host key";
    }; # hostKeyPath
  }; # options

  config = lib.mkIf config.openssh.enable {
    services = {
      openssh = {
        enable = true;
        openFirewall = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        }; # settings
        listenAddresses = [
          {
            addr = "0.0.0.0";
            port = 22;
          }
        ];
        hostKeys = [
          {
            path = config.openssh.hostKeyPath;
            type = "ed25519";
          }
        ]; # hostKeys
        knownHosts = let
          keys = import (lib.custom.relativeToRoot "data/keys.nix");
        in
          lib.mapAttrs (_: publicKey: {inherit publicKey;}) keys.hosts; # knownHosts
      }; # openssh
    }; # services
  }; # config
}
