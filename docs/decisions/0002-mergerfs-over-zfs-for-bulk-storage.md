---
type: decision
title: "ADR 0002: MergerFS Tiered Storage over Traditional ZFS Arrays"
description: "Architectural Decision Record choosing MergerFS with Btrfs SSD cache pooling over ZFS vdev pools for home server mass storage."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - adr
  - decision
  - storage
  - mergerfs
  - zfs
  - power-efficiency
---

# ADR 0002: MergerFS Tiered Storage over Traditional ZFS Arrays

## Context
When architecting the bulk storage pool for `zita` (serving 4K media libraries, family shares, and backups), we evaluated traditional enterprise ZFS (RAIDZ1/RAIDZ2) against a modular tiered architecture using MergerFS and Btrfs.

Homelab constraints differed significantly from enterprise data centers:
1. **Power & Acoustic Constraints**: Spinning up a wide array of 6-8 enterprise mechanical drives 24/7 draws substantial idle wattage (40W-80W continuous) and generates noticeable acoustic rumble.
2. **Asymmetric Drive Expansion**: In a homelab, purchasing matched sets of 5-8 identical 20TB+ drives simultaneously is cost-prohibitive. We needed the flexibility to add individual high-capacity drives (e.g., a single 24TB drive) as storage demands expand.
3. **Workload Characteristics**: 95% of reads are sequential media streams, and daily write volume is moderate. High IOPS random I/O is primarily confined to application databases (Actual Budget, Jellyfin metadata).

## Decision
We chose **FUSE MergerFS with a tiered Btrfs SSD cache pool** over a monolithic ZFS RAIDZ array:
* **Write Ingestion**: All writes land on a fast, silent 2x 120GB SSD Btrfs RAID-1 mirror (`/mnt/cache/data`) with zero mechanical spin-up delay.
* **Bulk Storage**: A 24TB Seagate Enterprise mechanical drive (`/mnt/disk1`) stores cold data and media files.
* **Cold Data Eviction**: A custom systemd service (`mergerfs-mover`) monitors the SSD cache. Eviction only triggers if cache usage exceeds 75%, moving files older than 14 days to the mechanical disk.
* **Independent Filesystems**: Each drive remains an independent Btrfs volume. If hardware catastrophic failure occurs, any drive can be plugged into any standard Linux machine and read directly without proprietary array reconstruction.

## Consequences
### Positive:
* **Acoustic & Energy Efficiency**: The mechanical drive remains spun down and silent during typical web browsing, budgeting, and routine file access.
* **Incremental Scalability**: Additional drives of any capacity (e.g., 18TB, 24TB, 30TB) can be appended to the MergerFS mount string instantly without pool re-striping.
* **Crash Resilience**: Because files are stored whole on individual underlying filesystems, a multi-drive catastrophic event only loses data on the physically damaged drive; the rest of the pool remains intact.

### Trade-offs:
* **FUSE Overhead**: File metadata traversal incurs a minor FUSE context-switch overhead compared to in-kernel ZFS, though this is negligible over 1GbE/2.5GbE network links.
* **No Real-Time Striped Parity**: Does not provide instant parity recalculation across drives like RAIDZ; critical data relies on off-site backup and 3-2-1 snapshot strategies.
