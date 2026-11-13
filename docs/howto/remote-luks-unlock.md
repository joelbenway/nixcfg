---
type: howto
title: "How-To: Remote Headless LUKS Unlocking over SSH"
description: "Runbook for remotely unlocking michael and zita during early initrd boot over SSH, including the automated cross-host zita-auto-unlock daemon."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - howto
  - luks
  - initrd
  - ssh
  - encryption
  - automation
---

# How-To: Remote Headless LUKS Unlocking over SSH 🔑🌐

Headless servers running full-disk encryption present a classic challenge: if the machine power-cycles or reboots following a kernel update, it cannot mount its root filesystem or start normal network services without someone entering the disk encryption passphrase.

The NixCFG homelab solves this using **Stage 1 Initrd Networking** and an **Automated Peer-to-Peer Unlocking Daemon**.

---

## Architecture Overview

```
                          [ Power Outage / Kernel Reboot ]
                                         |
                                         v
                      +--------------------------------------+
                      |  zita boots into initrd stage 1      |
                      |  - Configures 192.168.77.20          |
                      |  - Starts Dropbear SSH on port 2222  |
                      |  - Waits for LUKS passphrase         |
                      +--------------------------------------+
                                         ^
                                         |
     (Probes every 15s)                  | (Transmits passphrase over SSH)
                                         |
                      +--------------------------------------+
                      |  michael (Router / Gateway)          |
                      |  - Detects port 2222 open on zita    |
                      |  - Reads passphrase from Agenix      |
                      |  - Unlocks zita automatically        |
                      +--------------------------------------+
```

---

## 1. Automated Unlocking: `michael` -> `zita`

When `zita` (the storage server) reboots, `michael` (the router) detects it and unlocks it automatically without human intervention:

* **Detection Daemon**: `michael` runs a systemd timer ([`hosts/michael/remote-unlock.nix`](../../hosts/michael/remote-unlock.nix)) executing every 15 seconds.
* **Network Probe**: Netcat probes `zita.home:2222`.
* **Automated Injection**: Once detected, `michael` establishes an SSH connection using its host key, pipes `zita-luks-passphrase` into `systemd-tty-ask-password-agent`, and unlocks the drive.
* **Manual Trigger**: If needed, an operator on `michael` can manually invoke:
  ```bash
  zita-unlock
  ```

---

## 2. Manually Unlocking `michael` During Boot

When `michael` itself reboots after an update, its initrd brings up the network interfaces before root is mounted:

* **Skylab VLAN (Trusted)**: Available at `192.168.77.1:2222`
* **Management VLAN**: Available at `192.168.1.1:2222`
* **Emergency Out-of-Band (OOB)**: Available at `192.168.99.1:2222` on `enp5s0`

### Unlocking Steps:
From any trusted laptop (`jerome` or `agnes`) connected to Skylab or plugged into the emergency OOB port:

```bash
# Connect to initrd SSH on port 2222
ssh -p 2222 root@192.168.77.1
```

Once connected, enter the LUKS passphrase at the prompt or run:
```bash
systemd-tty-ask-password-agent
```

As soon as the passphrase verifies, LUKS opens `cryptroot`, the initrd network shuts down, Dropbear exits, and Stage 2 begins mounting filesystems and bringing up the firewall and router services.

---

## Related Documents
* [Host Profile: michael](../hosts/michael.md)
* [Host Profile: zita](../hosts/zita.md)
* [Network Routing & Perimeter Defense](../architecture/network-routing.md)
* [Security, Cryptography & Bootstrapping](../architecture/security-model.md)
