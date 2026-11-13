---
type: concept
title: "Host Profile: therese (Zero-Trust Bootstrap Installer ISO)"
description: "Minimalist, zero-trust NixOS installer ISO built in a container, joining Tailscale ephemerally for remote hands-off deployment via nixos-anywhere."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - host
  - installer
  - iso
  - zero-trust
  - tailscale
  - security
---

# therese: The "Little Way" Bootstrap Installer 🕊️

> *"St. Therese of Lisieux is celebrated for her 'Little Way'—achieving extraordinary results through small, humble, and simple acts rather than grand, complicated heroics. In our fleet, Therese is a tiny, humble boot image that makes provisioning complex, hardened systems effortless."*

`therese` is a specialized, zero-trust NixOS installation ISO. It completely solves the infamous **"Chicken-and-Egg" bootstrap paradox** in declarative NixOS deployments: *how do you deploy systems that require encrypted secrets without placing master decryption keys on an unencrypted USB flash drive?*

---

## Architectural Principles

1. **Zero Hardcoded Secrets**: The installer image contains no production LUKS passphrases, no SSH host private keys, and no persistent credentials.
2. **Containerized Build Isolation**: The ISO is generated inside a clean container environment using [`scripts/build_iso`](../../scripts/build_iso), preventing host environment leaks.
3. **Scoped Ephemeral Connectivity**: The image includes only guest Wi-Fi parameters and a scoped Tailscale OAuth client credential tagged exclusively with `tag:bootstrap`.
4. **RAM-Only Key Staging**: Actual LUKS encryption secrets and permanent host keys are injected over an encrypted SSH tunnel from the administrator's workstation directly into target RAM at deploy time.

---

## How the Bootstrap Cycle Works

```
  +-----------------------------------------------------------+
  | 1. Containerized Build                                    |
  |    ./scripts/build_iso builds therese.iso with            |
  |    guest Wi-Fi and scoped tag:bootstrap Tailscale OAuth.  |
  +-----------------------------------------------------------+
                               |
                               v
  +-----------------------------------------------------------+
  | 2. Boot on Target Bare Metal                              |
  |    Target boots from USB, connects to Wi-Fi/Ethernet,     |
  |    and registers as ephemeral node 'therese' on Tailnet.  |
  +-----------------------------------------------------------+
                               |
                               v
  +-----------------------------------------------------------+
  | 3. Remote Provisioning (Operator Workstation)             |
  |    Operator runs: ./scripts/install_host <hostname>       |
  |    - Verifies UEFI Setup Mode (if Lanzaboote enabled)     |
  |    - Unlocks & stages target LUKS secrets in remote RAM   |
  |    - Partitions disks declaratively via Disko             |
  |    - Installs system over SSH via nixos-anywhere          |
  +-----------------------------------------------------------+
                               |
                               v
  +-----------------------------------------------------------+
  | 4. Ephemeral Dissolution                                  |
  |    Target reboots into its permanent encrypted profile.   |
  |    'therese' node vanishes automatically from Tailscale.  |
  +-----------------------------------------------------------+
```

---

## Bundled Tooling

The minimal image closures include diagnostic, partitioning, and crypto utilities:

* **Disko**: Declarative disk layout creation and LUKS volume formatting.
* **Sbctl**: UEFI Secure Boot inspection and platform key enrollment.
* **Agenix / Age**: Cryptographic secret inspection and key validation.
* **Btrfs-progs & Util-Linux**: Filesystem manipulation and disk wipe utilities.
* **Curl, JQ, Rsync**: Remote transfer and API interaction tools.

---

## Related Documents
* [How to Bootstrap a New Host](../howto/bootstrap-new-host.md)
* [ADR 0003: Zero-Trust Ephemeral Bootstrap via Therese](../decisions/0003-zero-trust-therese-bootstrap.md)
* [Security, Cryptography & Bootstrapping](../architecture/security-model.md)
