---
type: plan
title: "NixCFG Fleet Audit Remediation Plan (Tiers 1–3)"
description: "Phased remediation plan addressing security, boot/scheduling, script reliability, CI test execution, desktop decoupling, service-catalog deduplication, and dead-code cleanup across nixcfg."
status: active
owner: joel
timestamp: "2026-11-24"
tags:
  - plan
  - security
  - refactoring
  - maintenance
  - ci
---

# NixCFG Fleet Audit Remediation Plan

**Goal:** Resolve all high-priority security, boot, and reliability bugs across the fleet first (**PR 1 / Tier 1**), then follow with CI test wiring + Plasma/router decoupling (**PR 2 / Tier 2**) and service-catalog/impermanence consolidation + dead-code cleanup (**PR 3 / Tier 3**).

---

## Roadmap Overview

| PR | Scope | Branch | Status |
|---|---|---|---|
| **PR 1 (Tier 1)** | Security hardening (`michael` initrd key, `hermes` sudoers, `forgejo-runner`, `copyparty` firewall), workstation `kernelParams` bug, reboot/timer collisions, `remote-unlock` port drift, `deploy_host`/`reboot_host`/`boot-verify`/`auto-update`/`netprov`/`loadkeys`/`vpn-gateway`/`firefox` fixes | `fix/tier1-audit` | **In Progress** |
| **PR 2 (Tier 2A)** | Wire `fleet-notify`, `beszel-query`, and `kmail-provision` `pytest` suites into `flake.nix` `checks` + CI; deduplicate CI secrets setup; dynamic shell-lint discovery; add `therese` to CI eval; decouple KDE Plasma from `users/` & stop leaking workstation/dev stack (`podman`, `devenv`, MCP, `pinentry-qt`, browser secrets) onto `michael` and `zita` | `refactor/ci-and-decoupling` | Planned |
| **PR 3 (Tier 2B + Tier 3)** | Single source of truth `data/services.nix` + `data/network.nix`, shared persistent-service impermanence helper, fleet baseline consolidation in `hosts/configuration.nix` (incl. workstation `btrfs.autoScrub`), drop over-provisioned secrets (`storage-luks-passphrase`, builder `nix-builder-ssh`), share VS Code tooling (`antigravity`/`vscodium`), prune dead modules/hardware (`retroarch`, `llm`, `proton`, 6 orphaned `hardware/*.nix`), complete `data/ports.nix`, and clean up `shell.nix`/`flake.nix`/`disk-health.sh`/`TODO.md` | `refactor/consolidate-and-cleanup` | Planned |

---

## PR 1 (Tier 1): Detailed Task Breakdown (`fix/tier1-audit`)

### Global Constraints
- Never print, commit, or log plaintext secrets or credentials.
- Preserve existing functionality for all 5 hosts (`agnes`, `francis`, `jerome`, `michael`, `zita`) and `therese`.
- Keep `modules/notify.nix` desktop-agnostic; keep `fleet-notify-desktop` inside `modules/plasma.nix`.
- All Nix files pass `alejandra --check .` and `statix check .`; all Bash scripts pass `shellcheck` and `shfmt -d -i 2 -ci`; all Python changes pass syntax/unit tests; all 5 hosts evaluate cleanly via `nix eval`.

### Review Focus (PR 1)
1. **`michael` initrd key isolation:** Confirm `/persist/etc/ssh/ssh_host_ed25519_key` is absent from `boot.initrd.network.ssh.hostKeys` while `/persist/etc/ssh/initrd_host_ed25519_key` remains present.
2. **`hermes` privilege boundary:** Confirm `systemd-run` and `Defaults:hermes !authenticate` are gone from sudoers, `rebuild-agent-env` rejects `--system`/custom path args when called by `hermes`, and global `programs.git.config.safe.directory = ["*"]` is removed.
3. **Workstation `boot.kernelParams` merge:** Confirm `nix eval` shows `intel_iommu=on`, `mem_sleep_default=deep`, `tpm_tis.interrupts=0`, AND hardware `i915.*` params all present on `agnes` and `francis`, and `intel_iommu=on,igfx_off` (without duplicate `intel_iommu=on`) on `jerome`.
4. **Script & updater safety:** Confirm `reboot_host` pipes sudo password over stdin (never in remote argv), `deploy_host` delegates to `nixos-auto-update-canary` and handles `degraded` consistently, `boot-verify.sh` alerts and cleans up `pending-reboot.json` on watchdog rollback, and `netprov.py` uses `requests.Session` with `raise_for_status()`.

---

### Task 1: Host Security, Boot Params, & Maintenance Schedule Fixes
**Files:**
- Modify: `hosts/michael/initrd-network.nix` — remove `/persist/etc/ssh/ssh_host_ed25519_key` from `boot.initrd.network.ssh.hostKeys`.
- Modify: `hosts/michael/remote-unlock.nix` — bind `zitaUnlockPkg` once and have `zita-auto-unlock` use `${toString ports.initrdSsh.ssh}` and call `${zitaUnlockPkg}/bin/zita-unlock "$target" "${toString ports.initrdSsh.ssh}"`.
- Modify: `hosts/michael/dns.nix` — move `pihole-gravity-update` timer from `Sun *-*-* 03:30:00` to `Sun *-*-* 04:30:00` (avoiding `03:30` reboot window).
- Modify: `hosts/zita/storage.nix` — move `mergerfs-mover` timer from `03:00` to `02:00` (avoiding `03:00` reboot window).
- Modify: `hosts/zita/default.nix` — drop `DHCP = "yes"` from initrd `10-lan` static config so dual NICs don't race for extra DHCP leases.
- Modify: `hosts/common/workstation.nix` & `hosts/jerome/default.nix` — introduce `options.workstation.iommuParam` (default `"intel_iommu=on"`, set to `"intel_iommu=on,igfx_off"` in `hosts/jerome/default.nix`), remove `lib.mkDefault` from `boot.kernelParams` in `workstation.nix`, and drop redundant `mem_sleep_default=deep` / `tpm_tis.interrupts=0` from `jerome/default.nix`.

**Verification:** `alejandra --check .`, `statix check .`, and `nix eval --json` verifying `boot.kernelParams` on `agnes`, `francis`, and `jerome`, plus `michael` initrd `hostKeys`.

---

### Task 2: Service Module Security & Reliability Fixes
**Files:**
- Modify: `modules/hermes/default.nix` & `modules/hermes/SOUL.md`:
  - Remove `systemd-run` entries from `security.sudo.extraRules` and remove `Defaults:hermes !authenticate`.
  - In `rebuild-agent-env`, reject `--system` and positional `REPO_PATH`/`HOST_NAME` overrides when `SUDO_USER == "hermes"` (or non-root non-wheel caller).
  - Remove global `programs.git.config.safe.directory = ["*"]` (keep scoped `GIT_CONFIG_*` inside `rebuild-agent-env`).
  - Remove duplicate `pkgs.signal-cli` package entry (keep wrapper) and include `pkgs.systemd` in `environment.PATH` (dropping dead `systemd.services.hermes-agent.path`).
  - Update `modules/hermes/SOUL.md` line 110–113 to recommend `sudo rebuild-agent-env --restart` instead of `sudo systemd-run`.
- Modify: `modules/forgejo.nix`:
  - Use `utils.escapeSystemdPath cfg.dataDir` for mount unit ordering instead of hardcoded `"var-lib-forgejo.mount"`.
  - Replace `chmod -R 0750 ${cfg.dataDir}` with `chmod -R u=rwX,g=rX,o= ${cfg.dataDir}`.
  - Run `forgejo-runner` as dedicated system user `forgejo-runner` (`group = "forgejo-runner"`, `extraGroups = ["podman"]` when Podman is enabled), running `ExecStartPre` with `+` and `chown -R forgejo-runner:forgejo-runner /var/lib/forgejo-runner`.
- Modify: `modules/copyparty.nix`:
  - Remove unused host firewall port `networking.firewall.allowedTCPPorts = [cfg.port]` (binds `127.0.0.1` behind Caddy) and remove dead unused `users.users.copyparty` / `users.groups.copyparty`.
- Modify: `modules/loadkeys.nix`:
  - Move per-user unit from global `systemd.user.services` into `home-manager.users.${user}.systemd.user.services.loadkeys-import`, add `Unit.ConditionPathExists = toString cfg.envFile`, and remove the unreachable 30s file-wait loop.
- Modify: `modules/auto-update.nix`:
  - Guard `gitMirror` firewall rule properly across nftables vs iptables (`192.168.77.0/24` instead of `192.168.0.0/16`, matching `modules/beszel.nix`).
- Modify: `modules/vpn-gateway.nix`:
  - Add `gnugrep` to `piaWgScript.runtimeInputs` and add an assertion that `cfg.providers.pia.credentialsFile != null` when `cfg.providers.pia.enable`.
- Modify: `modules/firefox.nix`:
  - Fix `"security.pki.crlite_mode" = 2` (int instead of string `"2"`) and wrap `home.activation.{createFirefoxDir,cleanupFirefoxSymlinks}` with `lib.hm.dag.entryBefore ["checkLinkGeneration"]`.

**Verification:** `alejandra --check .`, `statix check .`, `nix eval` across all 5 hosts (`agnes`, `francis`, `jerome`, `michael`, `zita`).

---

### Task 3: Operational Scripts, Auto-Update, & `netprov` Reliability Fixes
**Files:**
- Modify: `scripts/reboot_host`:
  - Pipe `$SUDO_PW` over stdin (`printf '%s\n' "$SUDO_PW" | ssh -o BatchMode=yes ... "sudo -S -- $*"`), never interpolating it into the remote command string.
  - Accept both `running` and `degraded` in the stage-2 return check.
  - Use `run_ssh_sudo "tpm-reenroll --status"` at post-reboot verification.
  - Return exit code `1` from `usage` on invalid/missing arguments and validate `$# -ge 2` for value-taking flags.
- Modify: `scripts/deploy_host`:
  - Clear `trap - ERR` at the start of `rollback()`.
  - Replace duplicated `michael` inline canaries and contradictory `degraded` post-switch check with `run_ssh "nixos-auto-update-canary"` (plus external `dig @${TARGET_ADDRESS}` for `michael`), covering `zita`'s 10 critical services automatically too.
  - Only sync remote git repo when clean and on `master` (never clobbering `hermes/agent-env` or dirty trees) and use `HOME` on the remote user instead of hardcoded `/home/joel`.
  - Return exit code `1` from `usage` on invalid/missing arguments and validate `$# -ge 2`.
- Modify: `pkgs/auto-update/boot-verify.sh`:
  - In the `TARGET_SYS != BOOTED_SYS` branch (watchdog/panic fallback), remove `PENDING_BOOT_FILE` and publish a `boot_verify_failed` (`critical`) alert via `nixos-auto-update-write-status`.
- Modify: `pkgs/auto-update/auto-update.sh`:
  - Remove root-owned `git remote` mutation of `/home/joel/Projects/nixcfg`.
  - Report `"update_failed"` (not `"rollback_failed"`) when rollback succeeds, keeping `"rollback_failed"` for when rollback itself fails.
  - Require `bootctl` for unattended reboot (fall back to `reboot_required_attended` if absent), and only write `pending-reboot.json` and report `reboot_scheduled` when `shutdown -r` succeeds.
- Modify: `pkgs/netprov/netprov.py`:
  - Replace raw `curl` subprocesses in `cmd_switch_apply` and `cmd_switch_cycle_poe` with `requests.Session` (using `data={...}` form encoding, `timeout=5`, and `raise_for_status()`), eliminating argv password leaks and silent HTTP failures.
  - Derive AP radio slot bindings from `s.get("band")` (supporting `all`/`dual`/`tri` and `"2.4"`/`"5"`/`"6"`).
  - Wrap `build_ap_commands` in `cmd_ap_apply` with `try/except ValueError`.

**Verification:**
- `shellcheck` & `shfmt -d -i 2 -ci` on all modified scripts.
- `python3 -m py_compile` + unit smoke tests on `pkgs/netprov/netprov.py` (testing `requests.Session` error handling and `build_ap_commands` band routing).
- Behavioral bash tests on `boot-verify.sh` watchdog-rollback path.
- Full 5-host `nix eval` + `alejandra --check .` + `statix check .`.

---

## PR 2 (Tier 2A) — Planned Follow-Up Scope
- Convert `pkgs/beszel-query/default.nix` to `stdenvNoCC.mkDerivation` with `doCheck = true` running `pytest`.
- Export `packages` and `checks` (`fleet-notify`, `beszel-query`, `kmail-provision`) in `flake.nix` so `nix flake check` runs all Python unit tests in CI.
- Extract `.github/actions/setup-secrets/action.yml`, dynamically discover shell scripts in `ci.yml`, pin lint tools to `flake.lock`, and add `therese` to host eval.
- Decouple KDE Plasma from `users/common/default.nix` (`plasma.enable` owned by `hosts/common/workstation.nix`, gate Dolphin/KMail/wallpaper on `config.plasma.enable`), add `joel.dev` (default `joel.desktop`) so `michael` and `zita` don't pull Podman/devenv/Node/MCP/browser secrets, and make `modules/gpg.nix` default to `pinentry-curses` on headless hosts.

## PR 3 (Tier 2B + Tier 3) — Planned Follow-Up Scope
- Add `data/services.nix` + `data/network.nix` to generate `zita` Caddy vhosts/firewall ports and `michael` Pi-hole CNAMEs/initrd network from a single source of truth.
- Extract a shared persistent-service helper for `impermanence.directories` + `escapeSystemdPath` `.mount` ordering + static users (`actual`, `beszel`, `forgejo`, `jellyfin`, `notify`, `vaultwarden`), removing `zita`'s `fixVarLibPrivate` hack.
- Consolidate fleet defaults into `hosts/configuration.nix` (including `services.btrfs.autoScrub` for workstations) and prune dead/over-provisioned secrets (`storage-luks-passphrase`, builder `nix-builder-ssh`).
- Share VS Code extensions/settings between `modules/antigravity.nix` and `modules/vscodium.nix`.
- Remove dead modules/hardware (`retroarch.nix`, `llm.nix`, `proton`, 6 orphaned `hardware/*.nix`), complete `data/ports.nix`, and clean up `shell.nix`, `flake.nix`, `disk-health.sh`, `TODO.md`, `opencode.nix`, and `networkstack.nix`.
