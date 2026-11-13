---
type: concept
title: "Host Profile: agnes & jerome (Dell Latitude E-Series Tri-Metal Laptops)"
description: "Mobile workstation profiles for agnes (Dell E7270) and jerome (Dell E7470), upgraded with 32GB RAM, FHD IPS displays, me_cleaned Intel ME, and E-Port docks."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - host
  - laptop
  - mobile
  - dell
  - hardware
  - security
---

# agnes & jerome: The Indestructible Tri-Metal Relics 💻

> *"The world throws away millions of perfectly good corporate laptops because an arbitrary Windows 11 TPM or CPU cutoff told them to. With NixOS, these magnesium and aluminum machines outshine modern plastic consumer laptops in durability, repairability, and speed."*

`agnes` and `jerome` are Dell Latitude E-Series business laptops from what many consider the golden age of enterprise portables: 14nm Skylake architecture, NVMe storage speeds, native TPM 2.0, but still featuring physical trackpoint buttons, modular RAM, and the legendary **Dell E-Port docking connector**.

---

## Technical Specifications Comparison

| Feature | `agnes` (Dell Latitude E7270) | `jerome` (Dell Latitude E7470) |
| :--- | :--- | :--- |
| **Form Factor** | 12.5" Sub-notebook | 14.0" Ultraportable Workstation |
| **Chassis** | Magnesium alloy & aluminum Tri-metal (MIL-STD 810G) | Magnesium alloy & aluminum Tri-metal (MIL-STD 810G) |
| **Processor** | Intel Core i7-6600U (2C/4T @ 2.6 - 3.4 GHz) | Intel Core i7-6650U (2C/4T @ 2.2 - 3.4 GHz) |
| **Graphics** | Intel HD Graphics 520 | **Intel Iris Graphics 540** (with 64MB eDRAM cache) |
| **Memory** | **32 GB DDR4-2133** (Factory max was 16GB) | **32 GB DDR4-2133** (Factory max was 16GB) |
| **Display Panel** | Upgraded 12.5" 1080p Full HD IPS (Matte) | Upgraded 14.0" 1080p Full HD IPS (Matte) |
| **Storage** | 1 TB SK Hynix Gold P31 PCIe NVMe | 1 TB High-Speed PCIe NVMe |
| **Firmware State** | UEFI Secure Boot with custom PK/KEK | **[me_cleaner](https://github.com/corna/me_cleaner)** neutralized Intel ME firmware |
| **Docking Interface**| Physical bottom E-Port (100W power + dual DP) | Physical bottom E-Port (100W power + dual DP) |
| **Namesake** | St. Agnes (martyred at age 12, matching 12") | St. Jerome (Doctor of Church, translator of Vulgate) |

---

## Key Hardware Modifications

Both laptops have been heavily customized beyond their original factory configurations:

1. **Memory Ceiling Doubled**: While Dell and Intel officially documented a 16GB RAM limit for these models, both systems are outfitted with dual 16GB DDR4 SODIMMs (32GB total), verified stable under continuous load and memory-intensive compilation.
2. **Display Upgrades**: Shipped from the factory with washed-out 1366x768 TN panels, both laptops were retrofitted with vibrant, high-contrast 1080p FHD matte IPS panels.
3. **Intel ME Neutralization (`jerome`)**: The Intel Management Engine firmware on `jerome` was stripped down using [`me_cleaner`](https://github.com/corna/me_cleaner). Unnecessary ME modules, active networking stacks, and out-of-band management components were removed from the SPI flash ROM, leaving only the bare minimum required to bring up the silicon.
4. **Docking Station Ecosystem**: The physical underside E-Port connector provides instant, single-click connection to dual 4K monitors, wired Gigabit networking, USB peripherals, and full charging power without fiddling with flaky USB-C dongles.

---

## Desktop Environment & Software Stack

Both laptops run an identical, fully declarative mobile workstation configuration:
* **KDE Plasma 6 + [Plasma-Manager](../../modules/plasma.nix)**: Declarative panel layouts, keyboard shortcuts, window behavior, and Breeze Dark styling.
* **[Hardened Firefox](../../modules/firefox.nix)**: Ephemeral session profiles, telemetry stripped, custom user.js, and automated extension provisioning (uBlock Origin, Bitwarden, etc.).
* **Security & Storage**: Disko-provisioned LUKS2 with Btrfs, Impermanence root-wiping, Lanzaboote Secure Boot, and automatic TPM2 auto-unlocking.
* **Agentic Development**: Outfitted with Google Antigravity (`agy` CLI + IDE) and OpenCode for on-the-go pairing with AI models.

---

## Related Documents
* [Fleet Overview & Ethos](../architecture/fleet-overview.md)
* [Security, Cryptography & Bootstrapping](../architecture/security-model.md)
* [ADR 0001: Impermanence with Root-on-Tmpfs/Btrfs](../decisions/0001-impermanence-and-btrfs.md)
