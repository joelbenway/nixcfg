---
type: decision
title: "ADR 0001: Impermanence with Ephemeral Root and Btrfs Subvolumes"
description: "Architectural Decision Record choosing ephemeral root filesystem wiping on every boot with explicit /persist retention via Impermanence."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - adr
  - decision
  - impermanence
  - btrfs
  - architecture
---

# ADR 0001: Impermanence with Ephemeral Root and Btrfs Subvolumes

## Context
Traditional operating system installations accumulate configuration drift, cache bloat, stale daemon artifacts, and leftover dependencies over months and years of use. In addition, persistent root filesystems provide an enduring landing zone for security compromises and unauthorized modifications.

We required an architecture that:
1. Enforces strict declarative discipline in NixOS (everything needed must be declared in code).
2. Guarantees that every reboot starts from a pristine, known-good operating state.
3. Isolates stateful data into easily backupable and auditable directories.

## Decision
We adopted the **Impermanence Pattern** across all production hosts (`michael`, `zita`, `francis`, `jerome`, `agnes`):
* Root (`/`) is mounted on an ephemeral Btrfs subvolume (`@root`) or tmpfs that is wiped clean on every system reboot.
* Only explicitly declared state (machine ID, SSH host identities, NetworkManager profiles, user application configs) is linked or bind-mounted from a dedicated persistent Btrfs subvolume (`/persist`).
* User homes use selective persistence: transient cache directories (`~/.cache`, download scratchpads) vanish on reboot, while critical dotfiles and data remain in `/persist/home/`.

## Consequences
### Positive:
* **Absolute Reproducibility**: If a service dependency or system tweak is made outside of NixOS, it will not survive a reboot, immediately highlighting undeclared configuration drift.
* **Hardened Security**: Unauthorized binaries, backdoors, or malicious scripts planted in `/tmp`, `/var`, `/etc`, or `/bin` are eliminated upon restart.
* **Trivial Backups**: Only `/persist` needs to be backed up; the rest of the OS can be regenerated identically from git.

### Trade-offs:
* **Initial Setup Overhead**: Any newly installed daemon that requires persistent storage must have its state directory explicitly added to `impermanence.directories` or `impermanence.files`.
* **State Discovery**: Required inspecting new packages to identify where they store user state (e.g., `/var/lib/private/actual`).
