# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  storageKeyPath = "/persist/secrets/storage-luks.key";

  # Hardware IDs
  storageDiskPart = "/dev/disk/by-id/ata-ST24000DM001-3Y7103_ZXA110H0-part1";
  cacheDisk1Part = "/dev/disk/by-id/ata-OCZ-VERTEX3_OCZ-14MF66108QE3EV6L-part1";
  cacheDisk2Part = "/dev/disk/by-id/ata-OCZ-VERTEX3_OCZ-3PMYU9GID47407M1-part1";

  btrfsCacheOpts = [
    "defaults"
    "ssd"
    "discard=async"
    "relatime"
    "space_cache=v2"
    "autodefrag"
    "commit=120"
    "compress=zstd"
    "nofail"
    "x-systemd.device-timeout=10s"
    "x-systemd.requires=dev-mapper-cryptcache1.device"
    "x-systemd.requires=dev-mapper-cryptcache2.device"
    "x-systemd.after=dev-mapper-cryptcache1.device"
    "x-systemd.after=dev-mapper-cryptcache2.device"
  ];

  btrfsDiskOpts = [
    "subvol=@"
    "defaults"
    "relatime"
    "space_cache=v2"
    "autodefrag"
    "commit=120"
    "compress=zstd"
    "nofail"
    "x-systemd.device-timeout=10s"
    "x-systemd.requires=dev-mapper-cryptdisk1.device"
    "x-systemd.after=dev-mapper-cryptdisk1.device"
  ];
in {
  environment.systemPackages = with pkgs; [
    mergerfs
    mergerfs-tools
    rsync
  ];

  # Allow non-root users (like Samba) to access FUSE mounts using allow_other
  programs.fuse.userAllowOther = true;

  # Decrypt persistent data and cache disks in Stage 2 using keyfile on /persist
  environment.etc.crypttab.text = ''
    cryptdisk1   ${storageDiskPart} ${storageKeyPath}
    cryptcache1  ${cacheDisk1Part}  ${storageKeyPath}
    cryptcache2  ${cacheDisk2Part}  ${storageKeyPath}
  '';

  # Filesystem mounts
  fileSystems = {
    # 24TB Seagate HDD (Backing Bulk Storage Disk 1)
    "/mnt/disk1" = {
      device = "/dev/mapper/cryptdisk1";
      fsType = "btrfs";
      options = btrfsDiskOpts;
    };

    # 2x 120GB SSDs (Btrfs RAID 1 Cache Pool)
    "/mnt/cache" = {
      device = "/dev/disk/by-label/CACHE";
      fsType = "btrfs";
      options = btrfsCacheOpts;
    };

    # Unified Tiered Storage via MergerFS
    # Writes land on /mnt/cache/data first (category.create=ff)
    # Reads search /mnt/cache/data then /mnt/disk1
    "/storage" = {
      fsType = "fuse.mergerfs";
      device = "/mnt/cache/data:/mnt/disk1";
      depends = [
        "/mnt/cache"
        "/mnt/disk1"
      ];
      options = [
        "defaults"
        "allow_other"
        "use_ino"
        "category.create=ff"
        "minfreespace=15G"
        "moveonenospc=true"
        "nofail"
        "cache.files=partial"
        "dropcacheonclose=true"
      ];
    };
  };

  # Ensure directories exist on cache and backing disk
  systemd.tmpfiles.rules = [
    "d /mnt/cache/data 0775 root users -"
    "d /mnt/cache/appdata 0775 root users -"
    "d /mnt/disk1/public 0775 nobody users -"
    "d /mnt/disk1/media 0775 root users -"
    "d /mnt/disk1/users 0755 root root -"
    "d /mnt/disk1/users/joel 0700 joel users -"
    "d /mnt/disk1/users/katy 0700 katy users -"
  ];

  # Monthly scrub for root, cache, and bulk storage disks
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [
      "/"
      "/mnt/cache"
      "/mnt/disk1"
    ];
  };

  # Intelligent Cache Mover: Migrates cold files from /mnt/cache/data to /mnt/disk1
  # only when cache usage exceeds threshold (e.g., 75%).
  # Leaves /mnt/cache/appdata completely untouched.
  systemd.services.mergerfs-mover = {
    description = "Intelligently evict cold cached files from SSD cache to 24TB bulk storage";
    path = with pkgs; [
      coreutils
      findutils
      rsync
    ];
    script = ''
      set -euo pipefail

      CACHE_SRC="/mnt/cache/data"
      STORAGE_DST="/mnt/disk1"
      HIGH_WATERMARK=75
      MIN_AGE_DAYS=14

      if [ ! -d "$CACHE_SRC" ] || [ ! -d "$STORAGE_DST" ]; then
        echo "Source or destination directory does not exist. Skipping."
        exit 0
      fi

      USAGE=$(df --output=pcent "$CACHE_SRC" | tail -1 | tr -dc '0-9')
      echo "Current cache usage: ''${USAGE}% (Threshold: ''${HIGH_WATERMARK}%)"

      if [ "$USAGE" -lt "$HIGH_WATERMARK" ]; then
        echo "Cache usage is below ''${HIGH_WATERMARK}%. Keeping files on SSD cache for silent/fast reads."
        exit 0
      fi

      echo "Cache threshold reached! Evicting cold files older than ''${MIN_AGE_DAYS} days..."

      find "$CACHE_SRC" -type f -atime +"$MIN_AGE_DAYS" ! -name "*.part" | while IFS= read -r file; do
        relpath="''${file#$CACHE_SRC/}"
        target_dir="$STORAGE_DST/$(dirname "$relpath")"
        mkdir -p "$target_dir"
        echo "Evicting cold file: $relpath -> $target_dir/"
        rsync -aHAX --remove-source-files "$file" "$target_dir/"
      done

      # Clean up empty directories in cache
      find "$CACHE_SRC" -mindepth 1 -type d -empty -delete

      echo "MergerFS cache mover finished successfully."
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
  };

  systemd.timers.mergerfs-mover = {
    description = "Nightly check for MergerFS cache threshold eviction";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
    };
  };
}
