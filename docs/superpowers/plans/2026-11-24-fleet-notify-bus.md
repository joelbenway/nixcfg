# Fleet-Wide Notification Bus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a desktop-agnostic fleet notification bus (`modules/notify.nix`) backed by self-hosted `ntfy-sh` on `zita`, wire KDE Plasma desktop streaming inside `modules/plasma.nix`, and unify `auto-update`, `smartd`, `beszel`, and systemd `OnFailure=` alerts onto the bus.

**Architecture:** `zita` runs NixOS `services.ntfy-sh` (`auth-default-access: deny-all`, least-privilege `agenix` tokens, Caddy TLS on `notify.benway.me` + Tailscale port `2587`). Every host enables `notify.client`, getting a stdlib Python `fleet-notify` CLI, `/etc/fleet-notify/config.json`, and a `fleet-notify@.service` `OnFailure=` template. Desktop consumers stay strictly inside desktop modules (`modules/plasma.nix` runs `fleet-notify-desktop` SSE → `notify-send`) so any workstation can switch desktops without touching `modules/notify.nix`.

**Tech Stack:** NixOS modules (`services.ntfy-sh`, Caddy, Home Manager, `agenix`, `impermanence`), Python 3 (stdlib only + `pytest`), Bash (`shellcheck` / `shfmt -i 2 -ci`), `libnotify` (`notify-send`).

**Spec:** `docs/superpowers/specs/2026-11-24-fleet-notify-bus-design.md`

## Global Constraints

- Public repo (`nixcfg`) / private secrets (`secrets/` submodule): zero tokens, hashes, or personal credentials in Nix store, CLI argv, `/etc/fleet-notify/config.json`, logs, or public files.
- Every reference to `secrets/*.age` must be guarded by `builtins.pathExists` so CI and pre-bootstrap evaluations pass when secrets are absent.
- `modules/notify.nix` must have zero KDE/Plasma coupling; desktop subscriber activation lives strictly in `modules/plasma.nix`.
- `pkgs/fleet-notify` uses Python 3 stdlib only (no third-party runtime Python packages) and sets `doCheck = true` running `pytest`.
- Ports in `data/ports.nix`: add `ntfy = { internal = 2586; tailscale = 2587; }` and remove `autoUpdate.internal = 9105`.
- `ntfy-sh` on `zita` uses static system user/group `ntfy-sh` (`DynamicUser = lib.mkForce false; PrivateUsers = lib.mkForce false;`) and persists `/var/lib/ntfy-sh` via `impermanence.directories`.
- `upstream-base-url` is omitted (Android direct connection over Tailscale/LAN; no external `ntfy.sh` relay).
- Notification failures must never fail `nixos-auto-update`, `nixos-boot-verify`, or `smartd` (`--best-effort` exits `0` after logging warning to stderr).
- All Nix files pass `alejandra --check .` and `statix check .`; all Bash scripts pass `shellcheck` and `shfmt -d -i 2 -ci`.

## Review Focus

1. **Missing/unreadable token file (pre-bootstrap or permissions):** `fleet-notify --best-effort` logs a clear warning without leaking secrets and exits `0`; without `--best-effort` it exits `1`; `fleet-notify-desktop` retries cleanly instead of crashing in a tight loop. *(Pinned in Tasks 1 & 2)*
2. **HTTP 4xx auth error vs 5xx/network failure:** `fleet-notify` fails fast on 4xx (no retry spam across URLs, never echoes bearer token); retries once per URL on transient 5xx/network errors and falls back to the next configured URL. *(Pinned in Task 1)*
3. **Corrupt cursor file, non-message SSE frames, and hung `notify-send`:** `fleet-notify-desktop` recovers from corrupt `cursor.json` (`since=10m`), ignores `open`/`keepalive`/`poll_request` events, deduplicates by `id`, persists cursor atomically (`0600`), and enforces a timeout on `notify-send`. *(Pinned in Task 2)*
4. **`auto-update` dedup, recovery, and single-alert crash handling:** `write-status.sh` suppresses duplicate same-day `reboot_required_attended` notices, notifies once on non-healthy → `healthy` recovery, stays silent on `healthy` → `healthy`, and `auto-update.sh` / `boot-verify.sh` fire exactly one alert on both handled and unhandled failures without duplicating via `OnFailure=`. *(Pinned in Task 4)*
5. **`smartd` single `-M exec` guarantee & pre-bootstrap `ntfy-sh` safety:** `modules/smartd.nix` disables nixpkgs' built-in `wall`/`mail`/`x11` hooks when `fleetNotify` is active so `smartd.conf` never gets duplicate `-M exec`; `modules/notify.nix` guards `auth-access` on `environmentFile != null` and `hosts/zita/default.nix` gates `notify.server.enable` + canary on `hasNtfyServerEnv`. *(Pinned in Tasks 3, 4 & 5)*

---

## File Structure

- **Create:**
  - `pkgs/fleet-notify/fleet_notify.py` — Publisher CLI (`fleet-notify`) + systemd `--unit` failure reporter.
  - `pkgs/fleet-notify/fleet_notify_desktop.py` — Long-running `ntfy` NDJSON SSE subscriber → `notify-send`.
  - `pkgs/fleet-notify/test_fleet_notify.py` — Unit tests for both publisher and desktop subscriber.
  - `pkgs/fleet-notify/default.nix` — Derivation installing `fleet-notify` & `fleet-notify-desktop` with `doCheck = true`.
  - `modules/notify.nix` — Desktop-agnostic `notify.server` (`ntfy-sh`) and `notify.client` (`fleet-notify`, `fleet-notify@.service`, `onFailureUnits`).
  - `docs/howto/fleet-notify.md` — Secret bootstrap, Android app setup, Beszel loopback `ntfy://` setup, and developer wiring guide.
- **Modify:**
  - `data/ports.nix` — Add `ntfy = { internal = 2586; tailscale = 2587; }`; remove `autoUpdate`.
  - `modules/plasma.nix` — Wire `fleet-notify-desktop` Home Manager user service per Plasma user.
  - `modules/auto-update.nix` — Remove `statusServer` and `desktopNotifications`; pass `fleet-notify` into `writeStatusScript`.
  - `pkgs/auto-update/write-status.sh` — Publish actionable transitions + same-day dedup + recovery via `fleet-notify --best-effort`.
  - `pkgs/auto-update/auto-update.sh` — Add `STATUS_REPORTED` guard + fallback `EXIT` trap for unhandled failures.
  - `pkgs/auto-update/boot-verify.sh` — Report attended-reboot post-boot canary failure via `write-status.sh`.
  - `modules/smartd.nix` — Add `notifications.fleetNotify` using `-m <nomailer> -M exec` and disabling nixpkgs' conflicting built-in hooks.
  - `hosts/configuration.nix` — Enable `notify.client` fleet-wide and wire guarded `fleet-notify-pub-token` (`0440 root:wheel`).
  - `hosts/common/workstation.nix` — Remove `auto-update.desktopNotifications.enable`; wire guarded `fleet-notify-sub-token` (`0440 root:users`).
  - `hosts/zita/default.nix` — Enable gated `notify.server`, Caddy vhosts (`notify.benway.me` + `:2587`), firewall port `2587`, loopback client URL, `onFailureUnits`, and gated `ntfy-sh` canary.
  - `hosts/michael/dns.nix` — Add `cname=notify.benway.me,zita.skylab.home`.
  - `hosts/michael/default.nix` — Wire `notify.client.onFailureUnits = ["pihole-ftl" "unbound"]`.
  - `.github/workflows/ci.yml` — Remove deleted `pkgs/auto-update/desktop-notify.sh` from `shellcheck` & `shfmt` commands.
  - `docs/howto/beszel-hermes-prompt.md` — Switch Beszel alerting to direct loopback `ntfy://` and keep Hermes read-only via `beszel-query`.
  - `docs/index.md` — Add link to `docs/howto/fleet-notify.md`.
- **Delete:**
  - `pkgs/auto-update/status-server.py`
  - `pkgs/auto-update/desktop-notify.sh`

---

### Task 1: Publisher CLI (`pkgs/fleet-notify/fleet_notify.py`)

**Files:**
- Create: `pkgs/fleet-notify/fleet_notify.py`
- Create: `pkgs/fleet-notify/test_fleet_notify.py`

**Interfaces:**
- Consumes: `/etc/fleet-notify/config.json` schema: `{"host": str, "urls": list[str], "defaultTopic": str, "desktopTopics": list[str], "publishTokenFile": str | None, "subscribeTokenFile": str | None}`.
- Produces:
  - `load_config(path: Path) -> NotifyConfig`
  - `read_token(path: str | None) -> str`
  - `parse_priority(raw: str | int) -> int` (maps `min/1..urgent/5` → `1..5`)
  - `publish_message(cfg: NotifyConfig, token: str, *, topic: str, title: str, message: str, priority: int = 3, tags: list[str] | None = None, click: str | None = None, markdown: bool = False, opener=...) -> None`
  - `collect_unit_failure(unit: str, host: str, runner=...) -> tuple[str, str]`
  - `main(argv: list[str] | None = None) -> int`

- [ ] **Step 1: Write failing tests for publisher CLI in `pkgs/fleet-notify/test_fleet_notify.py`**

```python
def test_publish_json_payload_and_bearer_header(tmp_path):
    # Sends POST to base_url with Content-Type: application/json,
    # Authorization: Bearer tk_pub123, and UTF-8 JSON body containing
    # topic, title, message, priority (int 1..5), tags (list), click, markdown.
    ...

def test_publish_retries_transient_5xx_and_falls_back_to_second_url(tmp_path):
    # URL 1 returns 503 twice (initial + 1 retry), URL 2 returns 200 -> succeeds.
    ...

def test_publish_fails_fast_on_401_and_never_echoes_token(tmp_path, capsys):
    # URL 1 returns 401 -> does NOT retry URL 1 or hit URL 2;
    # stderr/exception never contains "tk_supersecret".
    ...

def test_missing_token_file_best_effort_vs_strict(tmp_path, capsys):
    # Missing publishTokenFile: --best-effort exits 0 with stderr warning;
    # without --best-effort exits 1.
    ...

def test_unit_failure_mode_collects_systemctl_and_journal_tail(tmp_path):
    # --unit caddy.service invokes systemctl show + journalctl -n 15,
    # publishes to fleet-alerts with priority=4, tags=["rotating_light", "gear"],
    # title="[zita] Service failed: caddy.service", body includes result + journal lines.
    ...

def test_stdin_message_and_priority_aliases(tmp_path):
    # parse_priority("urgent") == 5, parse_priority("low") == 2, invalid raises ConfigError;
    # --stdin reads message from sys.stdin.
    ...
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix shell nixpkgs#python3Packages.pytest -c pytest pkgs/fleet-notify/test_fleet_notify.py -v`
Expected: FAIL (`ModuleNotFoundError: No module named 'fleet_notify'`).

- [ ] **Step 3: Implement `pkgs/fleet-notify/fleet_notify.py`**

Implement `NotifyConfig`, `ConfigError`, `PublishError`, `load_config`, `read_token`, `parse_priority`, `publish_message`, `collect_unit_failure`, `build_arg_parser`, and `main`:
- Publish using `ntfy`'s JSON endpoint (`POST <base_url>` with `json.dumps(payload).encode("utf-8")`, `Content-Type: application/json`, `Authorization: Bearer <token>`).
- Per URL: 5s timeout, 1 retry on `URLError` / `TimeoutError` / HTTP 5xx (429 included); immediate raise of `PublishError` on HTTP 4xx (excluding 429) without trying remaining URLs.
- Never include `token` in any raised error message or log line.
- Default config path: `os.environ.get("FLEET_NOTIFY_CONFIG", "/etc/fleet-notify/config.json")`.
- `--best-effort`: catch `ConfigError`/`PublishError`/`OSError`, print sanitized warning to `sys.stderr`, return `0`.

- [ ] **Step 4: Run tests to verify all Task 1 tests pass**

Run: `nix shell nixpkgs#python3Packages.pytest -c pytest pkgs/fleet-notify/test_fleet_notify.py -v && rm -rf pkgs/fleet-notify/__pycache__ .pytest_cache`
Expected: All 6 tests PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git add pkgs/fleet-notify/fleet_notify.py pkgs/fleet-notify/test_fleet_notify.py
git commit -m "feat(notify): add fleet-notify stdlib Python publisher CLI and tests"
```

---

### Task 2: Desktop SSE Subscriber (`pkgs/fleet-notify/fleet_notify_desktop.py`) & Package (`default.nix`)

**Files:**
- Create: `pkgs/fleet-notify/fleet_notify_desktop.py`
- Create: `pkgs/fleet-notify/default.nix`
- Modify: `pkgs/fleet-notify/test_fleet_notify.py`

**Interfaces:**
- Consumes: `load_config`, `read_token`, `NotifyConfig` from `fleet_notify.py`.
- Produces:
  - `load_cursor(path: Path) -> dict[str, Any]`
  - `save_cursor(path: Path, last_id: str, last_time: int) -> None` (atomic `0600`)
  - `priority_to_urgency(priority: int) -> str` (`>= 4` → `"critical"`, `3` → `"normal"`, `<= 2` → `"low"`)
  - `tags_to_icon(tags: list[str]) -> str` (`rotating_light`/`warning`/`x` → `"dialog-error"`, `arrows_counterclockwise` → `"system-reboot"`, `cd`/`floppy_disk` → `"drive-harddisk"`, default `"dialog-information"`)
  - `dispatch_notification(event: dict[str, Any], runner=...) -> bool` (invokes `notify-send --app-name=NixOS Fleet --urgency=... --icon=... -- <title> <message>` with 10s timeout)
  - `process_stream(lines: Iterable[bytes | str], cursor_path: Path, seen_id: str | None, dispatch_fn=...) -> str | None`
  - `build_stream_url(base_url: str, topics: list[str], since: str) -> str`
  - Nix derivation `pkgs/fleet-notify/default.nix` exposing `$out/bin/fleet-notify` and `$out/bin/fleet-notify-desktop` with `libnotify` on `PATH` and `doCheck = true`.

- [ ] **Step 1: Write failing tests for desktop SSE subscriber in `pkgs/fleet-notify/test_fleet_notify.py`**

```python
def test_stream_ignores_non_message_events_dedups_and_persists_0600_cursor(tmp_path):
    # Feed open, keepalive, message(id="m1"), duplicate message(id="m1"),
    # message(id="m2"), poll_request -> dispatches only m1 and m2;
    # cursor file has mode 0600 and last_id == "m2".
    ...

def test_corrupt_cursor_file_falls_back_to_10m_since(tmp_path):
    # Corrupt JSON in cursor.json -> load_cursor returns {}, stream URL uses since=10m.
    ...

def test_priority_urgency_and_tag_icon_mapping():
    # 5/4 -> critical, 3 -> normal, 2/1 -> low;
    # rotating_light -> dialog-error, arrows_counterclockwise -> system-reboot,
    # cd -> drive-harddisk, [] -> dialog-information.
    ...

def test_dispatch_notification_passes_double_dash_and_handles_timeout(monkeypatch):
    # Verifies ["--", title, message] prevents flag injection from leading hyphens
    # in title/message, and TimeoutExpired returns False without crashing loop.
    ...

def test_missing_subscribe_token_sleeps_with_backoff_without_crashing(tmp_path):
    # Missing subscribeTokenFile triggers controlled backoff wait (does not raise unhandled).
    ...
```

- [ ] **Step 2: Run tests to verify new tests fail**

Run: `nix shell nixpkgs#python3Packages.pytest -c pytest pkgs/fleet-notify/test_fleet_notify.py -v`
Expected: FAIL (`ModuleNotFoundError: No module named 'fleet_notify_desktop'`).

- [ ] **Step 3: Implement `pkgs/fleet-notify/fleet_notify_desktop.py` and `pkgs/fleet-notify/default.nix`**

- `fleet_notify_desktop.py`:
  - Uses `urllib.request.urlopen` streaming NDJSON lines from `<base_url>/<",".join(topics)>/json?since=<last_id or "10m">` with `Authorization: Bearer <sub_token>` and `timeout=70` (slightly above `ntfy`'s `45s` `keepalive-interval` so silent TCP drops are detected promptly!).
  - Persists cursor atomically (`0600`) to `${XDG_STATE_HOME:-~/.local/share}/fleet-notify/cursor.json` after each dispatched message (and on corrupt JSON, logs warning and falls back to `since=10m`).
  - Rotates across `cfg.urls` with exponential backoff (`2s` → `60s`, reset to `2s` after receiving valid stream data).
  - Installs `SIGTERM`/`SIGINT` handlers for clean exit (`0`).
- `pkgs/fleet-notify/default.nix`:
  - Builds with `pkgs.stdenvNoCC.mkDerivation`, `doCheck = true` running `pytest test_fleet_notify.py -v`, installs `fleet_notify.py` and `fleet_notify_desktop.py` to `$out/libexec/fleet-notify/`, and creates `makeWrapper` entrypoints `$out/bin/fleet-notify` (with `systemd` on `PATH` for `--unit`) and `$out/bin/fleet-notify-desktop` (with `libnotify` on `PATH`).

- [ ] **Step 4: Run unit tests and build Nix derivation**

Run:
```bash
nix shell nixpkgs#python3Packages.pytest -c pytest pkgs/fleet-notify/test_fleet_notify.py -v && rm -rf pkgs/fleet-notify/__pycache__ .pytest_cache
nix build --impure --no-link --print-out-paths --expr 'let f = builtins.getFlake ("path:" + toString ./.); pkgs = f.nixosConfigurations.francis.pkgs; in import ./pkgs/fleet-notify { inherit pkgs; }'
```
Expected: All 11 tests PASS and Nix build outputs `/nix/store/...-fleet-notify-0.1.0` cleanly.

- [ ] **Step 5: Commit Task 2**

```bash
git add pkgs/fleet-notify/fleet_notify_desktop.py pkgs/fleet-notify/default.nix pkgs/fleet-notify/test_fleet_notify.py
git commit -m "feat(notify): add fleet-notify-desktop SSE subscriber and Nix package"
```

---

### Task 3: Fleet Bus Module (`modules/notify.nix`), Ports (`data/ports.nix`), & KDE Integration (`modules/plasma.nix`)

**Files:**
- Modify: `data/ports.nix`
- Create: `modules/notify.nix`
- Modify: `modules/plasma.nix`

**Interfaces:**
- Consumes: `pkgs/fleet-notify` derivation (`bin/fleet-notify`, `bin/fleet-notify-desktop`), `data/ports.nix` (`ports.ntfy.internal` = `2586`, `ports.ntfy.tailscale` = `2587`).
- Produces:
  - `options.notify.server.{enable, domain, port, tailscalePort, dataDir, environmentFile, cacheDuration, extraAccess, extraSettings}`
  - `options.notify.client.{enable, urls, publishTokenFile, subscribeTokenFile, defaultTopic, desktopTopics, onFailureUnits, package}`
  - `systemd.services."fleet-notify@"` template unit
  - `/etc/fleet-notify/config.json` (non-secret)
  - `home-manager.users.<user>.systemd.user.services.fleet-notify-desktop` (defined strictly inside `modules/plasma.nix`).

- [ ] **Step 1: Update `data/ports.nix`**

Add `ntfy = { internal = 2586; tailscale = 2587; };` under `# Web & Application Services` (leave `autoUpdate` removal for Task 4 so `modules/auto-update.nix` continues evaluating between Tasks 3 and 4).

- [ ] **Step 2: Create `modules/notify.nix`**

Implement `options.notify.server` and `options.notify.client` per Spec §5.4:
- Static `ntfy-sh` user/group (`DynamicUser = lib.mkForce false; PrivateUsers = lib.mkForce false;`), `after`/`wants` on `dataDirMountUnit` when `config.impermanence.enable`, `impermanence.directories = [cfgServer.dataDir]`, `systemd.tmpfiles.rules`.
- Guard `auth-access` in `services.ntfy-sh.settings` on `cfgServer.environmentFile != null` (so pre-bootstrap `ntfy-sh` never references undefined users).
- `notify.client` writes `/etc/fleet-notify/config.json`, adds `fleetNotifyPkg` to `environment.systemPackages`, defines `systemd.services."fleet-notify@"` (`Type = "oneshot"`, `ExecStart = "${fleetNotifyPkg}/bin/fleet-notify --best-effort --unit %i"`), and wires `unitConfig.OnFailure = lib.mkAfter ["fleet-notify@%n.service"]` for each name in `cfgClient.onFailureUnits`.
- Verify zero references to `plasma`, `kde`, or `home-manager` in `modules/notify.nix`.

- [ ] **Step 3: Wire KDE Plasma subscriber in `modules/plasma.nix`**

Inside `home-manager.users = lib.mapAttrs (user: userConfig: { ... }) config.plasma.users`, add:
```nix
systemd.user.services.fleet-notify-desktop = lib.mkIf (config.notify.client.enable && config.notify.client.subscribeTokenFile != null) {
  Unit = {
    Description = "Stream fleet ntfy alerts to KDE Plasma notifications";
    After = ["graphical-session.target" "network-online.target"];
    PartOf = ["graphical-session.target"];
    ConditionPathExists = toString config.notify.client.subscribeTokenFile;
  };
  Service = {
    Type = "simple";
    ExecStart = "${config.notify.client.package}/bin/fleet-notify-desktop";
    Restart = "always";
    RestartSec = "5s";
  };
  Install = {
    WantedBy = ["graphical-session.target"];
  };
};
```

- [ ] **Step 4: Verify formatting, linting, and Nix evaluation**

Run:
```bash
git add -N modules/notify.nix
alejandra --check . && statix check .
nix eval .#nixosConfigurations.francis.config.system.build.toplevel.drvPath
nix eval .#nixosConfigurations.zita.config.system.build.toplevel.drvPath
```
Expected: All pass with 0 errors.

- [ ] **Step 5: Commit Task 3**

```bash
git add data/ports.nix modules/notify.nix modules/plasma.nix
git commit -m "feat(notify): add desktop-agnostic notify bus module and Plasma subscriber"
```

---

### Task 4: Producer Integrations (`auto-update`, `smartd`, & CI Shell Lint)

**Files:**
- Modify: `modules/auto-update.nix`
- Modify: `pkgs/auto-update/write-status.sh`
- Modify: `pkgs/auto-update/auto-update.sh`
- Modify: `pkgs/auto-update/boot-verify.sh`
- Delete: `pkgs/auto-update/status-server.py`
- Delete: `pkgs/auto-update/desktop-notify.sh`
- Modify: `data/ports.nix` (remove `autoUpdate = { internal = 9105; };`)
- Modify: `hosts/common/workstation.nix` (remove `auto-update.desktopNotifications.enable = true;`)
- Modify: `modules/smartd.nix`
- Modify: `.github/workflows/ci.yml` (remove `pkgs/auto-update/desktop-notify.sh` from `shellcheck` & `shfmt`)

**Interfaces:**
- Consumes: `config.notify.client.{enable, package}` and `fleet-notify --best-effort ...` CLI.
- Produces:
  - `write-status.sh` publishing actionable transitions + same-day dedup (`lastNotifiedDate`) + non-healthy→healthy recovery.
  - `auto-update.sh` single-alert `EXIT` trap (`STATUS_REPORTED` guard) + `boot-verify.sh` attended-reboot canary failure reporting.
  - `options.smartd.notifications.fleetNotify` (default `config.notify.client.enable`) with clean single `-M exec` in `smartd.conf`.

- [ ] **Step 1: Update `pkgs/auto-update/write-status.sh`, `auto-update.sh`, and `boot-verify.sh`**

- `write-status.sh`:
  - Read `PREV_STATUS`, `PREV_SUMMARY`, `PREV_NOTIFIED_DATE` from existing `$STATUS_FILE` safely (`jq ... 2>/dev/null || echo ""`).
  - Determine whether to notify (`SHOULD_NOTIFY`, `TOPIC`, `PRIORITY`, `TAGS`) per Spec §5.7.1:
    - `update_failed` / `rollback_failed` → `fleet-alerts`, `urgent`, `rotating_light,nix` (always notify).
    - `reboot_required_attended` → `fleet-alerts`/`high`/`warning,arrows_counterclockwise` if `severity == "critical"`, else `fleet-updates`/`default`/`arrows_counterclockwise`; skip if `PREV_STATUS == STATUS && PREV_SUMMARY == SUMMARY && PREV_NOTIFIED_DATE == TODAY`.
    - `reboot_scheduled` → `fleet-updates`, `low`, `clock3` (skip if same-day duplicate).
    - `healthy` → notify ONLY if `PREV_STATUS` was one of `update_failed`, `rollback_failed`, `reboot_required_attended`, `reboot_scheduled` → `fleet-updates`, `low`, `white_check_mark`.
  - Write `lastNotifiedDate` into `status.json` (preserving `PREV_NOTIFIED_DATE` when deduped, updating to `$TODAY` when notified).
  - If `SHOULD_NOTIFY == true` and `command -v fleet-notify >/dev/null 2>&1`: call `fleet-notify --best-effort --topic "$TOPIC" --priority "$PRIORITY" --tags "$TAGS" --title "[${HOST_NAME}] ${SUMMARY}" "${DETAILS:-${SUMMARY}}"`.
- `auto-update.sh`:
  - Add `STATUS_REPORTED=false` wrapper helper `report_status() { STATUS_REPORTED=true; nixos-auto-update-write-status "$@"; }`.
  - Update `trap` to run both `cleanup_staged_leaf` and, if exit code `$rc -ne 0 && "$STATUS_REPORTED" != "true"`, call `nixos-auto-update-write-status "update_failed" "critical" "Auto-update exited unexpectedly on ${HOST_NAME} (exit ${rc})" "Inspect journalctl -u nixos-auto-update on ${HOST_NAME}."`.
- `boot-verify.sh`:
  - In the canary failure branch (lines 29–41), also call `nixos-auto-update-write-status "update_failed" "critical" "${HOST_NAME} failed post-boot canary check after attended reboot" "Post-boot canary failed on $(readlink -f /run/booted-system)."` when `PENDING_BOOT_FILE` is absent before `exit 1`.

- [ ] **Step 2: Clean up `modules/auto-update.nix`, `data/ports.nix`, `hosts/common/workstation.nix`, `.github/workflows/ci.yml`, and delete retired scripts**

- Remove `statusServerScript`, `desktopNotifyScript`, `options.auto-update.statusServer`, `options.auto-update.desktopNotifications`, and their systemd/firewall blocks from `modules/auto-update.nix`; add `lib.optional (config.notify.client.enable or false) config.notify.client.package` to `writeStatusScript.runtimeInputs`.
- Remove `autoUpdate` from `data/ports.nix` and `desktopNotifications.enable = true` from `hosts/common/workstation.nix`.
- Delete `pkgs/auto-update/status-server.py` and `pkgs/auto-update/desktop-notify.sh`.
- Remove `pkgs/auto-update/desktop-notify.sh` from `.github/workflows/ci.yml` lines 73 & 76.

- [ ] **Step 3: Wire `modules/smartd.nix` to `fleet-notify`**

- Add `options.smartd.notifications.fleetNotify` (`bool`, default `config.notify.client.enable or false`) and default `notifications.wall` to `!cfg.notifications.fleetNotify`.
- When `cfg.notifications.fleetNotify` is enabled:
  - Create `smartdNotifyScript` (`pkgs.writeShellApplication` with `fleet-notify` + optional `util-linux` for `wall`) calling `fleet-notify --best-effort --topic fleet-alerts --priority high --tags warning,cd --title "[${hostname}] SMART: ${SMARTD_FAILTYPE:-Alert} (${SMARTD_DEVICE:-disk})" "${SMARTD_FULLMESSAGE:-${SMARTD_MESSAGE:-SMART warning}}"`.
  - Set `services.smartd.notifications.{wall,mail,x11}.enable = false;` so nixpkgs' `notifyOpts` is empty, and prepend `"-m <nomailer> -M exec ${smartdNotifyScript}/bin/smartd-fleet-notify"` to `defaultOpts`.

- [ ] **Step 4: Write/run behavioral tests for `write-status.sh` and lint all scripts & Nix**

Run:
- Quick automated verification script (in `pytest` inside `pkgs/fleet-notify/test_fleet_notify.py` or bash smoke test) exercising `write-status.sh` with a mock `fleet-notify` on `PATH`:
  1. `healthy` → `healthy` emits 0 notifications
  2. `update_failed` emits 1 urgent notification to `fleet-alerts`
  3. `reboot_required_attended` emits 1 notification on first call, 0 on same-day repeat
  4. `healthy` after `reboot_required_attended` emits 1 recovery notification to `fleet-updates`
- `nix run nixpkgs#shellcheck -- pkgs/auto-update/auto-update.sh pkgs/auto-update/boot-verify.sh pkgs/auto-update/canary.sh pkgs/auto-update/write-status.sh`
- `nix run nixpkgs#shfmt -- -d -i 2 -ci pkgs/auto-update/auto-update.sh pkgs/auto-update/boot-verify.sh pkgs/auto-update/canary.sh pkgs/auto-update/write-status.sh`
- `alejandra --check . && statix check .`
- Verify `smartd.conf` generated for `francis` has exactly one `-M exec` per `DEFAULT`/`DEVICESCAN` line (`nix eval --raw` on `systemd.services.smartd.serviceConfig.ExecStart` + inspect referenced `smartd.conf` after Task 5 enables `notify.client`).

- [ ] **Step 5: Commit Task 4**

```bash
git add modules/auto-update.nix modules/smartd.nix data/ports.nix hosts/common/workstation.nix .github/workflows/ci.yml pkgs/auto-update/
git commit -m "feat(notify): wire auto-update and smartd to fleet bus and retire legacy polling"
```

---

### Task 5: Fleet Host Wiring & Documentation

**Files:**
- Modify: `hosts/configuration.nix`
- Modify: `hosts/common/workstation.nix`
- Modify: `hosts/zita/default.nix`
- Modify: `hosts/michael/dns.nix`
- Modify: `hosts/michael/default.nix`
- Create: `docs/howto/fleet-notify.md`
- Modify: `docs/howto/beszel-hermes-prompt.md`
- Modify: `docs/index.md`

**Interfaces:**
- Consumes: `options.notify.server`, `options.notify.client`, `data/ports.nix` (`ports.ntfy`).
- Produces: All 5 hosts (`zita`, `michael`, `francis`, `agnes`, `jerome`) wired cleanly, guarded by `builtins.pathExists` on all 3 secrets, plus complete runbook docs.

- [ ] **Step 1: Wire fleet-wide client & workstations**

- `hosts/configuration.nix`:
  - Guard `secrets/fleet-notify-pub.token.age` with `builtins.pathExists` → `age.secrets.fleet-notify-pub-token` (`name = "fleet-notify-pub.token"`, `mode = "0440"`, `owner = "root"`, `group = "wheel"`).
  - Set `notify.client = { enable = true; publishTokenFile = lib.mkIf hasFleetNotifyPubToken config.age.secrets.fleet-notify-pub-token.path; };`.
- `hosts/common/workstation.nix`:
  - Guard `secrets/fleet-notify-sub.token.age` with `builtins.pathExists` → `age.secrets.fleet-notify-sub-token` (`name = "fleet-notify-sub.token"`, `mode = "0440"`, `owner = "root"`, `group = "users"`).
  - Set `notify.client.subscribeTokenFile = lib.mkIf hasFleetNotifySubToken config.age.secrets.fleet-notify-sub-token.path;`.

- [ ] **Step 2: Wire `zita` server & `michael` DNS / `onFailureUnits`**

- `hosts/zita/default.nix`:
  - Guard `secrets/ntfy-server.env.age` with `builtins.pathExists` → `age.secrets.ntfy-server-env` (`name = "ntfy-server.env"`, `mode = "0400"`, `owner = "ntfy-sh"`, `group = "ntfy-sh"`).
  - Enable `notify.server` gated on `hasNtfyServerEnv` (`domain = "notify.benway.me"`, `environmentFile = config.age.secrets.ntfy-server-env.path`).
  - Set `notify.client = { urls = ["http://127.0.0.1:${toString ports.ntfy.internal}" "https://notify.benway.me" "https://zita.${config.tailscale.tailnet}:${toString ports.ntfy.tailscale}"]; onFailureUnits = ["caddy" "beszel-hub" "vaultwarden" "forgejo"]; };`.
  - Add `ports.ntfy.tailscale` to `networking.firewall.allowedTCPPorts`, add Caddy vhosts for `notify.benway.me` and `${hostname}.${config.tailscale.tailnet}:${toString ports.ntfy.tailscale}`, and append `lib.optional hasNtfyServerEnv "ntfy-sh"` to `auto-update.canary.services`.
- `hosts/michael/dns.nix`: add `"cname=notify.benway.me,zita.skylab.home"`.
- `hosts/michael/default.nix`: set `notify.client.onFailureUnits = ["pihole-ftl" "unbound"];`.

- [ ] **Step 3: Write `docs/howto/fleet-notify.md` and update `docs/howto/beszel-hermes-prompt.md` & `docs/index.md`**

- Verify Beszel's Shoutrrr `ntfy://` query parameter syntax against nixpkgs' `beszel` binary/source before documenting the exact URL (`scheme=http` vs `disabletls=yes`) in both `docs/howto/fleet-notify.md` and `docs/howto/beszel-hermes-prompt.md`.
- Document one-time secret bootstrap (`ntfy user hash`, `agenix -e` for the 3 `.age` files + `agenix-rules.nix`), Android `ntfy` app setup, Beszel Hub notification URL, and how future modules/desktops plug into `modules/notify.nix`.
- Add `docs/howto/fleet-notify.md` to `docs/index.md`.

- [ ] **Step 4: Run full validation across all 5 hosts**

Run:
```bash
alejandra --check .
statix check .
nix run nixpkgs#shellcheck -- scripts/build_iso scripts/install_host scripts/generate_syncthing_keys scripts/deploy_host scripts/reboot_host scripts/sync_agent pkgs/auto-update/auto-update.sh pkgs/auto-update/boot-verify.sh pkgs/auto-update/canary.sh pkgs/auto-update/write-status.sh pkgs/disk-health/disk-health.sh
nix run nixpkgs#shfmt -- -d -i 2 -ci scripts/build_iso scripts/install_host scripts/generate_syncthing_keys scripts/deploy_host scripts/reboot_host scripts/sync_agent pkgs/auto-update/auto-update.sh pkgs/auto-update/boot-verify.sh pkgs/auto-update/canary.sh pkgs/auto-update/write-status.sh pkgs/disk-health/disk-health.sh
nix run nixpkgs#actionlint
nix build --impure --no-link --print-out-paths --expr 'let f = builtins.getFlake ("path:" + toString ./.); pkgs = f.nixosConfigurations.francis.pkgs; in import ./pkgs/fleet-notify { inherit pkgs; }'
for h in agnes francis jerome michael zita; do
  echo "=== eval $h ==="
  nix eval ".#nixosConfigurations.${h}.config.system.build.toplevel.drvPath"
done
```
Expected: Every linter, sandboxed package build (11+ pytest passing), and all 5 host evaluations succeed with 0 errors. Also verify `smartd.conf` contains exactly one `-M exec` per directive and that `zita`/`michael` do NOT evaluate `fleet-notify-sub-token` or `fleet-notify-desktop`.

- [ ] **Step 5: Commit Task 5**

```bash
git add hosts/configuration.nix hosts/common/workstation.nix hosts/zita/default.nix hosts/michael/dns.nix hosts/michael/default.nix docs/howto/fleet-notify.md docs/howto/beszel-hermes-prompt.md docs/index.md
git commit -m "feat(hosts): wire fleet notification bus across hosts and add docs"
```
