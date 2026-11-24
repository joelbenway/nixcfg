---
type: concept
title: "Host Profile: zita (HP z620 Workstation & Storage Server)"
description: "Homelab server profile for zita, an HP z620 dual Xeon workstation running 24TB tiered storage, Jellyfin, Actual Budget, Samba, Copyparty, Forgejo, Vaultwarden, Beszel Hub, ntfy, Hermes, and Harmonia binary cache."
status: active
trust: verified
owner: joel
timestamp: "2026-11-24"
tags:
  - host
  - server
  - storage
  - z620
  - xeon
  - hardware
---

# zita: The Domestic Servant & Media Monolith 🗝️

> *"St. Zita is the patron saint of domestic servants and homemakers, almost always depicted carrying a ring of household keys. Zita quietly tends to the house, serving files, media, finances, and keeping the family's digital home running smoothly."*

`zita` is an **HP z620 Workstation**. Originally built around 2012 to drive massive video wall installations in Chicago, this dual-socket workstation was decommissioned and destined for scrap. After its specialized broadcast capture cards were sold off, the machine became better than free.

Today, `zita` lives in the basement where it acts as the central storage appliance, application server, and winter heater for the homelab.

---

## Hardware Specifications

| Component | Specification | Notes |
| :--- | :--- | :--- |
| **Chassis** | HP z620 Mid-Tower Tool-less Chassis | Heavy-gauge steel, dual-redundant fan channels, tool-less bays |
| **Processors** | Dual Intel Xeon E5-2667 v2 (Ivy Bridge-EP) | **16 Cores, 32 Threads** total @ 3.30 GHz base / 4.00 GHz turbo |
| **Memory** | 128 GB DDR3-1866 ECC Registered | Quad-channel per CPU, massive cache buffer for ZFS/Btrfs |
| **Graphics** | NVIDIA Quadro M2000 (4GB GDDR5) | GM206 (Maxwell 2nd Gen) with dedicated NVENC hardware transcoding |
| **Bulk Storage** | 1x 24 TB Seagate Enterprise HDD (`ST24000DM001`) | High-density bulk mechanical storage formatted Btrfs |
| **Cache Storage** | 2x 120 GB OCZ Vertex 3 SATA SSDs | Btrfs RAID-1 mirrored write/read cache pool (`/mnt/cache`) |
| **Unified Storage** | FUSE MergerFS Pool (`/storage`) | Combines `/mnt/cache/data` and `/mnt/disk1` with SSD write caching |
| **OS Drive** | Encrypted NVMe / SATA Boot SSD | LUKS2 + Btrfs with Impermanence root wiping |
| **Networking** | Dual Intel 82579LM / 82574L Gigabit Ethernet | Connected to Skylab (trusted VLAN) and Tailscale mesh |
| **Security Hardware** | Discrete TPM 1.2 & Legacy Secure Boot | Hardware crypto key storage |

---

## Storage Architecture Overview

`zita` utilizes a custom **Tiered Hybrid Storage Architecture**:

```
                       /storage (FUSE MergerFS)
                      /                         \
      Writes land here (category.create=ff)       Fallback / Bulk Reads
                    /                             \
        /mnt/cache/data (Btrfs RAID-1)         /mnt/disk1 (Btrfs Single)
        2x 120GB OCZ Vertex 3 SSDs             1x 24TB Seagate HDD
                    |                                     ^
                    |==== Intelligent Eviction ===========|
                         (mergerfs-mover nightly at 75%)
```

1. **Fast Writes**: Inbound files land directly on the SSD cache pool, delivering silent, line-rate gigabit writes without spinning up mechanical platters.
2. **Cold Data Migration**: A custom systemd service ([`mergerfs-mover`](../architecture/storage-tiering.md)) checks cache usage nightly. If cache exceeds **75% utilization**, files older than 14 days are atomically migrated to the 24TB mechanical disk via `rsync`.
3. **Appdata Protection**: High-frequency database files (Jellyfin metadata, Actual Budget SQLite) reside permanently in `/mnt/cache/appdata` and are never evicted to the mechanical drive.

---

## Hosted Services

`zita` runs a comprehensive suite of declarative homelab services:

* **[Jellyfin Media Server](../../modules/jellyfin.nix)**: Delivers 4K HDR and 1080p media streaming to televisions and mobile devices. Leverages the NVIDIA Quadro M2000 for hardware-accelerated NVENC video transcoding.
* **[Actual Budget](../../modules/actual.nix)**: Self-hosted zero-knowledge privacy-focused envelope budgeting server.
* **[Samba (SMB/CIFS)](../../modules/samba.nix)**: Declarative, multi-user local network file shares for Windows, Linux, and macOS clients with guest and authenticated access.
* **[Copyparty](../../modules/copyparty.nix)**: Blazing-fast HTTP/WebDAV file server allowing instant upload, streaming, audio player, and file management via any browser without accounts or heavy client software.
* **[Caddy Reverse Proxy](../../hosts/zita/default.nix)**: Handles automated TLS certificate acquisition via Cloudflare DNS-01 API challenges, exposing services securely over local DNS and Tailscale.
* **[Nix Binary Cache (Harmonia)](../../modules/binary-cache.nix)**: Caches compiled Nix store paths locally (`services.harmonia.cache`) and cryptographically signs them with an ed25519 key, dramatically accelerating rebuilds across all laptops and workstations.
* **[Hermes Autonomous Agent](../../modules/hermes.nix)**: Native systemd AI systems engineer bridged to Signal via `signal-cli`, with privilege-separated Agentic GitOps self-provisioning and read-only `beszel-query` fleet telemetry access.
* **[Forgejo Git Forge & Actions Runner](../../modules/forgejo.nix)**: Private, self-hosted software forge (`git.benway.me`) backed by SQLite and a dedicated SSH server on port `2220`. Features built-in CI/CD with `forgejo-runner` leveraging Zita's 32 cores for native Nix builds and Podman container workflows.
* **[Vaultwarden Password Manager](../../modules/vaultwarden.nix)**: Private, Bitwarden-compatible password manager (`vault.benway.me`) backed by SQLite with automated daily persistent backups, WebSocket sync across clients, and Caddy reverse proxy.
* **[Beszel Fleet Telemetry Hub](../../modules/beszel.nix)**: Lightweight PocketBase-backed monitoring hub (`metrics.benway.me`) polling all 5 fleet hosts over Tailscale/LAN SSH for CPU, RAM, thermals, S.M.A.R.T. health, `systemd` service status/logs, laptop battery, and Quadro M2000 GPU utilization—pushing alerts directly to loopback `ntfy`, paired with the read-only `beszel-query` CLI for on-demand Hermes Signal troubleshooting.
* **[`ntfy` Fleet Notification Bus](../../modules/notify.nix)**: Self-hosted `ntfy-sh` broker (`notify.benway.me` + Tailscale `:2587`) with `deny-all` least-privilege tokens (`fleet-pub` write-only, `fleet-sub` read-only, `joel` admin), unifying `auto-update`, `smartd`, Beszel, and systemd `OnFailure=` alerts across Android and desktop sessions.
* **Distributed Nix Builder**: With 32 logical threads and 128GB of RAM, `zita` pairs with `michael` as a remote compilation builder for `agnes`, `jerome`, and `francis`.

---

## Related Documents
* [Storage Architecture & Tiering](../architecture/storage-tiering.md)
* [Hermes Autonomous Agent & Signal Gateway](../architecture/hermes-agent.md)
* [Fleet Notification Bus (ntfy + Desktop Subscribers)](../howto/fleet-notify.md)
* [Beszel Fleet Telemetry & Hermes Setup](../howto/beszel-hermes-prompt.md)
* [Fleet Overview & Ethos](../architecture/fleet-overview.md)
* [ADR 0002: MergerFS Tiered Storage over Traditional ZFS](../decisions/0002-mergerfs-over-zfs-for-bulk-storage.md)
