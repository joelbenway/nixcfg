---
type: architecture
title: "Architecture: Hermes Autonomous Agent & Signal Gateway"
description: "Architecture of the Hermes AI agent on zita: Signal messenger bridge, privilege-separated Agentic GitOps self-provisioning, and zero-cost model routing."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - architecture
  - ai
  - hermes
  - signal
  - gitops
  - nixos
---

# Hermes Autonomous Agent & Signal Gateway 🕊️🤖

**Hermes** is an autonomous AI systems engineer running as a native systemd daemon on `zita`. It provides an encrypted, 24/7 mobile interface via **Signal Messenger**, paired with a novel **Agentic GitOps** architecture that allows the agent to safely self-provision its own dependencies on an otherwise immutable NixOS system.

---

## High-Level Architecture

```
                       [ Joel's Mobile Phone ]
                                  |
                           (Signal Protocol)
                                  |
                                  v
                [/var/lib/signal-cli - signal-cli Daemon]
                        (HTTP API on 127.0.0.1:8085)
                                  |
                                  v
                   [hermes-agent.service on zita]
              (Native systemd daemon, user: hermes)
                                  |
       +--------------------------+--------------------------+
       |                                                     |
       v                                                     v
[Multi-Model Inference Router]               [Privilege-Separated GitOps]
- Primary: Nemotron 3 Ultra ($0.00)          - Leaf: modules/hermes/agent-env.nix
- Review: GLM 5.3 Flash 1M ($0.00)           - Script: rebuild-agent-env
- Vision: Gemma 4 31B ($0.00)                - Atomic ~/.nix-profile updates
- Compression: Nemotron 3.5 ($0.00)          - Auto-commit to hermes/agent-env branch
- Fallbacks: DeepSeek -> Local Offline       - Detached systemd background reload
```

---

## 1. Signal Gateway & Interaction Layer

* **`signal-cli` Daemon**: Runs as an independent systemd service under the `hermes` user, exposing an HTTP endpoint on `127.0.0.1:8085`.
* **Quick Device Linking (`signal-link`)**: An admin script prints a terminal QR code using `qrencode`, allowing instant device linking from the Signal mobile app (**Settings -> Linked Devices -> Add Device**).
* **Local Terminal Access**: The administrator can also interact directly from the `zita` terminal via `hermes-chat` or `hermes-cli`.

---

## 2. Agentic GitOps: Self-Provisioning on Immutable NixOS

On immutable NixOS, traditional imperative package management (`pip install`, `apt`, `npm -g`, `cargo install`) fails by design. Traditional solutions either give the agent full `root` access (a catastrophic security risk) or run it inside an unmanaged, mutable container.

Instead, Hermes uses a **privilege-separated leaf-module architecture**:

### The Blast Radius Containment
* **Restricted File Access**: The `hermes` user only has write permissions to:
  * Its state directory: `/var/lib/hermes`
  * The mutable leaf configuration: `modules/hermes/agent-env.nix` (synced with `/var/lib/hermes/agent-env.nix`)
* **Read-Only System**: Hermes has no write access to host configurations, secrets, firewall rules, or core NixOS modules.
* **Strict Sudo Whitelist**: The `hermes` user has passwordless sudo access restricted strictly to:
  * `/run/current-system/sw/bin/rebuild-agent-env`
  * Restarting `hermes-agent.service` via `systemd-run`

### The Self-Provisioning Workflow (`rebuild-agent-env`)
When a user asks Hermes to analyze a video or convert a document, and Hermes lacks the necessary CLI tool:
1. **Leaf Edit**: Hermes appends the required package (e.g. `pkgs.ffmpeg`, `pkgs.poppler_utils`, `pkgs.ripgrep`) to `extraPackages` in `agent-env.nix`.
2. **Rebuild Trigger**: Hermes runs `sudo rebuild-agent-env`.
3. **Automated Pipeline**:
   * Validates syntax with `nix-instantiate --parse`.
   * GitOps tracking: Automatically commits the change to a dedicated git branch (`hermes/agent-env`).
   * Builds the derivation with `nix-build` against Nixpkgs.
   * Atomically switches `~/.nix-profile` to the new environment generation.
   * Deep-merges runtime configuration changes (`extraSettings`) into `~/.hermes/config.yaml`.
   * Probes environment health.
4. **Immediate Availability**: The new tools are immediately live in Hermes's execution environment. If runtime options changed, a detached systemd timer schedules a graceful restart 2 seconds later, allowing the current conversation turn to complete cleanly.

---

## 3. Zero-Cost Model Hierarchy ($0.00 Token Budget)

Hermes is configured to maximize intelligence and context while maintaining a **$0.00 token cost** using free tiers from OpenRouter, NVIDIA, and Google, backed by Agenix-encrypted API keys:

| Role | Provider | Model | Cost | Capabilities |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Engine** | OpenRouter | `nvidia/nemotron-3-ultra-550b-a55b:free` | **$0.00** | Reasoning, tool-use, code synthesis |
| **Review / Big Brain**| NVIDIA | `z-ai/glm-5.3-flash` | **$0.00** | 1M context window for large repo analysis |
| **Media / Vision** | Google | `gemma-4-31b-it` | **$0.00** | Image and visual diagram inspection |
| **Compression** | NVIDIA | `nvidia/nemotron-3.5-lightning-30b-a3b`| **$0.00** | Automated conversation context summarization |
| **Paid Fallback** | DeepSeek | `deepseek-flash` | Pay-as-you-go | Failover if free providers rate-limit |
| **Offline Fallback** | Local | `http://localhost:8080/v1` | **$0.00** | Local fallback if internet uplink is down |

---

## 4. Guiding Soul & Operational Boundaries (`SOUL.md`)

Hermes's core identity, behavioral directives, and immutable operating constraints are declaratively injected via [`modules/hermes/SOUL.md`](../../modules/hermes/SOUL.md). This system prompt instructs the agent to respect NixOS immutability, follow the GitOps self-provisioning protocol, and maintain persistent memory across conversations using its built-in SQLite memory provider.

---

## Related Documents
* [AI Development Environment](./ai-development.md)
* [Host Profile: zita](../hosts/zita.md)
* [Security, Cryptography & Bootstrapping](./security-model.md)
