---
type: architecture
title: "Architecture: Agentic AI Development Environment"
description: "Declarative AI development platform integrating Google Antigravity, OpenCode, Model Context Protocol (MCP) servers, and secure credential injection via loadkeys."
status: active
trust: verified
owner: joel
timestamp: "2026-11-12"
tags:
  - architecture
  - ai
  - antigravity
  - opencode
  - mcp
  - tooling
---

# Agentic AI Development Environment 🤖⚡

The workstations in the NixCFG fleet (`francis`, `jerome`, `agnes`) feature a declarative, fully reproducible environment for **agentic pair-programming** and AI assistance.

Instead of wrestling with manual binary installations, mismatched Node/Python SDKs, or unmanaged API keys, the AI environment is declared in NixOS modules and deployed identically across machines.

---

## Architectural Stack

```
+-----------------------------------------------------------------------+
| Interactive Development & Editors                                     |
| Antigravity IDE (VSCode-based)  |  agy CLI  |  OpenCode CLI Assistant |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| Model Context Protocol (MCP) Shared Hub                               |
| NixOS Search | GitHub API | Tavily Web Search | Context7 Docs         |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
| Secure Credential Injection (loadkeys)                               |
| systemd user service pulls encrypted API keys from Agenix              |
| and injects them safely into the desktop session environment           |
+-----------------------------------------------------------------------+
```

---

## 1. Google Antigravity Platform ([`modules/antigravity.nix`](../../modules/antigravity.nix))

The Antigravity module provides complete access to Google's advanced agentic coding environment:
* **`agy` CLI**: Headless command-line agent capable of planning, executing complex refactors, and interacting with Git worktrees.
* **Antigravity IDE**: Rich visual workspace configured with specialized extensions, debugger profiles, and deep integration with language servers.
* **Skills and Customizations**: Declaratively manages global rules, skills, and sidecars across all user profiles.

---

## 2. Model Context Protocol (MCP) ([`modules/mcp.nix`](../../modules/mcp.nix))

AI agents in the environment are equipped with real-time tool execution via the Model Context Protocol:
* **`nixos` Server**: Enables the agent to query nixpkgs package databases, option definitions, and flake metadata live during sessions.
* **`github` Server**: Allows agents to inspect pull requests, read repository issues, and verify CI run statuses.
* **`tavily` & Web Search**: Real-time retrieval of live documentation, errata, and hardware specifications.
* **`context7` Server**: Live library and API documentation querying.

---

## 3. Session Key Injection ([`modules/loadkeys.nix`](../../modules/loadkeys.nix))

API keys for model providers (Gemini, Claude, OpenAI) are sensitive assets that should never be stored in plaintext bash dotfiles or shell histories.

* The [`loadkeys`](../../modules/loadkeys.nix) systemd user service runs automatically upon desktop login.
* It securely reads encrypted keys from Agenix (`/run/agenix/`) and exports them into `systemd --user` and `dbus` session environments.
* Both CLI agents (`agy`, `opencode`) and GUI editors instantly inherit their operational credentials without manual prompts or exposed secrets.

---

## 4. Local LLM Runner ([`modules/llm.nix`](../../modules/llm.nix))

For completely offline or privacy-sensitive inference:
* Utilizes `llama.cpp` and `llama-swap` to host open-weight models locally.
* Dynamically manages model swapping in VRAM/system RAM based on active query requirements.

---

## Related Documents
* [Fleet Overview & Ethos](./fleet-overview.md)
* [Host Profile: francis](../hosts/francis.md)
* [Security, Cryptography & Bootstrapping](./security-model.md)
