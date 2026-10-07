# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  disks ? ["/dev/sdb"],
  passwordFile ? "/run/agenix/storage-luks-passphrase",
  ...
}: let
  btrfsOpts = [
    "defaults"
    "noatime"
    "space_cache=v2"
    "autodefrag"
    "commit=120"
    "compress=zstd"
  ];
in {
  disko.devices = {
    disk = {
      storage1 = {
        type = "disk";
        device = builtins.elemAt disks 0;
        content = {
          type = "gpt";
          partitions = {
            storage = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptstorage";
                settings.allowDiscards = true;
                passwordFile = passwordFile;
                content = {
                  type = "btrfs";
                  extraArgs = ["-L STORAGE" "-f"];
                  subvolumes = {
                    "@storage" = {
                      mountpoint = "/storage";
                      mountOptions = btrfsOpts;
                    };
                    "@public" = {
                      mountpoint = "/storage/public";
                      mountOptions = btrfsOpts;
                    };
                    "@media" = {
                      mountpoint = "/storage/media";
                      mountOptions = btrfsOpts;
                    };
                    "@users" = {
                      mountpoint = "/storage/users";
                      mountOptions = btrfsOpts;
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
