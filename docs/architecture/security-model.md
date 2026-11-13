---
type: architecture
title: "Architecture: Security, Cryptography & Bootstrapping"
description: "Comprehensive security architecture: Impermanence root-wiping, Lanzaboote Secure Boot, TPM2 auto-enrollment, Agenix secret lifecycle, and zero-trust bootstrapping."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - architecture
  - security
  - impermanence
  - secure-boot
  - tpm
  - agenix
  - crypto
---

# Security, Cryptography & Bootstrapping 🔒🛡️

The NixCFG homelab treats consumer and enterprise hardware with high-security zero-trust principles. From the moment silicon powers on to the operational runtime, the system assumes hostile environments, enforces cryptographic verification, and eliminates configuration state drift.

---

## The Four Pillars of the Security Model

```
+--------------------------------------------------------------------------+
| 1. Cryptographic Boot Integrity                                          |
|    Lanzaboote UEFI Secure Boot with custom enrolled keys (PK, KEK, db)    |
|    prevents untrusted bootloaders, kernels, and initrd tampering.        |
+--------------------------------------------------------------------------+
                                     |
                                     v
+--------------------------------------------------------------------------+
| 2. Hardware-Bound Disk Encryption                                        |
|    LUKS2 full-disk encryption sealed against TPM2 PCR measurements.       |
|    Auto-unseals only when UEFI firmware and boot chain remain unaltered. |
+--------------------------------------------------------------------------+
                                     |
                                     v
+--------------------------------------------------------------------------+
| 3. Ephemeral Root Runtime (Impermanence)                                  |
|    Root filesystem is wiped on every single reboot. State only exists    |
|    in explicitly declared /persist mountpoints and volatile RAM.         |
+--------------------------------------------------------------------------+
                                     |
                                     v
+--------------------------------------------------------------------------+
| 4. Ephemeral Secrets Lifecycle (Agenix)                                  |
|    Encrypted secrets decrypted at boot strictly into volatile RAM        |
|    (/run/agenix/) bound to host SSH public identities.                   |
+--------------------------------------------------------------------------+
```

---

## 1. Impermanence: Erasing Root on Every Boot

Traditional Linux systems accumulate state drift, stale packages, temp files, and potential malware persistence over years of operation.

In this flake ([`modules/impermanence.nix`](../../modules/impermanence.nix)):
* **Blank Slate**: On every boot, the root filesystem (`/`) is cleanly wiped back to an empty snapshot or ephemeral tmpfs.
* **Explicit Persistence**: Only paths explicitly declared in the configuration are mapped to `/persist`:
  * System identity: `/etc/machine-id`, `/etc/ssh/ssh_host_ed25519_key`.
  * Logs: `/var/log` for systemd journal retention across reboots.
  * Secrets: `/persist/secrets/` containing sealed keys.
  * Network: NetworkManager Wi-Fi profiles and Tailscale machine state.
* **Result**: If an attacker compromises a service or drops a binary into `/tmp`, `/bin`, or `/usr`, a simple reboot completely vaporizes their presence.

---

## 2. Lanzaboote Secure Boot Automation

UEFI Secure Boot is configured declaratively via [`modules/secureboot.nix`](../../modules/secureboot.nix) utilizing [Lanzaboote](https://github.com/nix-community/lanzaboote):
* **Custom Keys**: The system does not rely on third-party keys; it generates and signs system boot closures with custom Platform Keys (PK), Key Exchange Keys (KEK), and Database (db) keys stored in `/var/lib/sbctl`.
* **Atomic Signing**: When NixOS builds a new generation, Lanzaboote automatically signs the UKI (Unified Kernel Image) and systemd-boot loader before writing to the EFI System Partition.

---

## 3. Automated TPM2 LUKS Enrollment (`tpm-reenroll`)

Full-disk encryption without hardware auto-unlock requires typing long passphrases on every reboot—an enormous barrier for headless servers or automated reboot notifications.

This flake implements fully automated TPM2 unsealing ([`modules/tpm.nix`](../../modules/tpm.nix)):
* **Automated Enrollment**: A oneshot systemd service checks all configured LUKS devices at boot. If a device lacks a TPM2 keyslot, it reads the encrypted passphrase from Agenix and seals it against the system TPM2 chip bound to PCRs 0 (firmware), 2 (option ROMs), and 7 (Secure Boot state).
* **CLI Companion (`tpm-reenroll`)**: If a UEFI firmware update or kernel command-line change alters system PCRs, the admin simply runs:
  ```bash
  sudo tpm-reenroll
  ```
  The script automatically reads the live agenix secret, wipes invalidated TPM keyslots, and re-seals against the updated system measurements.
* **Inspection**: Running `sudo tpm-reenroll --status` displays live keyslots, enrolled TPM tokens, and active PCR hashes.

---

## 4. Secret Lifecycle via Agenix

Secrets (Wi-Fi PSKs, Tailscale OAuth tokens, LUKS passphrases, API keys) are stored in git encrypted with `age` ([`secrets/`](../../secrets/)):
* Encrypted against each host’s public SSH ed25519 key.
* The host private key resides exclusively on the physical machine in `/persist/etc/ssh/ssh_host_ed25519_key`.
* Decryption occurs during early boot directly into `/run/agenix/` (a memory-only `tmpfs`), ensuring plaintext secrets never touch disk storage.

---

## Related Documents
* [TPM2 Enrollment & Re-enrollment](../howto/tpm-enrollment.md)
* [ADR 0001: Impermanence with Root-on-Tmpfs/Btrfs](../decisions/0001-impermanence-and-btrfs.md)
* [ADR 0003: Zero-Trust Ephemeral Bootstrap via Therese](../decisions/0003-zero-trust-therese-bootstrap.md)
