---
okf_version: "0.2"
type: index
title: "NixCFG Knowledge Base & Architecture Documentation"
description: "Open Knowledge Format (OKF) index for Joel's NixOS homelab fleet, host specifications, storage architecture, security model, and operations."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - nixos
  - homelab
  - linux-unplugged
  - okf
  - architecture
---

# NixCFG Knowledge Base (OKF)

Welcome to the structured Open Knowledge Format (OKF) documentation for **Joel's NixOS Homelab & Fleet Configuration**. 

This documentation provides deep technical architecture, hardware specifications, operational how-to guides, and Architectural Decision Records (ADRs) for the entire fleet—celebrating the resurrection of corporate e-waste and the generosity of the **LINUX Unplugged** community.

---

## Architecture & Concepts

High-level architecture specifications detailing how the fleet functions as an integrated, self-healing system:

* [Fleet Overview & Ethos](./architecture/fleet-overview.md) (`type: architecture`): Fleet topology, naming philosophy (Catholic Saints), enterprise relic salvation, the listener-gifted `francis`, and distributed Nix builds.
* [Storage Architecture & Tiering](./architecture/storage-tiering.md) (`type: architecture`): Tiered storage on `zita` combining a 24TB Seagate HDD and a Btrfs RAID-1 SSD cache pool using MergerFS with automated cold-data migration (`mergerfs-mover`).
* [Network Routing & Perimeter Defense](./architecture/network-routing.md) (`type: architecture`): `michael` core router architecture, dual 2.5GbE interfaces, 802.1Q trunking, VLAN isolation (Skylab, Skynet, IoT, Mgmt, OOB rescue), CAKE SQM, and Pi-hole integration.
* [Security, Cryptography & Bootstrapping](./architecture/security-model.md) (`type: architecture`): Zero-trust bootstrap model, ephemeral root wipe via Impermanence, Lanzaboote UEFI Secure Boot, TPM2 auto-enrollment, and Agenix secret lifecycles.
* [Agentic AI Development Environment](./architecture/ai-development.md) (`type: architecture`): Antigravity IDE, `agy` CLI, OpenCode, Model Context Protocol (MCP) servers, and secure session key injection via `loadkeys`.
* [Hermes Autonomous Agent & Signal Gateway](./architecture/hermes-agent.md) (`type: architecture`): Autonomous systems agent on `zita` with a Signal messenger bridge, privilege-separated Agentic GitOps self-provisioning, and zero-cost model routing.

---

## Host Concepts & Hardware Profiles

Deep dives into the individual machines comprising the homelab:

* [francis](./hosts/francis.md) (`type: concept`): HP ProDesk 600 G4 Desktop Mini (i5-8500T, 32GB RAM, 1TB NVMe)—generously gifted by a LINUX Unplugged listener and reborn as a silent desktop powerhouse.
* [zita](./hosts/zita.md) (`type: concept`): HP z620 workstation (dual 8-core Xeon E5-2667v2, 128GB ECC RAM, Quadro M2000)—the heavy lifter running 24TB tiered storage, Jellyfin NVENC, Actual Budget + Plaid sync, Samba, Copyparty, Hermes Signal bot, and local binary cache.
* [michael](./hosts/michael.md) (`type: concept`): HP Slim desktop (i3-12100, dual 2.5GbE NIC)—the perimeter gatekeeper, VLAN router, CAKE traffic shaper, and dropbear initrd remote LUKS unlocker.
* [agnes & jerome](./hosts/agnes-and-jerome.md) (`type: concept`): Dell Latitude E7270 & E7470 laptops—MIL-STD 810G Tri-metal chassis, E-Port docking stations, 32GB RAM upgrades, FHD IPS panels, and ME-cleaned daily drivers.
* [therese](./hosts/therese.md) (`type: concept`): Minimalist, zero-trust bootstrap installer ISO built inside a container, joining Tailnet as an ephemeral bootstrap node for unattended `nixos-anywhere` deployments.

---

## Operational How-To Guides

Action-oriented runbooks for operating and deploying hosts:

* [How to Bootstrap a New Host](./howto/bootstrap-new-host.md) (`type: howto`): End-to-end walkthrough for building the `therese` ISO, booting bare metal, and deploying remotely via `install_host`.
* [TPM2 Enrollment & Re-enrollment](./howto/tpm-enrollment.md) (`type: howto`): Automating LUKS enrollment against hardware PCRs, inspecting tokens, and using the `tpm-reenroll` CLI.
* [Remote LUKS Unlocking over SSH](./howto/remote-luks-unlock.md) (`type: howto`): Remotely unlocking `michael` during initrd boot over an encrypted SSH connection.

---

## Architectural Decision Records (ADRs)

Formal design choices, trade-offs, and historical context:

* [ADR 0001: Impermanence with Root-on-Tmpfs/Btrfs](./decisions/0001-impermanence-and-btrfs.md) (`type: decision`): Rationale for wiping the root filesystem on every reboot while persisting state to `/persist`.
* [ADR 0002: MergerFS Tiered Storage over Traditional ZFS](./decisions/0002-mergerfs-over-zfs-for-bulk-storage.md) (`type: decision`): Trade-off analysis choosing MergerFS + Btrfs cache pool over ZFS vdevs for energy efficiency and flexible drive additions.
* [ADR 0003: Zero-Trust Ephemeral Bootstrap via Therese](./decisions/0003-zero-trust-therese-bootstrap.md) (`type: decision`): Security decision to isolate installer media with scoped Tailscale OAuth rather than baking master encryption keys into flash drives.
