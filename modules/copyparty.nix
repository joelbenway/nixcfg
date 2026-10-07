# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  inputs,
  lib,
  ...
}: let
  userOpts = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Username for copyparty account";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing user password";
    };

    canWriteMedia = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether user can write to /media";
    };
  };
in {
  options.copyparty = {
    enable = lib.mkEnableOption "Copyparty file server";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "files.benway.me";
      description = "Domain name for copyparty";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3923;
      description = "Port to listen on";
    };

    users = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {options = userOpts;});
      default = [];
      description = "List of copyparty users";
    };
  };

  config = let
    cfg = config.copyparty;
    mediaWriters = map (u: u.name) (lib.filter (u: u.canWriteMedia) cfg.users);

    userVolumes = lib.listToAttrs (map (u: {
        name = "/${u.name}";
        value = {
          path = "/storage/users/${u.name}";
          access.rw = [u.name];
        };
      })
      cfg.users);

    userAccounts = lib.listToAttrs (map (u: {
        name = u.name;
        value.passwordFile = u.passwordFile;
      })
      cfg.users);

    userBindMounts = lib.listToAttrs (map (u: {
        name = "/storage/users/${u.name}";
        value = {
          hostPath = "/storage/users/${u.name}";
          isReadOnly = false;
        };
      })
      cfg.users);

    passwordBindMounts = lib.listToAttrs (map (u: {
        name = u.passwordFile;
        value = {
          hostPath = u.passwordFile;
          isReadOnly = true;
        };
      })
      cfg.users);
  in
    lib.mkIf cfg.enable {
      networking.firewall.allowedTCPPorts = [cfg.port];

      containers.copyparty = {
        autoStart = true;

        bindMounts =
          {
            "/storage/public" = {
              hostPath = "/storage/public";
              isReadOnly = false;
            };
            "/storage/media" = {
              hostPath = "/storage/media";
              isReadOnly = false;
            };
          }
          // userBindMounts
          // passwordBindMounts;

        config = {...}: {
          imports = [inputs.copyparty.nixosModules.default];

          services.copyparty = {
            enable = true;
            user = "copyparty";
            group = "copyparty";

            accounts = userAccounts;

            settings = {
              i = "0.0.0.0";
              p = cfg.port;
              no_reload = true;
            };

            volumes =
              {
                "/public" = {
                  path = "/storage/public";
                  access.rw = "*";
                };

                "/media" = {
                  path = "/storage/media";
                  access =
                    if mediaWriters == []
                    then {r = "*";}
                    else {
                      r = "*";
                      rw = mediaWriters;
                    };
                };
              }
              // userVolumes;
          };

          users.users.copyparty = {
            isSystemUser = true;
            group = "copyparty";
          };
          users.groups.copyparty = {};

          system.stateVersion = "24.11";
        };
      };
    };
}
