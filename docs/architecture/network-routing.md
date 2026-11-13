---
type: architecture
title: "Architecture: Network Routing & Perimeter Defense"
description: "Network topology and firewall architecture on michael: dual 2.5GbE, 802.1Q trunking, VLAN segmentation, CAKE SQM traffic shaping, and Pi-hole DNS."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - architecture
  - networking
  - firewall
  - vlan
  - cake-sqm
  - security
---

# Network Routing & Perimeter Defense 🛡️🌐

The homelab’s network infrastructure is anchored by `michael`, an HP Slim desktop running NixOS configured as a dedicated high-throughput multi-gigabit router, stateful firewall, and DNS filtration gateway.

---

## Physical Interface Layout

| Physical Port | Linux Interface | Speed | Destination / Role |
| :--- | :--- | :--- | :--- |
| **PCIe Port 1 (Bottom)** | `enp3s0` | 2.5 Gbps | Upstream ISP Modem / ONT (WAN) |
| **PCIe Port 2 (Top)** | `enp4s0` | 2.5 Gbps | KeepLINK 8-Port Switch Port 1 (802.1Q Trunk) |
| **Onboard 1GbE NIC** | `enp5s0` | 1.0 Gbps | **Emergency Out-of-Band (OOB) Rescue Port** (`192.168.99.1/24`) |

> **Out-of-Band Rescue Feature**: If an 802.1Q switch failure or severe configuration misstep ever isolates the main trunk (`enp4s0`), plugging any laptop directly into the motherboard’s onboard 1GbE Ethernet jack (`enp5s0`) immediately grants a dedicated rescue DHCP lease and local SSH console access without touching the console keyboard or monitor.

---

## VLAN Architecture & Security Policy

Traffic flowing across the 2.5GbE trunk (`enp4s0`) is segmented into distinct 802.1Q VLAN sub-interfaces:

```
[enp4s0 2.5GbE Trunk]
      |
      +---> enp4s0.1  (VLAN 1:  Management)   192.168.1.0/24   [Switches, APs]
      |
      +---> enp4s0.77 (VLAN 77: Skylab)       192.168.77.0/24  [Trusted Hosts]
      |
      +---> enp4s0.62 (VLAN 62: Skynet)       192.168.62.0/24  [Guest Access]
      |
      +---> enp4s0.69 (VLAN 69: IoT)          192.168.69.0/24  [Smart Home]
```

### Inter-VLAN Firewall Rules

1. **Skylab (VLAN 77 - Trusted)**:
   * Can initiate connections to all VLANs (IoT, Guest, Management).
   * Has unrestricted outbound WAN access.
   * Can access all storage shares on `zita`, local DNS servers, and router administration interfaces over SSH/HTTPS.
2. **Skynet (VLAN 62 - Guest)**:
   * Direct NAT access to outbound internet.
   * Client-to-client isolation enabled.
   * Strictly blocked from routing into Skylab (VLAN 77) or accessing router management ports.
3. **IoT (VLAN 69 - Untrusted)**:
   * Outbound WAN internet only for device cloud connectivity.
   * Strictly quarantined from Skylab and the router's internal services.
   * Specific mDNS reflection permitted via Avahi so trusted mobile devices on Skylab can cast media to smart speakers or Chromecasts.

---

## Bufferbloat Elimination with CAKE SQM

Many residential broadband connections suffer from crippling latency spikes ("bufferbloat") whenever heavy downloads or cloud backups saturate the upstream or downstream bandwidth.

`michael` solves this by applying the state-of-the-art **CAKE (Common Applications Kept Enhanced)** queue discipline to the WAN interface ([`modules/cake-sqm.nix`](../../modules/cake-sqm.nix)):
* **Fair Queueing**: Automatically distributes bandwidth across competing connections and flows.
* **DiffServ Awareness**: Automatically detects and prioritizes interactive traffic (VoIP, SSH keystrokes, DNS lookups, gaming packets) ahead of bulk TCP streams.
* **Low Latency Under Load**: Pings remain sub-15ms even during multi-stream 4K downloads or full-bandwidth git checkouts.

---

## DNS Architecture & Granular Ad Blocking

DNS resolution on `michael` is handled through a layered approach ([`hosts/michael/dns.nix`](../../hosts/michael/dns.nix)):

1. **Pi-hole FTL Integration**:
   Acts as the primary network DNS server. Employs VLAN group rules ([`hosts/michael/pihole-groups.nix`](../../hosts/michael/pihole-groups.nix)) to enforce distinct blocking policies:
   * *Skylab Group*: Strict ad and tracking telemetry blocking.
   * *IoT Group*: Blocks aggressive smart TV ad beacons, data collection endpoints, and telemetry while preserving device functionality.
   * *Guest Group*: Balanced ad filtering plus malware domain protection.
2. **Local Recursive Resolution**: Unbound resolves recursive queries directly from upstream root nameservers with DNSSEC validation.
3. **Handshake TLD Support**: Integrates `hnsd` for native, decentralized resolution of alternative Handshake top-level domains.

---

## Related Documents
* [Host Profile: michael](../hosts/michael.md)
* [Remote LUKS Unlocking over SSH](../howto/remote-luks-unlock.md)
* [Security, Cryptography & Bootstrapping](./security-model.md)
