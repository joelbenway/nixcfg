{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.impermanence;
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
  }; # options.impermanence

  config = lib.mkIf cfg.enable {
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
      directories =
        [
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
        ]
        ++ cfg.directories; # directories
      files =
        [
          "/etc/machine-id"
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_ed25519_key.pub"
        ]
        ++ cfg.files; # files
    }; # environment.persistence."/persist"
  }; # config
}
