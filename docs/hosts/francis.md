---
type: concept
title: "Host Profile: francis (HP ProDesk 600 G4 Desktop Mini)"
description: "Workstation profile for francis, a 1-liter desktop mini gifted by a LINUX Unplugged listener, running NixOS with impermanence, Secure Boot, and TPM2."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - host
  - workstation
  - linux-unplugged
  - community
  - hp
  - hardware
---

# francis: The Listener-Gifted Workstation 🎁

> *"Lord, make me an instrument of your peace... St. Francis begged for discarded stones and used them to rebuild ruined chapels. In that same spirit, we take discarded hardware and make it sing."*

`francis` is an **HP ProDesk 600 G4 Desktop Mini (DM)**. This machine holds a special, cherished place in the homelab: **it was gifted to Joel by a LINUX Unplugged listener—Mike from the [Computer Upcycle Project](https://computerupcycleproject.org/)**, a great organization that provides computers to people in need and installs NixOS on computers in need.

Rescued from corporate obsolescence and brought into the homelab fold, `francis` is now the centerpiece of Joel's primary battlestation, driving an **HP Z32x DreamColor monitor** and an **Audioengine N22 amplifier paired with vintage Koss speakers**. Refurbished, maxed out with 32GB RAM and 1TB high-speed NVMe storage, it serves as a whisper-quiet, ultra-efficient daily workstation.

---

## Hardware Specifications

| Component | Specification | Notes |
| :--- | :--- | :--- |
| **Chassis** | HP ProDesk 600 G4 Desktop Mini (1L) | Compact footprint (~177 x 175 x 34 mm) |
| **Processor** | Intel Core i5-8500T (Coffee Lake) | 6 Cores, 6 Threads @ 2.10 GHz base / 3.50 GHz boost (35W TDP) |
| **Graphics** | Intel UHD Graphics 630 | Dual DisplayPort 1.2 + optional configurable video port |
| **Memory** | 32 GB DDR4-2666 SODIMM | Dual-channel upgrade |
| **Primary Storage** | 1 TB NVMe M.2 SSD | High-speed PCIe Gen 3x4 |
| **Secondary Storage** | 2.5" SATA drive bay available | Unpopulated or auxiliary bulk storage |
| **Networking** | Intel I219-LM Gigabit Ethernet | Low-latency wired connectivity |
| **Cooling & Noise** | Blower fan with copper heatpipe | Virtually silent at idle; low thermal footprint |

---

## Homelab Role & Workload

Within the homelab ecosystem, `francis` serves as a dedicated desktop workstation:
* **Interactive Development**: Serves as a responsive, dedicated workstation for coding, compiling, and testing NixOS configurations without heating up the room or spinning loud fans.
* **Distributed Build Node**: Cooperates with `zita` and the laptops in the fleet via [`distributed-builds.nix`](../architecture/fleet-overview.md#distributed-builds), offloading heavy compilation tasks or contributing local compute.
* **Peripherals & Workstation Audio**: Configured with declarative PipeWire audio stack, Alice75 mechanical keyboard mapping, R1 Pro mouse profiles, and CUPS network printing.
* **Continuous File Synchronization**: Keeps workspace trees, project assets, and documents in sync with other nodes across the Tailnet via `syncthing`.

---

## NixOS Configuration Highlights

`francis` is built on top of the shared [`hosts/common/workstation.nix`](../../hosts/common/workstation.nix) baseline:

1. **Declarative Partitioning ([`disks.nix`](../../hosts/francis/disks.nix))**:
   Partitioned using `disko` with a GPT table containing:
   * `ESP`: 1GB EFI System Partition formatted FAT32 (`/boot`).
   * `cryptroot`: Encrypted LUKS2 volume containing a Btrfs filesystem with subvolumes `@root` (ephemeral), `@home`, `@nix`, and `@persist`.
   * `swap`: Encrypted swap partition for suspend/hibernation support.

2. **Impermanence Architecture**:
   The root filesystem is ephemeral: every boot begins with a blank slate, while critical state (machine ID, SSH host keys, user home state) is retained in `/persist`.

3. **Secure Boot & TPM2 Automation**:
   * **Lanzaboote**: Full UEFI Secure Boot integration signed with custom platform keys.
   * **TPM2 Auto-Unlock**: LUKS volume automatically unseals on boot against system PCRs via [`modules/tpm.nix`](../../modules/tpm.nix), requiring no manual passphrase entry during normal power cycles.

4. **Mesh Networking & Telemetry**:
   Seamlessly integrated into the private Tailscale mesh network with automated OAuth key enrollment and headless remote management.

---

## Community Significance

In many homelabs, hardware is either bought brand-new or scavenged from enterprise scrap yards. `francis` embodies the very best part of the open-source and podcasting community: a listener reaching out to pass along capable silicon so it could live a productive second life running NixOS.

St. Francis of Assisi is remembered for radical humility and rebuilding that which was broken. For this 1-liter desktop mini, running pure declarative NixOS was the ultimate resurrection.

---

## Related Documents
* [Fleet Overview & Ethos](../architecture/fleet-overview.md)
* [How to Bootstrap a New Host](../howto/bootstrap-new-host.md)
* [TPM2 Enrollment & Re-enrollment](../howto/tpm-enrollment.md)
* [ADR 0001: Impermanence with Root-on-Tmpfs/Btrfs](../decisions/0001-impermanence-and-btrfs.md)
