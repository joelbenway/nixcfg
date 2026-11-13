---
type: decision
title: "ADR 0003: Zero-Trust Ephemeral Bootstrap via Therese"
description: "Architectural Decision Record choosing scoped ephemeral Tailscale OAuth credentials over baked-in master keys for installer media."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - adr
  - decision
  - security
  - bootstrap
  - tailscale
  - zero-trust
---

# ADR 0003: Zero-Trust Ephemeral Bootstrap via Therese

## Context
Deploying hardened, fully encrypted NixOS hosts onto bare-metal hardware presents a fundamental bootstrapping dilemma:
1. **The "Flash Drive Vulnerability"**: If disk encryption passphrases, master Age keys, or production SSH host private keys are baked into the installer USB drive, losing that physical drive compromises the security of the fleet.
2. **The "Manual Console Burden"**: Typing 64-character randomized LUKS passphrases and long base64 keys into a target console monitor by hand is slow, error-prone, and precludes headless installations.
3. **Reproducibility**: The installation process must be completely scripted and repeatable across different hardware architectures without bespoke manual steps.

## Decision
We designed and implemented **`therese`**, an ephemeral bootstrap ISO built inside an isolated container:
* **Zero Baked-In Production Secrets**: The ISO carries no master encryption keys, no host SSH keys, and no persistent credentials.
* **Ephemeral Tailnet Mesh**: The ISO contains only guest Wi-Fi credentials and a scoped Tailscale OAuth client credential tagged strictly with `tag:bootstrap`.
* **RAM-Only Key Injection**: Upon booting, the target machine registers as an isolated, temporary node on the Tailnet. The administrator triggers `./scripts/install_host <hostname>` from an authorized operator workstation.
* **Remote Deployment via `nixos-anywhere`**: LUKS passphrases and SSH keys are read from Agenix on the operator workstation and staged strictly in volatile target RAM (`/tmp/secrets`). Disks are formatted declaratively via Disko, system closures deployed over SSH, and the target reboots cleanly into its permanent identity.

## Consequences
### Positive:
* **Physically Safe Media**: If the installer USB drive is misplaced, lost, or left in a conference room, it poses zero threat to fleet secrets or production systems.
* **Completely Headless**: Target machines can be installed without attaching a display, keyboard, or mouse; all deployment logic and progress reporting happens on the operator's laptop.
* **Ephemeral Lifecycle**: As soon as the target machine reboots into its final installation, the temporary `therese` node vanishes automatically from the Tailnet.

### Trade-offs:
* **Network Dependency**: The bootstrap process requires active internet access (Wi-Fi or Ethernet) to reach the Tailscale coordination plane and download closures.
* **Pre-staged Secrets Requirement**: Host secrets (LUKS passphrase, host SSH public key) must be generated and committed to Agenix prior to running `install_host`.
