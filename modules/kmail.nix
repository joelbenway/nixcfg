# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable declarative KMail provisioning for this user";

      configFile = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = ''
          Path to the decrypted KMail JSON configuration file (typically from agenix).
        '';
      };

      prune = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Remove previously managed KMail accounts, transports, and identities
          when they are removed from configFile. Unmanaged entries are never touched.
        '';
      };
    };
  };

  kmailProvision = import ../pkgs/kmail-provision {inherit pkgs;};
in {
  options.kmail = {
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Per-user declarative KMail provisioning configuration";
    };
  };

  config = lib.mkIf config.plasma.enable {
    home-manager.users =
      lib.mapAttrs (
        _: cfg:
          lib.mkIf (cfg.enable && cfg.configFile != null) (let
            configPath = toString cfg.configFile;
          in {
            home.packages = [kmailProvision];

            systemd.user.services.kmail-provision = {
              Unit = {
                Description = "Provision declarative KMail accounts";
                After = ["graphical-session.target" "plasma-kwallet-pam.service"];
                PartOf = ["graphical-session.target"];
                ConditionPathExists = configPath;
              };
              Service = {
                Type = "oneshot";
                ExecStart = "${kmailProvision}/bin/kmail-provision --config ${lib.escapeShellArg configPath}${lib.optionalString cfg.prune " --prune"}";
              };
              Install = {
                WantedBy = ["graphical-session.target"];
              };
            };

            systemd.user.paths.kmail-provision = {
              Unit = {
                Description = "Watch declarative KMail config for updates";
                PartOf = ["graphical-session.target"];
              };
              Path = {
                PathChanged = configPath;
                Unit = "kmail-provision.service";
              };
              Install = {
                WantedBy = ["graphical-session.target"];
              };
            };
          })
      )
      config.kmail.users;
  };
}
