{
  # ls -l /dev/disk/by-id/
  disks ? ["/dev/disk/by-id/nvme-nvme.1c5c-4b4a43424e343030373131363042363056-5348475033312d31303030474d-00000001"],
  swapSize ? "33G",
  ...
}: let
  btrfsOpts = [
    "defaults"
    "ssd"
    "discard=async"
    "noatime"
    "space_cache=v2"
    "autodefrag"
    "commit=120"
    "compress=zstd"
  ];

  passwordFile = "/tmp/secret.key";
in {
  disko.devices = {
    disk = {
      main = {
        device = builtins.elemAt disks 0;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              name = "ESP";
              start = "0%";
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = swapSize;
              content = {
                type = "luks";
                name = "cryptswap";
                settings.allowDiscards = true;
                passwordFile = passwordFile;
                content = {
                  type = "swap";
                  extraArgs = ["-L SWAP"];
                }; # content
              };
            }; # swap
            root = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";
                settings.allowDiscards = true;
                passwordFile = passwordFile;
                content = {
                  type = "btrfs";
                  extraArgs = ["-L ROOT" "-f"];

                  subvolumes = {
                    "@" = {
                      mountpoint = "/";
                      mountOptions = btrfsOpts;
                    };
                    "@home" = {
                      mountpoint = "/home";
                      mountOptions = btrfsOpts;
                    };
                    "@nix" = {
                      mountpoint = "/nix";
                      mountOptions = btrfsOpts;
                    };
                    "@persist" = {
                      mountpoint = "/persist";
                      mountOptions = btrfsOpts;
                    };
                    "@log" = {
                      mountpoint = "/var/log";
                      mountOptions = btrfsOpts;
                    };
                    "@snapshots" = {
                      mountpoint = "/.snapshots";
                      mountOptions = btrfsOpts;
                    };
                  }; # subvolumes
                }; # content
              }; # content
            }; # root
          }; # partitions
        }; # content
      }; # main
    }; # disk
  }; # disko.devices
}
