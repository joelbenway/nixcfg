{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      gpgFile = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Path to <user>-gpg-keys.asc file to import";
      }; # gpgFile
    }; # options
  }; # userConfigType
in {
  options = {
    gpg = {
      users = lib.mkOption {
        type = lib.types.attrsOf userConfigType;
        default = {};
        description = "Per user gpg configuration";
      };
    }; # gpg
  }; # options

  config = {
    home-manager.users = lib.mapAttrs (user: cfg:
      lib.mkIf (cfg.gpgFile != null) {
        programs = {
          gpg = {
            enable = true;
            mutableKeys = true;
            mutableTrust = true;
          }; # gpg
        }; # programs

        home.activation.importUserGpgKeys =
          lib.mkIf (cfg.gpgFile != null)
          (inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
            $DRY_RUN_CMD ${pkgs.gnupg}/bin/gpg --batch --quiet --import ${cfg.gpgFile}
            for fpr in $(${pkgs.gnupg}/bin/gpg --show-keys --with-colons ${cfg.gpgFile} | ${pkgs.gawk}/bin/awk -F: '/^fpr:/ {print $10}'); do
              echo "$fpr:6:" | $DRY_RUN_CMD ${pkgs.gnupg}/bin/gpg --import-ownertrust
            done
          '');

        services = {
          gpg-agent = {
            enable = true;
            pinentry.package = pkgs.pinentry-qt;
          }; # gpg-agent
        }; # services
      })
    config.gpg.users;
  };
}
