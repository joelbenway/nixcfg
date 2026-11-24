---
type: architecture
title: "Architecture: Fleet Overview & Design Ethos"
description: "Comprehensive fleet topology, corporate e-waste salvage philosophy, listener-gifted hardware, Catholic saint naming motifs, and distributed Nix compilation."
status: active
trust: verified
owner: joel
timestamp: "2026-11-24"
tags:
  - architecture
  - fleet
  - homelab
  - linux-unplugged
  - distributed-builds
---

# Fleet Overview & Design Ethos ⛪❄️

The **NixCFG Homelab Fleet** is built on a simple yet radical proposition: **enterprise corporate e-waste is not obsolete—it is high-performance silicon waiting for a proper operating system.**

Instead of spending thousands of dollars on disposable, locked-down consumer gadgets, this homelab rescues discarded enterprise relics, upgrades their memory and displays, and orchestrates them into a unified, resilient, declarative infrastructure running NixOS.

---

## Fleet Topology & Role Matrix

```
                          [ Internet / Public Fiber ]
                                      |
                           +----------------------+
                           |  michael (HP Slim)   |  <-- Core Router & Firewall
                           |  i3-12100, 2.5GbE    |      CAKE SQM, VLANs, DNS
                           +----------------------+
                                      |
                     [ 802.1Q 2.5GbE Managed Trunk ]
                                      |
        +-----------------------------+-----------------------------+
        |                                                           |
 [ VLAN 77: Skylab ]                                         [ Tailscale Mesh ]
        |                                                           |
        +---> zita (HP z620 Server)                                 |
        |     Dual Xeon E5-2667v2 (32T), 128GB ECC, 24TB + SSD      +--- (All Hosts)
        |     Jellyfin, Forgejo, Vaultwarden, Beszel, ntfy, Hermes  |
        |                                                           |
        +---> francis (HP ProDesk 600 G4 Mini) <--------------------+
        |     i5-8500T, 32GB RAM, 1TB NVMe                          |
        |     *Gifted by a LINUX Unplugged Listener!*               |
        |                                                           |
        +---> jerome (Dell Latitude E7470)                          |
        |     i7-6650U Iris, 32GB RAM, FHD IPS, me_cleaned          |
        |                                                           |
        +---> agnes (Dell Latitude E7270)                           |
              i7-6600U, 32GB RAM, FHD IPS, E-Port Docking           |
```

| Host | Hardware Platform | Primary Role | Memory & CPU | Special Highlight |
| :--- | :--- | :--- | :--- | :--- |
| **`michael`** | HP Slim Desktop S01 | Perimeter Router / Firewall | 16 GB, i3-12100 (4C/8T) | Dual 2.5GbE, CAKE SQM, initrd remote unlock |
| **`zita`** | HP z620 Workstation | Storage, Media, Homelab Server | 128 GB ECC, Dual Xeon (16C/32T) | 24TB Tiered MergerFS, Quadro NVENC, Nix Cache |
| **`francis`** | HP ProDesk 600 G4 Mini | Dedicated Workstation | 32 GB, i5-8500T (6C/6T) | **Gifted by a LINUX Unplugged listener!** |
| **`jerome`** | Dell Latitude E7470 | Daily Driver Ultraportable | 32 GB, i7-6650U Iris (2C/4T) | ME-cleaned firmware, E-Port dock, 1080p IPS |
| **`agnes`** | Dell Latitude E7270 | Compact Mobile Field Unit | 32 GB, i7-6600U (2C/4T) | Tri-metal MIL-STD 810G chassis, 1080p IPS |
| **`therese`** | Ephemeral USB/ISO | Zero-Trust Bootstrap Installer| Runs in RAM (Minimal) | Containerized build, scoped Tailscale bootstrap |

---

## Naming Philosophy: Catholic Saints

Every node in the fleet is named after a Catholic Saint whose life story and spiritual patronage directly mirrors the technical role of the host:

* **Michael**: *St. Michael the Archangel*, prince of the heavenly host and defender against evil forces. He guards the network gate as the perimeter firewall and router.
* **Zita**: *St. Zita*, patron saint of domestic servants, known for holding household keys. She works in the basement managing the family's media, data storage, and finances.
* **Francis**: *St. Francis of Assisi*, patron saint of humility and the poor, who begged for discarded stones to rebuild ruined chapels. This hardware was salvaged and given second life through the generosity of a community listener.
* **Jerome**: *St. Jerome*, Doctor of the Church who spent decades painstakingly translating the scriptures into Latin. He acts as the daily driver translation and development engine.
* **Agnes**: *St. Agnes*, martyred at age 12, reflecting the ultra-compact 12.5" form factor of the Dell Latitude E7270.
* **Therese**: *St. Therese of Lisieux*, patron saint of missionaries, known for her "Little Way" of quiet humility. She is a tiny, humble boot image that quietly deploys massive systems without fanfare.

---

## Distributed Compilation Infrastructure

Compiling large packages or kernel builds on 15W dual-core laptops (`agnes` and `jerome`) would take hours and drain batteries. To solve this, the fleet implements transparent **Distributed Nix Compilation** via [`modules/distributed-builds.nix`](../../modules/distributed-builds.nix):

1. **Remote Builders Registry**: Workstations and laptops (`francis`, `agnes`, `jerome`) distribute builds over Tailscale `ssh-ng` to both always-on servers declared in [`data/builders.nix`](../../data/builders.nix):
   * **`michael`** (`i3-12100`, Alder Lake): `maxJobs = 8`, `speedFactor = 4` (high single-thread IPC)
   * **`zita`** (Dual Xeon E5-2667 v2, Ivy Bridge): `maxJobs = 16`, `speedFactor = 3` (massive parallel throughput)
2. **Cryptographic Binary Cache**: `zita` runs a local [Harmonia](../../modules/binary-cache.nix) (`services.harmonia.cache`) binary cache server. Any package compiled once on `zita` is signed with an ed25519 key and served to `michael`, `francis`, `jerome`, and `agnes` over LAN/Tailscale.

---

## Automated Updates & Fleet Notification Bus

The entire fleet runs an automated, canary-verified update schedule ([`modules/auto-update.nix`](../../modules/auto-update.nix)) wired into a unified, desktop-agnostic notification bus ([`modules/notify.nix`](../../modules/notify.nix)):
* **Non-Interactive Updates**: Flakes are updated and system closures built during the early morning hours with randomized jitter, automatic post-boot canary verification (`boot-verify`), and unattended rollback on server failures.
* **Self-Hosted `ntfy` Bus on `zita`**: `auto-update`, `smartd` drive alerts, Beszel telemetry alerts, and systemd `OnFailure=` crashes all publish to `https://notify.benway.me` (`fleet-alerts` & `fleet-updates`) for instant push delivery to Android and desktop sessions.
* **Desktop-Owned Subscribers**: `modules/notify.nix` has zero desktop coupling. KDE Plasma workstations (`francis`, `jerome`, `agnes`) stream alerts to native desktop notifications via `fleet-notify-desktop` wired strictly inside [`modules/plasma.nix`](../../modules/plasma.nix), keeping workstations ready to switch desktop environments cleanly.

---

## Related Documents
* [Storage Architecture & Tiering](./storage-tiering.md)
* [Network Routing & Perimeter Defense](./network-routing.md)
* [Security, Cryptography & Bootstrapping](./security-model.md)
* [Hermes Autonomous Agent & Signal Gateway](./hermes-agent.md)
* [Fleet Notification Bus (ntfy + Desktop Subscribers)](../howto/fleet-notify.md)
* [Host Profile: francis](../hosts/francis.md)
