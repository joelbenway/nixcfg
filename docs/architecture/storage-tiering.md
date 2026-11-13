---
type: architecture
title: "Architecture: Tiered Storage & Intelligent Cache Eviction"
description: "Detailed architecture of zita's storage subsystem: 24TB bulk storage, Btrfs RAID-1 SSD cache, FUSE MergerFS, and high-watermark automated mover."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - architecture
  - storage
  - mergerfs
  - btrfs
  - ssd-cache
---

# Tiered Storage & Intelligent Cache Eviction 🗄️⚡

The storage subsystem on `zita` delivers the speed and quiet operation of an all-flash array for everyday workloads, combined with the massive density of enterprise mechanical drives, without running noisy platters 24/7 or spending fortune on enterprise SSDs.

---

## Architectural Components

```
                                  [ Client Access ]
                          (Samba, Copyparty, Jellyfin, CLI)
                                          |
                                          v
                               [/storage - FUSE MergerFS]
                                          |
                    +---------------------+---------------------+
                    |                                           |
      Writes & Active Working Set                       Bulk Archive & Reads
                    |                                           |
                    v                                           v
         [/mnt/cache - Btrfs RAID-1]                  [/mnt/disk1 - Btrfs Single]
         2x 120GB OCZ Vertex 3 SSDs                   1x 24TB Seagate Enterprise HDD
         (/mnt/cache/data + /appdata)                 (/public, /media, /users)
                    |                                           ^
                    |                                           |
                    +=== mergerfs-mover (Nightly at 75% cap) ===+
```

### 1. The Bulk Storage Layer (`/mnt/disk1`)
* **Drive**: 1x 24 TB Seagate Enterprise SATA HDD (`ST24000DM001`).
* **Filesystem**: Btrfs with `compress=zstd`, `relatime`, `space_cache=v2`, and `commit=120`.
* **Role**: High-density repository for 4K video libraries, system backups, and cold archives.

### 2. The SSD Cache Layer (`/mnt/cache`)
* **Drives**: 2x 120 GB OCZ Vertex 3 SATA SSDs configured in a hardware-independent Btrfs RAID-1 mirror.
* **Filesystem**: Btrfs with `ssd`, `discard=async`, `compress=zstd`, `commit=120`.
* **Two Root Directories**:
  * `/mnt/cache/data`: Dynamic write buffer for network shares and torrents/downloads.
  * `/mnt/cache/appdata`: Pinned high-IOPS storage for application databases (Actual Budget SQLite, Jellyfin transcode cache/metadata). **Never evicted to mechanical disk.**

### 3. The Unified Pool (`/storage`)
* **FUSE Filesystem**: [MergerFS](https://github.com/trapexit/mergerfs) pools `/mnt/cache/data` and `/mnt/disk1` under a single unified mount point.
* **Create Policy (`category.create=ff`)**: New files and directories are always created on the first available branch in the list: the SSD cache pool (`/mnt/cache/data`).
* **Fallback & Free Space**: `minfreespace=15G` and `moveonenospc=true` ensure that if the cache fills completely during an unexpectedly massive file transfer, MergerFS automatically overflows writes directly to the 24TB drive without returning `ENOSPC` errors to clients.

---

## Intelligent Cache Eviction (`mergerfs-mover`)

Traditional unRAID or ZFS cache systems either keep everything in RAM or trigger mindless daily transfers that spin up mechanical drives every single night, regardless of how much space remains.

`zita` replaces this with a smart, threshold-driven systemd service and timer ([`hosts/zita/storage.nix`](../../hosts/zita/storage.nix)):

```bash
HIGH_WATERMARK=75    # Trigger eviction only if SSD cache exceeds 75% capacity
MIN_AGE_DAYS=14      # Only evict files whose access time (atime) is older than 2 weeks
```

### Eviction Logic Flow

1. Every morning at 03:00, `mergerfs-mover.timer` executes `mergerfs-mover.service`.
2. The service checks cache disk utilization via `df`.
3. **Below 75%**: The service exits immediately. Active files remain on high-speed solid-state storage. Mechanical drives remain spun down and silent, saving power and eliminating acoustic chatter.
4. **Above 75%**: The service initiates a targeted sweep:
   * Finds regular files older than 14 days (`-atime +14`).
   * Excludes in-progress downloads (`! -name "*.part"`).
   * Moves cold files atomically to the 24TB drive using `rsync -aHAX --remove-source-files`.
   * Prunes empty parent directory trees on the cache.
   * Completely ignores `/mnt/cache/appdata`, preserving database latency.

---

## Data Integrity & Maintenance

* **Automated SMART Drive Health Monitoring (`smartd`)**: Fleet-wide daemon via [`modules/smartd.nix`](../../modules/smartd.nix) continuously monitoring ATA and NVMe storage devices. Schedules daily short self-tests (`02:00`), weekly long self-tests (`Sundays 04:00`), monitors temperature thresholds (warns at 55°C, critical at 65°C), respects disk spindown with `-n standby,q`, broadcasts terminal warnings via `wall`, and provides the [`disk-health`](../../pkgs/disk-health/disk-health.sh) CLI inspection utility.
* **Monthly Automated Scrub**: Configured via `services.btrfs.autoScrub`, verifying checksums across root, the cache pool, and the 24TB bulk drive on a monthly cadence.
* **Instant Decryption via Persistent Keyfile**: Storage disks are encrypted with LUKS2 and decrypted during Stage 2 system initialization using a keyfile safely stored on `/persist/secrets/storage-luks.key`.

---

## Related Documents
* [Host Profile: zita](../hosts/zita.md)
* [ADR 0002: MergerFS Tiered Storage over Traditional ZFS](../decisions/0002-mergerfs-over-zfs-for-bulk-storage.md)
* [Security, Cryptography & Bootstrapping](./security-model.md)
