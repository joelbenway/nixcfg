# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  inputs,
  utils,
  ...
}: let
  cfg = config.impermanence;

  persistentServiceType = lib.types.submodule ({name, ...}: {
    options = {
      directory = lib.mkOption {
        type = lib.types.str;
        description = "Persistent data directory to bind-mount via impermanence.";
      };
      service = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Primary systemd service ordered after the persisted directory mount.";
      };
      extraServices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional systemd services ordered after the persisted directory mount.";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Static system user owning the persisted directory (defaults to entry name when createUser = true).";
      };
      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Static system group owning the persisted directory (defaults to resolved user).";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0750";
        description = "Permission mode for the persisted directory tmpfiles rule.";
      };
      createUser = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create a static system user/group and disable DynamicUser/PrivateUsers on the service.";
      };
      description = lib.mkOption {
        type = lib.types.str;
        default = "${name} service user";
        description = "Description for the created static system user.";
      };
    };
  });

  normalizeDir = p: let
    parts = lib.filter (part: part != "") (lib.splitString "/" (toString p));
  in
    "/" + (lib.concatStringsSep "/" parts);

  escapeTmpfilesPath = path: "\"${lib.replaceStrings ["\\" "\"" "%" "\n" "\r" "\t"] ["\\\\" "\\\"" "%%" "\\n" "\\r" "\\t"] path}\"";

  resolveUser = name: svc:
    if svc.user != null
    then svc.user
    else if svc.createUser
    then name
    else null;

  resolveGroup = name: svc: let
    u = resolveUser name svc;
  in
    if svc.group != null
    then svc.group
    else u;

  baseDirs = [
    "/var/lib/bluetooth"
    "/var/lib/nixos"
    "/var/lib/systemd"
    {
      directory = "/var/lib/sbctl";
      mode = "0700";
    }
    "/var/lib/tailscale"
    "/etc/NetworkManager/system-connections"
    "/var/cache/huggingface"
  ];

  extractDir = entry:
    normalizeDir (
      if builtins.isAttrs entry
      then entry.directory
      else entry
    );

  existingDirs = map extractDir (baseDirs ++ cfg.directories);

  persistentServiceDirs = lib.unique (
    lib.filter (d: !(builtins.elem d existingDirs)) (
      lib.mapAttrsToList (_: svc: normalizeDir svc.directory) cfg.persistentServices
    )
  );

  createdUserEntries = lib.filterAttrs (_: svc: svc.createUser) cfg.persistentServices;
  tmpfilesEntries = lib.filterAttrs (name: svc: (resolveUser name svc) != null || (resolveGroup name svc) != null) cfg.persistentServices;
in {
  imports = [
    inputs.impermanence.nixosModules.impermanence
  ]; # imports

  options.impermanence = {
    enable = lib.mkEnableOption "Btrfs rollback and impermanence";
    device = lib.mkOption {
      type = lib.types.str;
      default = "cryptroot";
      description = "The name of the decrypted LUKS device containing the Btrfs root.";
    }; # device
    directories = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [];
      description = "Additional directories to persist.";
    }; # directories
    files = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [];
      description = "Additional files to persist.";
    }; # files
    persistentServices = lib.mkOption {
      type = lib.types.attrsOf persistentServiceType;
      default = {};
      description = "Declarative persistent service state directories with optional static user provisioning and impermanence mount ordering.";
    };
  }; # options.impermanence

  config = lib.mkMerge [
    {
      users.users = lib.mkMerge (lib.mapAttrsToList (name: svc: let
          u = resolveUser name svc;
          g = resolveGroup name svc;
        in {
          ${u} = {
            isSystemUser = true;
            group = g;
            home = svc.directory;
            inherit (svc) description;
          };
        })
        createdUserEntries);

      users.groups = lib.mkMerge (lib.mapAttrsToList (name: svc: {
          ${resolveGroup name svc} = {};
        })
        createdUserEntries);

      systemd.services = lib.mkMerge (lib.mapAttrsToList (name: svc: let
          u = resolveUser name svc;
          g = resolveGroup name svc;
        in {
          ${svc.service}.serviceConfig = {
            DynamicUser = lib.mkForce false;
            PrivateUsers = lib.mkForce false;
            User = u;
            Group = g;
          };
        })
        createdUserEntries);

      systemd.tmpfiles.rules = lib.mapAttrsToList (name: svc: let
        resolvedUser = resolveUser name svc;
        resolvedGroup = resolveGroup name svc;
        u =
          if resolvedUser != null
          then resolvedUser
          else "-";
        g =
          if resolvedGroup != null
          then resolvedGroup
          else "-";
      in "d ${escapeTmpfilesPath svc.directory} ${svc.mode} ${u} ${g} -")
      tmpfilesEntries;
    }

    (lib.mkIf cfg.enable {
      boot = {
        initrd = {
          systemd = {
            packages = with pkgs; [coreutils util-linux btrfs-progs];
            services.rollback = {
              description = "Rollback BTRFS root subvolume to a pristine state";
              wantedBy = ["initrd-root-device.target"];
              after = ["cryptsetup.target"];
              before = ["sysroot.mount"];
              unitConfig.DefaultDependencies = "no";
              serviceConfig.Type = "oneshot";
              script = ''
                set -euo pipefail
                mkdir -p /mnt
                mount -t btrfs -o subvol=/ /dev/mapper/${cfg.device} /mnt

                # Delete the old root subvolume
                if [[ -e /mnt/@ ]]; then
                    btrfs subvolume delete --recursive /mnt/@
                fi

                if [[ -e /mnt/@-blank ]]; then
                    # Create a writable snapshot from the "gold image"
                    btrfs subvolume snapshot /mnt/@-blank /mnt/@
                else
                    # Bootstrap: Create fresh root, set up mountpoints, then save as "gold image"
                    btrfs subvolume create /mnt/@
                    mkdir -p /mnt/@/home
                    mkdir -p /mnt/@/nix
                    mkdir -p /mnt/@/persist
                    mkdir -p /mnt/@/var/log
                    mkdir -p /mnt/@/.snapshots

                    # Create the read-only snapshot for future boots
                    btrfs subvolume snapshot -r /mnt/@ /mnt/@-blank
                fi

                umount /mnt
              '';
            }; # services.rollback
          }; # systemd
          supportedFilesystems = ["btrfs"];
          kernelModules = ["btrfs"];
        }; # initrd
      }; # boot

      fileSystems = {
        "/persist".neededForBoot = true;
      }; # fileSystems

      environment.persistence."/persist" = {
        hideMounts = true;
        directories = baseDirs ++ cfg.directories ++ persistentServiceDirs; # directories
        files =
          [
            "/etc/machine-id"
            "/etc/ssh/ssh_host_ed25519_key"
            "/etc/ssh/ssh_host_ed25519_key.pub"
          ]
          ++ cfg.files; # files
      }; # environment.persistence."/persist"

      systemd.services = lib.mkMerge (
        lib.mapAttrsToList (
          _: svc: let
            mountUnit = "${utils.escapeSystemdPath (normalizeDir svc.directory)}.mount";
            targets = [svc.service] ++ svc.extraServices;
          in
            lib.genAttrs targets (_: {
              after = [mountUnit];
              requires = [mountUnit];
            })
        )
        cfg.persistentServices
      );
    })
  ]; # config
}
