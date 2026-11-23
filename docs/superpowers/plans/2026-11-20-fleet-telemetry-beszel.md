# Fleet Telemetry & Hermes Alerting (Beszel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy declarative fleet-wide machine telemetry via Beszel Hub (`zita`) and Beszel Agents (all 5 hosts), paired with a read-only `beszel-query` CLI and a paste-ready Hermes self-configuration prompt for Signal alerting.

**Architecture:** A new `modules/beszel.nix` wraps nixpkgs's `services.beszel.hub` (static `beszel-hub` user, persisted `/var/lib/beszel-hub`, declarative `config.yml`, SSH pull via agenix-managed ed25519 keypair, `SHARE_ALL_SYSTEMS=true`) and `services.beszel.agent` (`smartmon`, `systemd`, GPU, extra filesystems, firewall restricted to `tailscale0` + Skylab LAN `192.168.77.0/24`). A stdlib-only Python CLI (`pkgs/beszel-query/`) gives Hermes read-only access to Beszel's PocketBase REST API, while Signal chat routing and webhook triage live purely in Hermes runtime config via `docs/howto/beszel-hermes-prompt.md`.

**Tech Stack:** NixOS (`services.beszel.hub`, `services.beszel.agent` v0.21.0), Caddy reverse proxy, Pi-hole DNS, Agenix (`secrets/` submodule), Python 3 stdlib + `pytest`, Hermes Agent (`gateway/platforms/webhook.py`).

**Spec:** `docs/superpowers/specs/2026-11-20-fleet-telemetry-beszel-design.md`

## Global Constraints

- Impermanence is enabled on all 5 hosts; persistent hub state must live at `/var/lib/beszel-hub` (persisted via `impermanence.directories`, using a static `beszel-hub` user instead of `DynamicUser = true` so impermanence bind-mounts and agenix file ownership work cleanly).
- `modules/smartd.nix` must remain enabled and untouched fleet-wide (active daily short / weekly long self-tests + `disk-health` CLI).
- `zita`'s 24TB HDD (`/mnt/disk1`) must not be woken unnecessarily: `SMART_INTERVAL = "12h"` (`smartctl -n standby`), `DISK_USAGE_CACHE = "1h"` on `zita`, and `beszel-query` must never call `/api/beszel/smart/refresh`.
- Agent port `45876` must never be exposed on WAN, `skynet`, or `iot` (`services.beszel.agent.openFirewall = false`; allow TCP `45876` strictly on `tailscale0` and `192.168.77.0/24`).
- All ports must be registered in `data/ports.nix` (`internal = 8090`, `tailscale = 8091`, `agent = 45876`).
- `secrets/` is a separate git submodule (`nixos-secrets`); `hosts/zita/default.nix` must guard optional `.age` files with `builtins.pathExists` (matching `modules/auto-update.nix`) so `nix eval` passes cleanly before operator secret creation, and commits in `nixcfg` must pass the TruffleHog pre-commit hook.
- Hermes must only receive read-only Beszel API credentials (`secrets/beszel-hermes.env.age`, owned by `hermes:hermes`, mode `0400`), never Beszel admin credentials; Signal alert routing stays purely in Hermes runtime config.
- Ephemeral installer ISO `therese` must not enable `beszel.agent`.

## Review Focus

1. **`beszel-query` when Beszel Hub is unreachable, returns HTTP 401/500, or returns invalid JSON:** Must exit non-zero with a concise stderr error (no traceback) and never leak `BESZEL_API_PASSWORD` into stdout or stderr. *(Pinned in Task 1)*
2. **`beszel-query` against offline/sleeping laptops (`agnes`, `jerome`) or unknown hostnames:** Offline hosts with null `info`/`stats` fields must render cleanly as `down` without crashing; unknown hostnames must exit non-zero listing available host names. *(Pinned in Task 1)*
3. **PocketBase filter & query escaping for special characters in host/unit names (e.g., `container@copyparty.service`, quotes):** Filter strings and URL query params must escape single quotes and URL-encode values so systemd unit names never break queries or inject filter syntax. *(Pinned in Task 1)*
4. **Firewall, `DynamicUser`, and HDD spindown regressions in `modules/beszel.nix`:** Nix evaluation checks must verify `openFirewall == false`, firewall rules restrict `45876` to `tailscale0` + `192.168.77.0/24`, `DynamicUser == false` on `beszel-hub`, `/var/lib/beszel-hub` is in `zita`'s `impermanence.directories`, and `zita` sets `SMART_INTERVAL = "12h"` and `DISK_USAGE_CACHE = "1h"`. *(Pinned in Tasks 2 & 3)*
5. **`beszel-hub` impermanence mount ordering and `therese` isolation:** `beszel-hub` must order after `var-lib-beszel-hub.mount`, seed `beszel_data/config.yml` and `beszel_data/id_ed25519` (`0600`) without touching `data.db`, and `therese` must evaluate with `beszel.agent.enable == false`. *(Pinned in Tasks 2 & 3)*

---

## File Structure

- **Create:** `pkgs/beszel-query/beszel_query.py` — stdlib-only Python 3 read-only CLI for Beszel's PocketBase REST API.
- **Create:** `pkgs/beszel-query/test_beszel_query.py` — `pytest` unit suite covering all subcommands and Review Focus #1–#3.
- **Create:** `pkgs/beszel-query/default.nix` — Nix package builder (`writeShellApplication` wrapping `beszel_query.py`).
- **Modify:** `data/ports.nix` — add `beszel = { internal = 8090; tailscale = 8091; agent = 45876; };`.
- **Modify:** `data/keys.nix` — add `beszelHub` public key entry.
- **Create:** `modules/beszel.nix` — NixOS module implementing `beszel.agent` and `beszel.hub` + Hermes `beszel-query` wiring.
- **Modify:** `hosts/configuration.nix` — enable `beszel.agent` fleet-wide with defaults.
- **Modify:** `hosts/zita/default.nix` — enable `beszel.hub`, `zita`-specific agent overrides (`nvidia-smi`, `/mnt/cache`, `/mnt/disk1`, `DISK_USAGE_CACHE`), Caddy blocks (`metrics.benway.me`, `zita.<tailnet>:8091`), firewall port, canary service, and guarded agenix secrets.
- **Modify:** `hosts/michael/dns.nix` — add `"cname=metrics.benway.me,zita.skylab.home"`.
- **Modify:** `modules/hermes/SOUL.md` — add short Fleet Telemetry section documenting `beszel-query`.
- **Create:** `docs/howto/beszel-hermes-prompt.md` — operator secret-bootstrap + Beszel alert-policy checklist and paste-ready Hermes self-configuration prompt.
- **Modify:** `docs/hosts/zita.md`, `docs/index.md`, `README.md` — document Beszel monitoring and link the how-to.

---

### Task 1: Read-Only `beszel-query` CLI & Unit Test Suite

**Files:**
- Create: `pkgs/beszel-query/beszel_query.py`
- Create: `pkgs/beszel-query/test_beszel_query.py`
- Create: `pkgs/beszel-query/default.nix`

**Interfaces:**
- Consumes: Environment variables `BESZEL_URL` (default `http://127.0.0.1:8090`), `BESZEL_API_EMAIL`, `BESZEL_API_PASSWORD` (loaded from process env or key=value `--env-file`, defaulting to `/run/agenix/beszel-hermes.env` if env vars are unset).
- Produces:
  - CLI executable `beszel-query` packaged by `pkgs/beszel-query/default.nix` (`{pkgs}: pkgs.writeShellApplication { name = "beszel-query"; ... }`).
  - Subcommands:
    - `beszel-query summary [--json]`
    - `beszel-query host <name> [--hours N] [--json]` (default `--hours 1`)
    - `beszel-query systemd [--host <name>] [--failed] [--logs <unit>] [--json]`
    - `beszel-query smart [--host <name>] [--json]`
    - `beszel-query alerts [--host <name>] [--history] [--json]`
  - PocketBase REST endpoints queried (strictly read-only after `POST /api/collections/users/auth-with-password`):
    - `GET /api/collections/systems/records`
    - `GET /api/collections/system_stats/records`
    - `GET /api/collections/systemd_services/records`
    - `GET /api/beszel/systemd/logs?system=<id>&service=<name>`
    - `GET /api/collections/smart_devices/records`
    - `GET /api/collections/alerts/records`
    - `GET /api/collections/alert_history/records`

- [ ] **Step 1: Write failing unit tests in `pkgs/beszel-query/test_beszel_query.py`**

Create `pkgs/beszel-query/test_beszel_query.py` with tests covering:
- `test_load_env_file_parses_quotes_and_comments`: loads `BESZEL_URL`, `BESZEL_API_EMAIL`, `BESZEL_API_PASSWORD` from a temp file ignoring `#` comments and blank lines without overwriting already-set env vars.
- `test_summary_renders_online_and_offline_laptops`: mocks `systems` records including `zita` (`status="up"`, populated `info` with `cpu`, `mp`, `dp`, `t`, `g`) and `agnes` (`status="down"`, `info={}` / `None`); asserts exit code `0`, both hosts appear in JSON and human output, and offline host does not crash *(Review Focus #2)*.
- `test_host_unknown_name_exits_nonzero_with_valid_hosts`: calls `host nonexistent`; asserts non-zero exit and stderr lists `zita` and `agnes` *(Review Focus #2)*.
- `test_host_fetches_recent_stats_with_time_filter`: calls `host zita --hours 2 --json`; asserts request targets `/api/collections/system_stats/records` filtered by `system='<id>'` and sorted `-created`.
- `test_systemd_failed_and_logs_escape_special_chars`: calls `systemd --host zita --failed` and `systemd --host zita --logs "container@copyparty.service"`; asserts `@` and quotes in unit/host names are properly escaped in filter and URL-encoded in `/api/beszel/systemd/logs` *(Review Focus #3)*.
- `test_smart_is_strictly_readonly`: calls `smart --host zita --json`; asserts only `GET /api/collections/smart_devices/records` is called and `/api/beszel/smart/refresh` is NEVER called.
- `test_alerts_and_history`: calls `alerts --json` and `alerts --history --json`; asserts `alerts` and `alert_history` collections are queried and formatted.
- `test_http_errors_and_unreachable_never_leak_password`: mocks `URLError`, HTTP `401`, HTTP `500`, and malformed JSON responses with `BESZEL_API_PASSWORD="super-secret-password-999"`; asserts non-zero exit, clean stderr message (no Python `Traceback`), and `"super-secret-password-999"` does not appear anywhere in stdout or stderr *(Review Focus #1)*.

- [ ] **Step 2: Run pytest to verify tests fail**

Run: `nix-shell -p python3 python3Packages.pytest --run "pytest pkgs/beszel-query/test_beszel_query.py -v"`
Expected: FAIL (`ModuleNotFoundError: No module named 'beszel_query'`).

- [ ] **Step 3: Implement `pkgs/beszel-query/beszel_query.py`**

Implement stdlib-only Python 3 module exposing:
- `load_config(env_file: str | None) -> tuple[str, str, str]` (reads `BESZEL_URL`, `BESZEL_API_EMAIL`, `BESZEL_API_PASSWORD` from env, falling back to `env_file` / `/run/agenix/beszel-hermes.env`; raises `BeszelError` if credentials missing).
- `escape_pb_filter(value: str) -> str` (escapes `\` and `'` for PocketBase filter literals).
- `class BeszelClient`:
  - `__init__(self, base_url: str, email: str, password: str, timeout: float = 10.0, opener=None)`
  - `authenticate(self) -> str` (`POST /api/collections/users/auth-with-password`, caches token; sanitizes errors so password is never echoed).
  - `get_json(self, path: str, params: dict[str, str] | None = None) -> dict` (URL-encodes `params` via `urllib.parse.urlencode`, handles `HTTPError`, `URLError`, `json.JSONDecodeError` -> `BeszelError`).
  - `list_systems()`, `resolve_system(name)`, `get_host_stats(system_id, hours)`, `list_systemd(system_id, failed_only)`, `get_systemd_logs(system_id, service)`, `list_smart(system_id)`, `list_alerts(system_id, history)`.
- `main(argv: list[str] | None = None) -> int`: parses CLI args, catches `BeszelError` and prints `error: <msg>` to stderr returning `1` (never printing stack traces or passwords).

- [ ] **Step 4: Package CLI in `pkgs/beszel-query/default.nix`**

Write `{pkgs}: pkgs.writeShellApplication { name = "beszel-query"; runtimeInputs = [pkgs.python3]; text = ''exec python3 ${./beszel_query.py} "$@"''; }` following `pkgs/auto-update/` style.

- [ ] **Step 5: Run tests and Nix build check**

Run:
```bash
nix-shell -p python3 python3Packages.pytest --run "pytest pkgs/beszel-query/test_beszel_query.py -v"
nix-build --no-out-link -E 'let pkgs = import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = "x86_64-linux"; }; in import ./pkgs/beszel-query { inherit pkgs; }'
```
Expected: All `pytest` cases PASS; `nix-build` produces a store path containing `bin/beszel-query`.

- [ ] **Step 6: Commit**

```bash
git add pkgs/beszel-query/
git commit -m "feat(beszel-query): add read-only Beszel PocketBase CLI and unit tests"
```

---

### Task 2: Port Registry, Keys, Agenix Rules, and `modules/beszel.nix`

**Files:**
- Modify: `data/ports.nix`
- Modify: `data/keys.nix`
- Create: `modules/beszel.nix`

**Interfaces:**
- Consumes: `pkgs/beszel-query/default.nix`, `data/ports.nix`, `data/keys.nix`, nixpkgs `services.beszel.hub` & `services.beszel.agent`.
- Produces:
  - `ports.beszel = { internal = 8090; tailscale = 8091; agent = 45876; };` in `data/ports.nix`.
  - `keys.beszelHub` (initially `""` until operator mints keypair, or populated string) in `data/keys.nix`.
  - NixOS module options in `modules/beszel.nix`:
    - `beszel.agent`:
      - `enable` (`bool`, default `false`)
      - `port` (`port`, default `ports.beszel.agent`)
      - `publicKey` (`str`, default `keys.beszelHub or ""`)
      - `smartmon` (`bool`, default `true`)
      - `smartInterval` (`str`, default `"12h"`)
      - `systemd` (`bool`, default `true`)
      - `gpuCollectors` (`listOf str`, default `[]`)
      - `extraFilesystems` (`listOf str`, default `[]`)
      - `diskUsageCache` (`nullOr str`, default `null`)
      - `extraEnvironment` (`attrsOf str`, default `{}`)
    - `beszel.hub`:
      - `enable` (`bool`, default `false`)
      - `domain` (`str`, default `"metrics.benway.me"`)
      - `port` (`port`, default `ports.beszel.internal`)
      - `tailscalePort` (`port`, default `ports.beszel.tailscale`)
      - `dataDir` (`str`, default `"/var/lib/beszel-hub"`)
      - `keyFile` (`nullOr path`, default `null`) — agenix path to `id_ed25519`
      - `environmentFile` (`nullOr path`, default `null`) — agenix path to `beszel-hub.env` (`USER_EMAIL`, `USER_PASSWORD`)
      - `hermesEnvFile` (`nullOr path`, default `null`) — agenix path to `beszel-hermes.env` (read-only API creds for `beszel-query`)
      - `systems` (`listOf (submodule { name; host; port ? 45876; })`, default `[]`)

- [ ] **Step 1: Register Beszel ports in `data/ports.nix` and key slot in `data/keys.nix`**

- Add `beszel = { internal = 8090; tailscale = 8091; agent = 45876; };` under `# Web & Application Services` in `data/ports.nix`.
- Add `beszelHub = "";` (with comment pointing to `docs/howto/beszel-hermes-prompt.md` for populating the generated `ssh-ed25519 ...` public key) to `data/keys.nix` and export it in the final attrset.
- Verify no port collisions:
  Run: `nix eval --impure --expr 'import ./data/ports.nix' --json`
  Expected: JSON output including `"beszel":{"agent":45876,"internal":8090,"tailscale":8091}` with exit code `0`.

- [ ] **Step 2: Create `modules/beszel.nix`**

Implement `modules/beszel.nix` (auto-imported by `modules/default.nix`) with:
- **`beszel.agent` config** (`lib.mkIf cfgAgent.enable`):
  - Enables `services.beszel.agent` with `openFirewall = false`, `smartmon.enable = cfgAgent.smartmon`.
  - Sets `services.beszel.agent.environment`:
    - `PORT = toString cfgAgent.port`
    - `KEY = cfgAgent.publicKey` (when non-empty)
    - `SMART_INTERVAL = cfgAgent.smartInterval` (when `cfgAgent.smartmon`)
    - `SKIP_SYSTEMD = !cfgAgent.systemd`, `SKIP_SYSTEMD_LOGS = !cfgAgent.systemd`
    - `GPU_COLLECTOR = cfgAgent.gpuCollectors` (when non-empty)
    - `EXTRA_FILESYSTEMS = lib.concatStringsSep "," cfgAgent.extraFilesystems` (when non-empty)
    - `DISK_USAGE_CACHE = cfgAgent.diskUsageCache` (when non-null)
    - merged with `cfgAgent.extraEnvironment`
  - Firewall rule via `networking.firewall.extraInputRules`:
    ```
    iifname "tailscale0" tcp dport ${toString cfgAgent.port} accept
    ip saddr 192.168.77.0/24 tcp dport ${toString cfgAgent.port} accept
    ```
    *(Never sets `openFirewall = true`, protecting WAN, `skynet`, and `iot` — Review Focus #4.)*
- **`beszel.hub` config** (`lib.mkIf cfgHub.enable`):
  - Creates static system user/group `beszel-hub` (`isSystemUser = true`, `home = cfgHub.dataDir`).
  - Enables `services.beszel.hub` with `host = "127.0.0.1"`, `port = cfgHub.port`, `dataDir = cfgHub.dataDir`, `environmentFile = cfgHub.environmentFile`, and `environment = { APP_URL = "https://${cfgHub.domain}"; SHARE_ALL_SYSTEMS = "true"; CHECK_UPDATES = "false"; }`.
  - Overrides `systemd.services.beszel-hub`:
    - `serviceConfig.DynamicUser = lib.mkForce false;`, `serviceConfig.PrivateUsers = lib.mkForce false;`, and `Group = "beszel-hub";` so static user ownership, `chown`, and `/run/agenix` reads work cleanly *(Review Focus #4)*.
    - Impermanence mount ordering when `config.impermanence.enable`: `after` and `wants` include `"var-lib-beszel-hub.mount"` *(Review Focus #5)*.
    - `ExecStartPre` (prefixed with `"+"` root helper, running before `beszel-hub migrate up` via `lib.mkBefore`): ensures `${cfgHub.dataDir}/beszel_data` exists (`0700 beszel-hub:beszel-hub`), copies `cfgHub.keyFile` to `${cfgHub.dataDir}/beszel_data/id_ed25519` (`0600 beszel-hub:beszel-hub`) if set, and writes declarative `config.yml` (generated via `pkgs.formats.yaml {}` with `systems` array) to `${cfgHub.dataDir}/beszel_data/config.yml` (`0640 beszel-hub:beszel-hub`) when `cfgHub.systems != []`, without touching `data.db` *(Review Focus #5)*.
  - Adds `cfgHub.dataDir` to `impermanence.directories` when `config.impermanence.enable` is true.
  - Installs `beszel-query` into `environment.systemPackages` (which exposes it at `/run/current-system/sw/bin/beszel-query`, already included in `hermes-agent`'s forced `PATH`).
  - When `config.hermes.enable` is true and `cfgHub.hermesEnvFile != null`: sets `systemd.services.hermes-agent.environment.BESZEL_ENV_FILE = toString cfgHub.hermesEnvFile;`.

- [ ] **Step 3: Verify module parses and passes `statix` / Nix eval**

Run:
```bash
nix-instantiate --parse modules/beszel.nix >/dev/null
nix-shell -p statix --run "statix check modules/beszel.nix data/ports.nix data/keys.nix"
```
Expected: Zero parse errors and zero `statix` warnings.

- [ ] **Step 4: Commit**

```bash
git add data/ports.nix data/keys.nix modules/beszel.nix
git commit -m "feat(beszel): add declarative Beszel hub and agent NixOS module"
```

---

### Task 3: Fleet Host Wiring & Evaluation Verification

**Files:**
- Modify: `hosts/configuration.nix`
- Modify: `hosts/zita/default.nix`
- Modify: `hosts/michael/dns.nix`

**Interfaces:**
- Consumes: `beszel.agent` and `beszel.hub` options from `modules/beszel.nix`, `ports.beszel` from `data/ports.nix`.
- Produces: Active Beszel configuration across `zita`, `michael`, `francis`, `agnes`, `jerome` (and untouched `therese`), exposed via `https://metrics.benway.me` and `https://zita.<tailnet>:8091`.

- [ ] **Step 1: Enable `beszel.agent` fleet-wide in `hosts/configuration.nix`**

Add `beszel.agent = { enable = true; smartmon = true; smartInterval = "12h"; systemd = true; };` right alongside `smartd.enable = true;` in `hosts/configuration.nix`. (Leave `smartd.enable = true;` completely untouched.)

- [ ] **Step 2: Configure `beszel.hub`, `zita` agent overrides, Caddy, firewall, canary, and guarded secrets in `hosts/zita/default.nix`**

In `hosts/zita/default.nix`:
- Define `hasBeszelHubKey`, `hasBeszelHubEnv`, `hasBeszelHermesEnv` using `builtins.pathExists (lib.custom.relativeToRoot "secrets/...")` (matching `modules/auto-update.nix`).
- Conditionally declare `age.secrets` entries:
  - `beszel-hub-key` (`mode = "0400"`, `owner = "root"`, `group = "root"` — copied by `ExecStartPre` root helper with `0600 beszel-hub:beszel-hub`)
  - `beszel-hub-env` (`mode = "0400"`, `owner = "beszel-hub"`, `group = "beszel-hub"`)
  - `beszel-hermes-env` (`mode = "0400"`, `owner = "hermes"`, `group = "hermes"`)
- Add `beszel.agent` overrides:
  - `gpuCollectors = ["nvidia-smi"];`
  - `extraFilesystems = ["/mnt/cache__Cache" "/mnt/disk1__Bulk"];`
  - `diskUsageCache = "1h";`
- Enable `beszel.hub`:
  - `enable = true;`
  - `domain = "metrics.benway.me";`
  - `keyFile = lib.mkIf hasBeszelHubKey config.age.secrets.beszel-hub-key.path;` (or `if hasBeszelHubKey then ... else null`)
  - `environmentFile = if hasBeszelHubEnv then config.age.secrets.beszel-hub-env.path else null;`
  - `hermesEnvFile = if hasBeszelHermesEnv then config.age.secrets.beszel-hermes-env.path else null;`
  - `systems`:
    - `{ name = "zita"; host = "127.0.0.1"; port = ports.beszel.agent; }`
    - `{ name = "michael"; host = "192.168.77.1"; port = ports.beszel.agent; }`
    - `{ name = "francis"; host = "francis.${config.tailscale.tailnet}"; port = ports.beszel.agent; }`
    - `{ name = "agnes"; host = "agnes.${config.tailscale.tailnet}"; port = ports.beszel.agent; }`
    - `{ name = "jerome"; host = "jerome.${config.tailscale.tailnet}"; port = ports.beszel.agent; }`
- Add `ports.beszel.tailscale` to `networking.firewall.allowedTCPPorts`.
- Add Caddy reverse proxy blocks for `metrics.benway.me` (Cloudflare DNS-01 TLS -> `127.0.0.1:${toString ports.beszel.internal}`) and `${hostname}.${config.tailscale.tailnet}:${toString ports.beszel.tailscale}` -> `127.0.0.1:${toString ports.beszel.internal}`.
- Add `"beszel-hub"` to `auto-update.canary.services`.

- [ ] **Step 3: Add `metrics.benway.me` CNAME in `hosts/michael/dns.nix`**

Add `"cname=metrics.benway.me,zita.skylab.home"` alongside the existing `*.benway.me` CNAME lines (`hosts/michael/dns.nix:94-99`).

- [ ] **Step 4: Run Nix evaluation verification across all 6 hosts (pinning Review Focus #4 & #5)**

Run:
```bash
nix eval --json .#nixosConfigurations.zita.config --apply 'c: {
  hubEnable = c.services.beszel.hub.enable;
  hubDynamicUser = c.systemd.services.beszel-hub.serviceConfig.DynamicUser;
  hubPrivateUsers = c.systemd.services.beszel-hub.serviceConfig.PrivateUsers;
  hubAfter = c.systemd.services.beszel-hub.after;
  impermanence = builtins.elem "/var/lib/beszel-hub" c.impermanence.directories;
  agentOpenFw = c.services.beszel.agent.openFirewall;
  fwHasTailscaleRule = builtins.match ".*iifname \"tailscale0\" tcp dport 45876 accept.*" c.networking.firewall.extraInputRules != null;
  fwHasSkylabRule = builtins.match ".*ip saddr 192\\.168\\.77\\.0/24 tcp dport 45876 accept.*" c.networking.firewall.extraInputRules != null;
  smartInterval = c.services.beszel.agent.environment.SMART_INTERVAL;
  diskCache = c.services.beszel.agent.environment.DISK_USAGE_CACHE;
  gpu = c.services.beszel.agent.environment.GPU_COLLECTOR;
  smartd = c.smartd.enable;
  canary = builtins.elem "beszel-hub" c.auto-update.canary.services;
}'
for h in michael francis agnes jerome; do
  nix eval --json ".#nixosConfigurations.${h}.config" --apply 'c: {
    agent = c.services.beszel.agent.enable;
    openFw = c.services.beszel.agent.openFirewall;
    smartmon = c.services.beszel.agent.smartmon.enable;
    smartd = c.smartd.enable;
  }'
done
nix eval --json .#nixosConfigurations.therese.config.services.beszel.agent.enable
```
Expected:
- `zita`: `hubEnable: true`, `hubDynamicUser: false`, `hubPrivateUsers: false`, `hubAfter` contains `"var-lib-beszel-hub.mount"`, `impermanence: true`, `agentOpenFw: false`, `fwHasTailscaleRule: true`, `fwHasSkylabRule: true`, `smartInterval: "12h"`, `diskCache: "1h"`, `gpu: ["nvidia-smi"]`, `smartd: true`, `canary: true`.
- `michael`, `francis`, `agnes`, `jerome`: `agent: true`, `openFw: false`, `smartmon: true`, `smartd: true`.
- `therese`: `false`.

- [ ] **Step 5: Commit**

```bash
git add hosts/configuration.nix hosts/zita/default.nix hosts/michael/dns.nix
git commit -m "feat(hosts): deploy Beszel hub on zita, agents fleet-wide, and metrics.benway.me DNS"
```

---

### Task 4: Hermes `SOUL.md`, Self-Configuration Prompt, and Documentation

**Files:**
- Modify: `modules/hermes/SOUL.md`
- Create: `docs/howto/beszel-hermes-prompt.md`
- Modify: `docs/hosts/zita.md`
- Modify: `docs/index.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `beszel-query` CLI subcommands from Task 1, `metrics.benway.me` / `data/ports.nix` from Tasks 2–3, Hermes webhook gateway (`WEBHOOK_ENABLED=true`, `WEBHOOK_PORT=8644`, `hermes webhook subscribe`) verified in locked `hermes-agent`.
- Produces:
  - Concise `Fleet Telemetry (Beszel)` section in `modules/hermes/SOUL.md`.
  - Complete operator bootstrap + paste-ready Hermes prompt in `docs/howto/beszel-hermes-prompt.md`.
  - Updated fleet documentation (`docs/hosts/zita.md`, `docs/index.md`, `README.md`).

- [ ] **Step 1: Document `beszel-query` in `modules/hermes/SOUL.md`**

Append a concise `## 5. Fleet Telemetry (Beszel)` section to `modules/hermes/SOUL.md` listing the exact `beszel-query` subcommands (`summary`, `host <name> --hours N`, `systemd --host <name> --failed`, `systemd --host <name> --logs <unit>`, `smart --host <name>`, `alerts --history`) and noting that access is strictly read-only and respects `zita`'s 24TB HDD spindown.

- [ ] **Step 2: Create `docs/howto/beszel-hermes-prompt.md`**

Write an OKF v0.2 how-to document containing:
1. **One-Time Secret Bootstrap (in `secrets/` submodule):**
   - Exact `agenix-rules.nix` entries for `beszel-hub-key.age`, `beszel-hub.env.age`, `beszel-hermes.env.age` (all `[keys.hosts.zita] ++ admins`).
   - Exact commands to generate the dedicated ed25519 hub keypair (`ssh-keygen -t ed25519 -N "" -C "beszel-hub@zita"`), copy the public key into `data/keys.nix` (`beszelHub`), and encrypt the 3 `.age` files (`beszel-hub-key.age`, `beszel-hub.env.age` with `USER_EMAIL`/`USER_PASSWORD`, `beszel-hermes.env.age` with `BESZEL_URL=http://127.0.0.1:8090`, `BESZEL_API_EMAIL`, `BESZEL_API_PASSWORD`).
2. **One-Time Beszel UI Setup (`https://metrics.benway.me`):**
   - Create the `readonly` Beszel user matching `beszel-hermes.env.age` (with `SHARE_ALL_SYSTEMS=true` already set by NixOS, it automatically sees all 5 hosts read-only).
   - Configure alert policy per spec §5.3:
     - `zita`, `michael`: Status (offline, 3–5 min grace) ON, Failed `systemd` units ON, Disk (`>= 85%`), Temp, CPU/RAM/Load (multi-min window), SMART ON.
     - `francis`, `agnes`, `jerome`: Status (offline) OFF, Failed `systemd` units OFF, Disk/Temp/SMART ON.
   - Paste the Shoutrrr webhook URL produced by Hermes below into **Settings -> Notifications** (`generic://127.0.0.1:8644/webhooks/beszel?template=json&disabletls=yes`).
3. **Paste-Ready Hermes Self-Configuration Prompt:**
   - A clean fenced prompt block Joel can paste directly into whichever Signal chat/DM he chooses with Hermes, instructing Hermes to:
     1. Run `beszel-query summary`, `beszel-query smart`, and `beszel-query systemd --failed` to verify read-only telemetry access.
     2. Enable its built-in webhook adapter on localhost (`WEBHOOK_ENABLED=true`, `WEBHOOK_PORT=8644`, bound to `127.0.0.1`) and create a webhook subscription for route `beszel` delivering to the **current Signal chat**.
     3. Configure its triage prompt/skill: when a Beszel alert JSON `{title, message}` arrives, use `beszel-query` to gather relevant context (affected host vitals, failed `systemd` units + logs, SMART status) and reply in Signal with a concise, actionable summary (severity, likely cause, suggested next check)—staying quiet unless an alert fires or Joel asks.
     4. Verify `http://127.0.0.1:8644/health`, test end-to-end with a synthetic alert payload, and output the exact Shoutrrr URL (`generic://127.0.0.1:8644/webhooks/beszel?template=json&disabletls=yes`) for Beszel Hub.

- [ ] **Step 3: Update `docs/hosts/zita.md`, `docs/index.md`, and `README.md`**

- `docs/hosts/zita.md`: add Beszel Hub (`metrics.benway.me`) to Hosted Services.
- `docs/index.md`: add link to `docs/howto/beszel-hermes-prompt.md` under Operational How-To Guides.
- `README.md`: add Beszel fleet telemetry bullet under `Areas of Note` and link under `Documentation`.

- [ ] **Step 4: Run final verification suite**

Run:
```bash
nix-shell -p python3 python3Packages.pytest --run "pytest pkgs/beszel-query/test_beszel_query.py -v"
nix-shell -p statix --run "statix check modules/beszel.nix data/ports.nix data/keys.nix hosts/configuration.nix hosts/zita/default.nix hosts/michael/dns.nix"
nix eval .#nixosConfigurations.zita.config.system.build.toplevel.drvPath --raw
```
Expected: All unit tests pass, zero `statix` issues, and `zita`'s full system derivation evaluates cleanly.

- [ ] **Step 5: Commit**

```bash
git add modules/hermes/SOUL.md docs/howto/beszel-hermes-prompt.md docs/hosts/zita.md docs/index.md README.md
git commit -m "docs(beszel): add Hermes telemetry instructions, self-config prompt, and fleet docs"
```
