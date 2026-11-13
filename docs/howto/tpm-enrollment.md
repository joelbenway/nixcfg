---
type: howto
title: "How-To: TPM2 LUKS Auto-Unlock and Re-Enrollment"
description: "Runbook for inspecting, testing, and re-enrolling TPM2 LUKS cryptographic tokens using the automated tpm-reenroll CLI utility."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - howto
  - tpm
  - luks
  - encryption
  - security
---

# How-To: TPM2 LUKS Auto-Unlock and Re-Enrollment 🔐

NixCFG systems utilize hardware TPM2 chips to automatically unseal LUKS2 disk encryption volumes at boot, provided the system firmware and Secure Boot states remain intact.

This guide explains how to inspect TPM bindings and re-enroll devices using the built-in `tpm-reenroll` command-line tool.

---

## The `tpm-reenroll` Utility

Every host with [`modules/tpm.nix`](../../modules/tpm.nix) enabled has access to the custom system-wide utility `tpm-reenroll` (also aliased as `tpm-enroll`).

### 1. Inspecting Live Cryptographic Status

To check existing LUKS keyslots, bound TPM tokens, and active system PCRs:

```bash
sudo tpm-reenroll --status
```

#### Example Output:
```
============================================================
 TPM2 & LUKS Keyslot Status for /dev/disk/by-partlabel/disk-main-root
============================================================
Keyslot 0: passphrase (Agenix Master Recovery Key)
Keyslot 1: tpm2 (systemd-tpm2 token #0)
Bound PCRs: 0 (firmware), 2 (option ROMs), 7 (Secure Boot state)

Current Hardware PCR Measurements:
PCR 0: 3a98f12...
PCR 2: 4b29c41...
PCR 7: 8e501a3...
Status: Healthy. Hardware unsealing active.
```

---

## 2. Re-Enrolling After Firmware or Hardware Updates

When a UEFI BIOS update, hardware replacement, or Secure Boot certificate change occurs, the hardware PCR measurements change. When this happens, the TPM will refuse to auto-unseal the drive, requiring the fallback recovery passphrase at boot.

Once booted into the system, re-bind the TPM to the new system measurements with a single command:

```bash
sudo tpm-reenroll
```

### What this does:
1. Locates the device's LUKS passphrase automatically from `/run/agenix/` (or prompts interactively if running in a recovery shell).
2. Cleans out stale TPM2 tokens from the LUKS header.
3. Queries current PCR 0, 2, and 7 values from the local TPM2 device.
4. Seals a new randomized encryption key against the current hardware PCR hash.
5. Writes the new token into keyslot 1.

---

## 3. Forcing a Token Reset

If a keyslot becomes corrupted or a token needs to be forcibly replaced:

```bash
sudo tpm-reenroll --force
```

This wipes all existing TPM2 tokens and forces generation of fresh sealed keys using the system agenix secret.

---

## Emergency Recovery Passphrase

If a system ever fails to auto-unlock at boot:
1. Enter the manual recovery passphrase shown on the console prompt.
2. The recovery passphrase is the plaintext secret managed by Agenix in `secrets/<hostname>-luks-passphrase.age`.
3. Once the machine finishes booting, run `sudo tpm-reenroll` to restore automated boots.

---

## Related Documents
* [Security, Cryptography & Bootstrapping](../architecture/security-model.md)
* [How to Bootstrap a New Host](./bootstrap-new-host.md)
* [ADR 0001: Impermanence with Root-on-Tmpfs/Btrfs](../decisions/0001-impermanence-and-btrfs.md)
