---
type: architecture
title: "Architecture: Fleet Overview & Design Ethos"
description: "Comprehensive fleet topology, corporate e-waste salvage philosophy, listener-gifted hardware, Catholic saint naming motifs, and distributed Nix compilation."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
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
        |     Jellyfin NVENC, Samba, Actual, Nix Binary Cache       |
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

1. **Remote Builders Registry**: Laptops and smaller workstations register `zita` as an authorized builder in `/etc/nix/machines`:
   ```nix
   nix.buildMachines = [
     {
       hostName = "zita";
       system = "x86_64-linux";
       maxJobs = 16;
       speedFactor = 4;
       supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
     }
   ];
   ```
2. **Cryptographic Binary Cache**: `zita` runs a local [`binary-cache`](../../modules/binary-cache.nix) server (`nix-serve`). Any package compiled once on `zita` is immediately signed with an ed25519 key and shared to `francis`, `jerome`, and `agnes` over the local 2.5GbE network at full line rate.

---

## Automated Updates & Fleet Maintenance

The entire fleet runs an automated, non-disruptive update schedule ([`modules/auto-update.nix`](../../modules/auto-update.nix)):
* **Non-Interactive Updates**: Flakes are updated and system closures built during the early morning hours with randomized jitter.
* **Plasma Desktop Notifications**: On workstations (`francis`, `jerome`, `agnes`), user-space updates apply live, while kernel updates trigger a gentle desktop notification in KDE Plasma indicating that a reboot is ready whenever convenient.

---

## Related Documents
* [Storage Architecture & Tiering](./storage-tiering.md)
* [Network Routing & Perimeter Defense](./network-routing.md)
* [Security, Cryptography & Bootstrapping](./security-model.md)
* [Host Profile: francis](../hosts/francis.md)
