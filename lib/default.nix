# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{lib, ...}: {
  relativeToRoot = lib.path.append ../.;

  scanFiles = path:
    map (f: (path + "/${f}")) (
      builtins.attrNames (
        lib.attrsets.filterAttrs (
          name: type:
            (type == "regular")
            && (name != "default.nix")
            && (lib.strings.hasSuffix ".nix" name)
        ) (builtins.readDir path)
      )
    );

  # Standard Btrfs-on-LUKS single-disk layout for NixOS fleet
  mkBtrfsLuksDisk = {
    device,
    swapSize ? null,
    passwordFile ? "/tmp/secret.key",
    allowDiscards ? true,
    extraBtrfsOpts ? [],
  }: let
    btrfsOpts =
      [
        "defaults"
        "ssd"
        "discard=async"
        "noatime"
        "space_cache=v2"
        "autodefrag"
        "commit=120"
        "compress=zstd"
      ]
      ++ extraBtrfsOpts;
  in {
    disko.devices = {
      disk = {
        main = {
          inherit device;
          type = "disk";
          content = {
            type = "gpt";
            partitions =
              {
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
              }
              // lib.optionalAttrs (swapSize != null) {
                swap = {
                  size = swapSize;
                  content = {
                    type = "luks";
                    name = "cryptswap";
                    settings.allowDiscards = allowDiscards;
                    inherit passwordFile;
                    content = {
                      type = "swap";
                      extraArgs = ["-L SWAP"];
                    };
                  };
                };
              }
              // {
                root = {
                  size = "100%";
                  content = {
                    type = "luks";
                    name = "cryptroot";
                    settings.allowDiscards = allowDiscards;
                    inherit passwordFile;
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
