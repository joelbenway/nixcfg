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
    users = lib.mkOption {
      default = {};
      type = lib.types.attrsOf (lib.types.coercedTo lib.types.str (p: {passwordFile = p;}) (lib.types.submodule {
        options = {
          passwordFile = lib.mkOption {
            type = lib.types.str;
            description = "Path to file containing plaintext password for the Samba user.";
          };
        };
      }));
      description = "Declarative Samba users and their password files.";
    }; # users
  }; # options.samba

  config = lib.mkIf config.samba.enable (let
    storageConfig = import (lib.custom.relativeToRoot "data/shares.nix");

    # Derive standard shares from data/shares.nix
    derivedShares =
      lib.mapAttrs' (_key: share: {
        name = share.name;
        value =
          {
            path = share.path;
            browseable = "yes";
            "read only" =
              if share.readOnly
              then "yes"
              else "no";
            "guest ok" =
              if share.guestOk
              then "yes"
              else "no";
            comment = share.comment;
            "create mask" = "0664";
            "directory mask" = "0775";
            "force group" = share.forceGroup or "users";
          }
          // lib.optionalAttrs (share ? forceUser) {"force user" = share.forceUser;}
          // lib.optionalAttrs (share ? writeList) {"write list" = lib.concatStringsSep " " share.writeList;};
      })
      storageConfig.shares;

    # Derive personal user shares if enabled
    derivedUserShares = lib.optionalAttrs (storageConfig.userShares.enable or false) (
      lib.mapAttrs' (username: _: let
        capName = (lib.toUpper (lib.substring 0 1 username)) + (lib.substring 1 (-1) username);
      in {
        name = capName;
        value = {
          path = "${storageConfig.userShares.basePath}/${username}";
          "valid users" = username;
          "read only" = "no";
          browseable = "yes";
          "force user" = username;
          "force group" = "users";
          "create mask" = "0664";
          "directory mask" = "0775";
        };
      })
      config.samba.users
    );

    allDerivedShares = derivedShares // derivedUserShares;
  in {
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
        // allDerivedShares
        // config.samba.shares;
    }; # services.samba

    services.samba-wsdd = {
      enable = true;
      openFirewall = true;
    }; # services.samba-wsdd

    systemd.services.samba-sync-users = lib.mkIf (config.samba.users != {}) {
      description = "Synchronize declarative Samba users and passwords";
      wantedBy = ["multi-user.target"];
      before = ["samba-smbd.service"];
      requiredBy = ["samba-smbd.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      restartTriggers = lib.mapAttrsToList (_: u: u.passwordFile) config.samba.users;
      path = [
        pkgs.coreutils
        pkgs.samba
      ];
      script = ''
        set -eu
        mkdir -p /var/lib/samba/private
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: u: ''
            if [ -s "${u.passwordFile}" ]; then
              PASS="$(tr -d '\r\n' < "${u.passwordFile}")"
              if pdbedit -L -u "${name}" >/dev/null 2>&1; then
                printf '%s\n%s\n' "$PASS" "$PASS" | smbpasswd -s "${name}"
              else
                printf '%s\n%s\n' "$PASS" "$PASS" | smbpasswd -s -a "${name}"
              fi
              smbpasswd -e "${name}"
              echo "Successfully synced Samba password for user '${name}'."
            else
              echo "Warning: Samba password file '${u.passwordFile}' for user '${name}' is empty or missing, skipping." >&2
            fi
          '')
          config.samba.users)}
      '';
    }; # systemd.services.samba-sync-users

    systemd.services.samba-smbd = lib.mkIf (config.samba.users != {}) {
      wants = ["samba-sync-users.service"];
      after = ["samba-sync-users.service"];
    };
  }); # config
}
