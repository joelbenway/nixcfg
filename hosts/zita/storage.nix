# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  disks ? ["/dev/sdb"],
  passwordFile ? "/tmp/storage-secret.key",
  keyFile ? "/persist/secrets/storage-luks.key",
  ...
}: let
  btrfsOpts = [
    "defaults"
    "noatime"
    "space_cache=v2"
    "autodefrag"
    "commit=120"
    "compress=zstd"
    "nofail"
    "x-systemd.device-timeout=10s"
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
                initrdUnlock = false;
                settings = {
                  allowDiscards = true;
                  keyFile = keyFile;
                };
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
