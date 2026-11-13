---
type: concept
title: "Host Profile: michael (HP Slim Core Router & Perimeter Firewall)"
description: "Router and perimeter firewall profile for michael, an HP Slim i3-12100 running dual 2.5GbE, 802.1Q VLANs, CAKE SQM, Pi-hole DNS, and initrd remote unlock."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - host
  - router
  - firewall
  - networking
  - security
  - hardware
---

# michael: The Archangel at the Gate 🛡️

> *"St. Michael the Archangel is the prince of the heavenly host and patron saint of soldiers, guardians, and the sick. Who better to stand watch over the homelab perimeter and protect the private network from the hostile internet?"*

`michael` is an **HP Slim Desktop** converted into an enterprise-grade router, firewall, and traffic shaper. Powered by an Intel Core i3-12100 and outfitted with a dual-port 2.5 Gigabit Ethernet PCIe adapter, `michael` routes, filters, shapes, and protects every packet entering or leaving the household.

---

## Hardware Specifications

| Component | Specification | Notes |
| :--- | :--- | :--- |
| **Chassis** | HP Slim Desktop S01 Form Factor | Low profile, small desktop footprint, low power consumption |
| **Processor** | Intel Core i3-12100 (Alder Lake) | 4 Cores, 8 Threads (Golden Cove Performance cores) up to 4.3 GHz |
| **Primary Network** | Dual-Port 2.5GbE PCIe Adapter | `enp3s0` (WAN) + `enp4s0` (LAN 802.1Q Trunk) |
| **Rescue Network** | Realtek 1GbE Onboard NIC | `enp5s0` dedicated out-of-band emergency rescue subnet |
| **Memory** | 16 GB DDR4-3200 | Ample overhead for in-memory state, Pi-hole FTL, and packet tables |
| **Storage** | Encrypted NVMe SSD | LUKS2 encryption with dropbear initrd remote SSH unlocking |
| **Security Hardware** | Discrete TPM 2.0 & Intel PTT | Hardware cryptographic state and Secure Boot validation |

---

## Network Architecture & VLAN Topology

`michael` connects to a managed KeepLINK 8-port 2.5GbE switch via an 802.1Q tagged VLAN trunk on `enp4s0`. The internal network is strictly segmented into functional zones:

```
                  Internet / ONT (Upstream ISP)
                               |
                   [enp3s0 - 2.5GbE WAN]
                         +-----------+
                         |  michael  |
                         +-----------+
                               |
               [enp4s0 - 2.5GbE 802.1Q Trunk]
                               |
              +----------------+----------------+
              | KeepLINK 8-Port 2.5GbE Switch   |
              +----------------+----------------+
                 /             |              \
           VLAN 77          VLAN 62         VLAN 69
           (Skylab)         (Skynet)         (IoT)
         Trusted PCs         Guests       Smart Devices
```

### VLAN Breakdown

| Network | VLAN ID | Subnet | Policy & Description |
| :--- | :--- | :--- | :--- |
| **Skylab** | 77 | `192.168.77.0/24` | **Trusted Devices**: Laptops, workstations, server access, full internet. |
| **Skynet** | 62 | `192.168.62.0/24` | **Guest Network**: Direct internet access; isolated from all internal subnets. |
| **IoT** | 69 | `192.168.69.0/24` | **Untrusted Smart Home**: Outbound internet only; isolated from Skylab and LAN. |
| **Management**| 1 | `192.168.1.0/24` | Infrastructure access for the managed switch and Wi-Fi Access Points. |
| **OOB Rescue** | — | `192.168.99.0/24` | **Emergency Out-of-Band**: Hardwired to `enp5s0` for direct recovery if trunk fails. |

---

## Key Software Modules

* **[Declarative Firewall & NAT (`routing.nix`)](../../hosts/michael/routing.nix)**: Built using modern Linux kernel packet filtering. Enforces strict inter-VLAN boundary rules, stateful connection tracking, and NAT masquerading for outbound traffic.
* **[CAKE Smart Queue Management (`cake-sqm.nix`)](../../modules/cake-sqm.nix)**: Utilizes the Common Applications Kept Enhanced (CAKE) qdisc on the WAN interface to completely eliminate bufferbloat, guaranteeing rock-bottom gaming latencies and crystal-clear voice calls even during heavy downloads.
* **[Network-Wide Ad Blocking & DNS (`dns.nix`)](../../hosts/michael/dns.nix)**: Runs Pi-hole with custom VLAN group policies ([`pihole-groups.nix`](../../hosts/michael/pihole-groups.nix)) allowing granular filtering per device category, combined with local unbound DNS resolution and Handshake DNS (`hnsd`).
* **[Initrd Network & Remote LUKS Unlock (`remote-unlock.nix`)](../../hosts/michael/remote-unlock.nix)**: When `michael` reboots after an update or power outage, the initrd initializes the network and starts a lightweight Dropbear SSH server. The admin can SSH in remotely to unseal the encrypted root drive.

---

## Related Documents
* [Network Routing & Perimeter Defense](../architecture/network-routing.md)
* [Remote LUKS Unlocking over SSH](../howto/remote-luks-unlock.md)
* [Fleet Overview & Ethos](../architecture/fleet-overview.md)
