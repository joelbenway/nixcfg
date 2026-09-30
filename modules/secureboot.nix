{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.secureboot;
in {
  options.secureboot = {
    enable = lib.mkEnableOption "Secure Boot via lanzaboote";
  };

  imports = [inputs.lanzaboote.nixosModules.lanzaboote];

  config = lib.mkIf cfg.enable {
    boot = {
      lanzaboote = {
        enable = true;
        pkiBundle = "/var/lib/sbctl";
        autoGenerateKeys.enable = true;
        autoEnrollKeys = {
          enable = true;
          autoReboot = true;
        };
      };
      loader = {
        systemd-boot.enable = lib.mkForce false;
        efi.canTouchEfiVariables = true;
      };
    };
  };
}
