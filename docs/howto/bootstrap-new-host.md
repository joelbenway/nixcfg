---
type: howto
title: "How-To: Bootstrap and Provision a New Bare-Metal Host"
description: "Step-by-step runbook for building the therese bootstrap ISO, booting bare metal, and deploying a secure NixOS host using install_host and nixos-anywhere."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - howto
  - deployment
  - bootstrapping
  - therese
  - nixos-anywhere
  - disko
---

# How to Bootstrap and Provision a New Bare-Metal Host 🚀

This guide walks through deploying a completely unconfigured bare-metal machine (such as `francis` or a laptop) into a fully encrypted, Secure-Boot-enrolled NixOS host without ever exposing master keys.

---

## Prerequisites

1. An operator workstation (e.g., `jerome` or `francis`) with git access to the `nixcfg` repository.
2. A USB flash drive (Ventoy-formatted or raw flash drive).
3. The target machine connected to Ethernet or within range of the guest Wi-Fi network.

---

## Step 1: Build the `therese` Installer ISO

From the root of the `nixcfg` repository on your operator workstation, run:

```bash
./scripts/build_iso
```

### What this does:
* Builds the `therese` ISO inside a clean container environment.
* Injects guest Wi-Fi parameters and the scoped Tailscale OAuth bootstrap token (`tag:bootstrap`).
* Outputs the completed boot image to `iso/therese.iso`.
* If a mounted Ventoy drive is detected, it offers to copy the ISO directly to the USB drive automatically.

---

## Step 2: Boot the Target Machine

1. Insert the USB drive into the target machine (e.g., `francis`).
2. Power on and enter the UEFI firmware setup (F10 on HP, F12 on Dell):
   * **If enabling Secure Boot (Lanzaboote)**: Put the UEFI firmware into **Setup Mode** (clear or delete existing Platform Keys).
   * Ensure Secure Boot is enabled in the BIOS settings.
3. Select the USB drive from the UEFI one-time boot menu.
4. The machine will boot `therese` into RAM, automatically connect to the network, and join your Tailnet as an ephemeral node named `therese`.

---

## Step 3: Deploy Remotely from Your Workstation

From your operator workstation terminal, run the deployment script specifying the target hostname:

```bash
./scripts/install_host francis
```

### What happens under the hood:
1. **Node Discovery**: The script locates the online `therese` node on your Tailscale network.
2. **Setup Mode Verification**: If `secureboot.enable = true` for the target host, it verifies that the target UEFI firmware is properly in Setup Mode before proceeding.
3. **RAM-Only Secret Staging**:
   * Reads the target's LUKS encryption passphrase from Agenix.
   * Generates or stages the host's permanent SSH ed25519 identity key.
   * Injects these secrets strictly into volatile RAM (`/tmp/secrets`) on the live bootstrap node over SSH.
4. **Disk Partitioning**: Executes `disko` remotely to format GPT tables, create the FAT32 ESP, initialize LUKS2 containers, and configure Btrfs subvolumes (`@root`, `@home`, `@nix`, `@persist`).
5. **System Installation**: Calls `nixos-anywhere` to copy all system store paths from the operator machine or binary cache directly to the target drive.
6. **Reboot**: Unmounts filesystems, syncs buffers, and reboots the target machine into its new permanent operating system.

---

## Step 4: Post-Install Verification

Once the machine reboots:

1. **Verify TPM Auto-Unlock**: The host should boot directly to the desktop or login prompt without requesting a LUKS password on console.
2. **Verify Secure Boot**: Run:
   ```bash
   bootctl status
   ```
   Confirm that `Secure Boot: enabled (user)` is reported.
3. **Verify Ephemeral Root**: Run `mount | grep ' / '` to confirm that root is mounted from the `@root` subvolume, ready to be wiped cleanly on the next reboot.

---

## Related Documents
* [Host Profile: therese](../hosts/therese.md)
* [Host Profile: francis](../hosts/francis.md)
* [TPM2 Enrollment & Re-enrollment](./tpm-enrollment.md)
* [ADR 0003: Zero-Trust Ephemeral Bootstrap via Therese](../decisions/0003-zero-trust-therese-bootstrap.md)
