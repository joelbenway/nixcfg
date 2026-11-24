---
type: spec
title: "Fleet-Wide Notification Bus (ntfy + Desktop Subscribers)"
description: "Design specification for a desktop-agnostic fleet notification bus module backed by self-hosted ntfy-sh on zita, with KDE Plasma subscriber integration in modules/plasma.nix and unified producers for auto-update, smartd, Beszel, and systemd OnFailure."
status: draft
owner: joel
timestamp: "2026-11-24"
tags:
  - spec
  - notifications
  - ntfy
  - fleet
  - plasma
  - auto-update
  - beszel
  - smartd
---

# Fleet-Wide Notification Bus Design

## 1. Intent & Why

Today, fleet notifications in `nixcfg` are split across three incompatible mechanisms:

1. **`auto-update`** (`modules/auto-update.nix`): Each host runs a Python HTTP server on port `9105` serving `/var/lib/nixos-auto-update/status.json`; KDE Plasma workstations poll all 5 hosts every 30 minutes (`fleet-health-notify.timer`) and call `notify-send`. Alerts never reach Joel's phone, lag by up to 30 minutes, miss offline hosts, and keep no history.
2. **`beszel`** (`modules/beszel.nix`): Beszel Hub on `zita` fires Shoutrrr webhooks to Hermes Agent (`127.0.0.1:8644`) for AI triage into Signal. Alerts don't appear as native desktop notifications and stop working if Hermes or external LLM APIs are unavailable.
3. **`smartd`** (`modules/smartd.nix`): Active drive self-test failures broadcast via `wall` (invisible on headless servers and GUI desktops) and NixOS defaults enable `xmessage` on X11 hosts.

We want a **single, fleet-wide notification bus module (`modules/notify.nix`)** backed by self-hosted **`ntfy-sh`** on `zita` that any NixOS module or user script can publish to, delivering instantaneously to:
- **Android phone** via the official `ntfy` app over Tailscale/LAN.
- **Workstation desktops** via a lightweight SSE subscriber (`fleet-notify-desktop`) wired inside each desktop module (`modules/plasma.nix` today) so `modules/notify.nix` remains completely desktop-agnostic and future workstations can run different desktops cleanly.

---

## 2. Goals, Non-Goals & Anti-Goals

### Goals
- **Reusable fleet bus (`modules/notify.nix`):**
  - `notify.server` on `zita`: declarative `services.ntfy-sh` behind Caddy (`notify.benway.me` + Tailscale HTTPS port, LAN CNAME in `hosts/michael/dns.nix`), `auth-default-access: deny-all`, least-privilege `agenix` tokens.
  - `notify.client` enabled fleet-wide in `hosts/configuration.nix`: installs `fleet-notify` CLI, writes non-secret `/etc/fleet-notify/config.json`, exposes `fleet-notify@.service` (`OnFailure=` crash notifier template) and declarative `notify.onFailureUnits`, and exposes `notify.client.package` (`fleet-notify` + `fleet-notify-desktop`) for desktop modules.
- **Desktop-agnostic bus / desktop-owned subscriber:**
  - `modules/notify.nix` has **zero** KDE/Plasma imports or assumptions.
  - `modules/plasma.nix` wires `fleet-notify-desktop` as a Home Manager systemd user service for every Plasma user. Future desktop modules (e.g. Hyprland, GNOME, Niri, Sway) can reuse `config.notify.client.package/bin/fleet-notify-desktop` or wire their own consumer independently.
- **Unify existing producers:**
  - `auto-update`: `write-status.sh` publishes actionable transitions directly via `fleet-notify` (retiring `status-server.py`, port `9105`, `nixos-auto-update-status.service`, and `desktop-notify.sh` / `fleet-health-notify.timer`).
  - `smartd`: replaces `wall`/`xmessage` with `-M exec` calling `fleet-notify` on disk faults and self-test failures.
  - `beszel`: pushes directly to `ntfy` over loopback (`ntfy://:tk_...@127.0.0.1:2586/fleet-alerts?...`) with zero LLM dependency; Hermes retains read-only `beszel-query` for on-demand Signal troubleshooting.
- **Secret safety & CI safety:** Zero secrets in the Nix store, CLI argv, logs, or public `nixcfg`; guarded with `builtins.pathExists` so headless hosts and GitHub Actions CI evaluate cleanly when private `.age` files are absent.
- **Tested package:** `pkgs/fleet-notify` built with `doCheck = true` running `pytest` unit tests.

### Non-Goals
- **iOS APNs relay:** Mobile client is Android over Tailscale/LAN, so `upstream-base-url` (`https://ntfy.sh`) is intentionally omitted (zero external relay traffic).
- **Hermes AI triage in the alert path:** Beszel alerts go directly to `ntfy`. Hermes keeps `beszel-query` on `zita` for interactive Signal queries when Joel wants deeper context.
- **Persistent offline spool daemon on roaming laptops:** `fleet-notify` does brief transient retries and logs failures cleanly; adding a per-host disk spool queue is deferred unless needed later.
- **Wiring other desktop environments now:** Only `modules/plasma.nix` wires `fleet-notify-desktop` in this change; the interface is kept desktop-agnostic for future desktop modules.

### Anti-Goals
- Never leak `ntfy` bearer tokens into `/nix/store`, process argv (`ps`), `/etc/fleet-notify/config.json`, or `journalctl`.
- Never let a notification failure abort `nixos-auto-update`, `nixos-boot-verify`, or `smartd` (`--best-effort` mode exits `0` after logging a warning to stderr).
- Never couple `modules/notify.nix` to `config.plasma.enable` or any KDE package.
- Never require headless servers (`zita`, `michael`) to decrypt desktop subscriber secrets.

---

## 3. Constraints

- **Public repo / private secrets:** `nixcfg` is public; all secrets live in the `secrets/` submodule (`joelbenway/nixos-secrets`) encrypted via `agenix`.
- **Host topology:**
  - Always-on servers: `zita` (media/services/Beszel Hub/Hermes/ntfy), `michael` (router/Pi-hole DNS/remote builder).
  - Workstations/laptops: `francis`, `agnes`, `jerome` (currently KDE Plasma 6 via `modules/plasma.nix`, may run other desktops in the future).
- **Networking & Caddy on `zita`:** Services bind to `127.0.0.1:<internal>` and are reverse-proxied by Caddy on both `<svc>.benway.me` (Cloudflare DNS-01 TLS + LAN CNAME on `michael`) and `zita.<tailnet>:<tailscale>` (Tailscale HTTPS).
- **Impermanence on `zita`:** `/var/lib/ntfy-sh` must be persisted via `impermanence.directories` with a static `ntfy-sh` user/group (overriding nixpkgs' `DynamicUser = true`, matching `modules/beszel.nix`) so impermanence mounts and `agenix` secret ownership (`0400 ntfy-sh:ntfy-sh`) work reliably without `/var/lib/private` permission conflicts.
- **Port registry (`data/ports.nix`):** All internal/Tailscale ports must be declared in `data/ports.nix` (collision-checked). `2586` (internal) and `2587` (Tailscale) are unused; `autoUpdate.internal = 9105` will be removed.
- **Nixpkgs versions:** `ntfy-sh` 2.37.2 (supports declarative `NTFY_AUTH_USERS`, `NTFY_AUTH_TOKENS`, and `auth-access` in `server.yml` + `environmentFile`), Python 3 stdlib only for `pkgs/fleet-notify`.

---

## 4. Approaches Considered

1. **Approach 1: Thin `ntfy` Bus Module (`modules/notify.nix`) + `fleet-notify` CLI + `OnFailure=` Template *(Selected)***
   - Uses NixOS `services.ntfy-sh` directly with zero custom server daemon. Provides a small stdlib Python package (`fleet-notify` publisher CLI + `fleet-notify-desktop` SSE subscriber) and a systemd `fleet-notify@.service` `OnFailure=` template. Desktop modules (`modules/plasma.nix`) opt into the desktop subscriber independently.
   - *Why selected:* Lowest maintenance, instant push to Android + KDE, clean separation between desktop-agnostic bus and desktop-specific consumers, trivial 1-line wiring for future services.
2. **Approach 2: `ntfy` Bus + Per-Host Offline Spool Daemon**
   - Same as Approach 1 plus `/var/lib/fleet-notify/spool/` and a drain timer on every host for hours-long offline queuing on roaming laptops.
   - *Trade-off:* Extra persistent directory and background unit on every host; unnecessary for now and easy to add behind the same `fleet-notify` CLI later if ever wanted.
3. **Approach 3: Custom Fleet Notification Router Daemon on `zita`**
   - Custom Python + SQLite + SSE server on `zita` doing centralized dedup, cooldowns, and Signal/Hermes fallback routing.
   - *Trade-off:* Unnecessary custom server maintenance once `ntfy + KDE` covers all required delivery channels.

---

## 5. Detailed Design

### 5.1 Ports & DNS

- **`data/ports.nix`:**
  - Add:
    ```nix
    ntfy = {
      internal = 2586;
      tailscale = 2587;
    };
    ```
  - Remove `autoUpdate = { internal = 9105; };` (no longer used once `status-server.py` is retired).
- **`hosts/michael/dns.nix`:**
  - Add LAN CNAME: `"cname=notify.benway.me,zita.skylab.home"`.
- **`hosts/zita/default.nix`:**
  - Add `ports.ntfy.tailscale` (`2587`) to `networking.firewall.allowedTCPPorts`.
  - Add Caddy virtual hosts for `notify.benway.me` (Cloudflare DNS-01 TLS → `127.0.0.1:2586`) and `${hostname}.${config.tailscale.tailnet}:2587` (→ `127.0.0.1:2586`).
  - Gate `notify.server.enable` and `"ntfy-sh"` in `auto-update.canary.services` on `hasNtfyServerEnv` (matching the existing `hasKmailSecret` / `hasBeszelHubEnv` pattern) so pre-bootstrap builds and CI never start `ntfy-sh` with `auth-access` referencing non-existent users.

### 5.2 Authentication, ACLs & Secrets (`secrets/` Submodule)

`ntfy-sh` enforces `auth-default-access: deny-all` with three least-privilege accounts declared via `NTFY_AUTH_USERS` + `NTFY_AUTH_TOKENS` (in `secrets/ntfy-server.env.age`) and non-secret `auth-access` rules in `server.yml`:

| User | Role | ACL (`auth-access`) | Purpose |
|---|---|---|---|
| `joel` | `admin` | `joel:*:rw` | Android `ntfy` app + ad-hoc admin / web UI |
| `fleet-pub` | `user` | `fleet-pub:fleet-*:wo` | Write-only publishing from all 5 hosts (`auto-update`, `smartd`, `OnFailure=`, `beszel`, interactive `wheel` users) |
| `fleet-sub` | `user` | `fleet-sub:fleet-*:ro` | Read-only SSE streaming for desktop sessions (`fleet-notify-desktop`) |

**Agenix secrets (all guarded by `builtins.pathExists` for CI safety):**
1. **`secrets/ntfy-server.env.age`** (encrypted for `[keys.hosts.zita] ++ admins`, `0400 ntfy-sh:ntfy-sh`, mounted on `zita` only):
   ```dotenv
   NTFY_AUTH_USERS=joel:<bcrypt-hash>:admin,fleet-pub:<bcrypt-hash>:user,fleet-sub:<bcrypt-hash>:user
   NTFY_AUTH_TOKENS=joel:tk_<admin_token>:phone,fleet-pub:tk_<pub_token>:fleet-hosts,fleet-sub:tk_<sub_token>:desktop-sessions
   ```
   *(Note: systemd `EnvironmentFile` does not expand `$` in values, so bcrypt `$2a$10$...` hashes pass through verbatim without escaping.)*
2. **`secrets/fleet-notify-pub.token.age`** (encrypted for `[keys.hosts.zita keys.hosts.michael keys.hosts.francis keys.hosts.agnes keys.hosts.jerome] ++ admins`, `0440 root:wheel`, declared in `hosts/configuration.nix`):
   - Raw single-line token `tk_<pub_token>` (readable by root services and `wheel` users).
3. **`secrets/fleet-notify-sub.token.age`** (encrypted for `[keys.hosts.francis keys.hosts.agnes keys.hosts.jerome] ++ admins`, `0440 root:users`, declared in `hosts/common/workstation.nix` so headless servers never decrypt it):
   - Raw single-line token `tk_<sub_token>` (readable by desktop user sessions).

### 5.3 Topic Taxonomy *(Our Call)*

Standardized `fleet-*` topics (covered by `fleet-pub:fleet-*:wo` and `fleet-sub:fleet-*:ro`):
- **`fleet-alerts`**: Actionable failures and critical issues (`auto-update` failures/rollbacks/TPM drift, `smartd` drive alerts, `beszel` infrastructure alerts, systemd `OnFailure=` crashes). Default priority `high` (`4`) or `urgent` (`5`).
- **`fleet-updates`**: Non-urgent operational updates (`auto-update` attended kernel reboot notices, scheduled reboots, post-failure/post-reboot recoveries). Default priority `default` (`3`) or `low` (`2`).
- Any future module can publish to `fleet-alerts`, `fleet-updates`, or any custom `fleet-<name>` topic without modifying `ntfy` ACLs.

### 5.4 Fleet Bus Module (`modules/notify.nix`)

Completely desktop-agnostic module defining `options.notify`:

- **`options.notify.server`:**
  - `enable` (`bool`, default `false`)
  - `domain` (`str`, default `"notify.benway.me"`)
  - `port` (`port`, default `ports.ntfy.internal` = `2586`)
  - `tailscalePort` (`port`, default `ports.ntfy.tailscale` = `2587`)
  - `dataDir` (`str`, default `"/var/lib/ntfy-sh"`)
  - `environmentFile` (`nullOr path`, default `null`)
  - `cacheDuration` (`str`, default `"72h"`)
  - `extraAccess` (`listOf str`, default `[]` — additional `auth-access` rules merged with the default three ACLs)
  - `extraSettings` (`attrsOf anything`, default `{}`)
  - Implementation:
    - Creates static system user/group `ntfy-sh` (`home = cfg.dataDir`).
    - Configures `services.ntfy-sh` with `base-url = "https://${cfg.domain}"`, `listen-http = "127.0.0.1:${toString cfg.port}"`, `behind-proxy = true`, `auth-default-access = "deny-all"`, `auth-file = "${cfg.dataDir}/user.db"`, `cache-file = "${cfg.dataDir}/cache.db"`, `cache-duration = cfg.cacheDuration`, `attachment-cache-dir = "${cfg.dataDir}/attachments"`, `enable-signup = false`, `enable-login = true`, `enable-metrics = false`, `keepalive-interval = "45s"`, and `auth-access` (guarded on `cfg.environmentFile != null` so `ntfy-sh` never fails startup referencing undefined users) set to `["joel:*:rw" "fleet-pub:fleet-*:wo" "fleet-sub:fleet-*:ro"] ++ cfg.extraAccess`.
    - Overrides `systemd.services.ntfy-sh.serviceConfig` to `DynamicUser = lib.mkForce false; PrivateUsers = lib.mkForce false; User = "ntfy-sh"; Group = "ntfy-sh";` and orders `after`/`wants` after `dataDirMountUnit` when `config.impermanence.enable`.
    - Registers `cfg.dataDir` in `impermanence.directories` and `systemd.tmpfiles.rules` (`d ${cfg.dataDir} 0750 ntfy-sh ntfy-sh -`).
    - Configures Caddy? *Builder call:* keep Caddy reverse proxy definitions in `hosts/zita/default.nix` alongside `files`/`budget`/`jellyfin`/`forgejo`/`vaultwarden`/`beszel` so all `zita` vhosts stay in one place.

- **`options.notify.client`:**
  - `enable` (`bool`, default `false`; enabled in `hosts/configuration.nix`)
  - `urls` (`listOf str`, default `["https://notify.benway.me" "https://zita.${tailnet}:${toString ports.ntfy.tailscale}"]`; on `zita`, prepend `"http://127.0.0.1:${toString ports.ntfy.internal}"`)
  - `publishTokenFile` (`nullOr (either path str)`, default `null`)
  - `subscribeTokenFile` (`nullOr (either path str)`, default `null`)
  - `defaultTopic` (`str`, default `"fleet-alerts"`)
  - `desktopTopics` (`listOf str`, default `["fleet-alerts" "fleet-updates"]`)
  - `onFailureUnits` (`listOf str`, default `[]` — list of systemd service names without `.service` suffix to automatically wire `OnFailure = ["fleet-notify@%n.service"]`)
  - `package` (`package`, read-only default pointing to `import ../pkgs/fleet-notify { inherit pkgs; }` so desktop modules can reference `config.notify.client.package`)
  - Implementation:
    - Installs `fleetNotifyPkg` in `environment.systemPackages`.
    - Writes `/etc/fleet-notify/config.json` (`0644`, non-secret: `host`, `urls`, `defaultTopic`, `desktopTopics`, `publishTokenFile`, `subscribeTokenFile`).
    - Defines `systemd.services."fleet-notify@"` (`Type = "oneshot"`, `ExecStart = "${fleetNotifyPkg}/bin/fleet-notify --best-effort --unit %i"`).
    - Generates `systemd.services = lib.genAttrs cfg.onFailureUnits (_: { unitConfig.OnFailure = lib.mkAfter ["fleet-notify@%n.service"]; });`.
    - **Contains no desktop user services.**

### 5.5 Package (`pkgs/fleet-notify/`)

Stdlib Python 3 package wrapped with `libnotify` (`notify-send`) on `PATH` for `fleet-notify-desktop`, built with `doCheck = true` running `pytest`:

1. **`fleet-notify` (publisher CLI):**
   - Arguments:
     - `--config PATH` (default `$FLEET_NOTIFY_CONFIG` or `/etc/fleet-notify/config.json`)
     - `--topic TOPIC` (default from config: `fleet-alerts`)
     - `--priority 1..5|min|low|default|high|urgent` (default `default`)
     - `--title TITLE` (if omitted, defaults to `[<host>] Notification`)
     - `--tags TAGS` (comma-separated ntfy tags/emojis)
     - `--click URL` (optional click URL)
     - `--markdown` (sets `Markdown: yes` header)
     - `--stdin` (read message body from stdin)
     - `--unit UNIT` (systemd failure mode: runs `systemctl show <unit> -p Result -p ExecMainStatus -p ActiveState` and `journalctl -u <unit> -n 15 --no-pager --output=short-iso`, formats title `[<host>] Service failed: <unit>` with `priority=high`, `tags=rotating_light,gear`, and publishes)
     - `--best-effort` (log errors to stderr and exit `0` instead of non-zero)
     - `[MESSAGE]` positional text
   - Security & reliability:
     - Reads token from `publishTokenFile` (strips whitespace); if token file is missing/unreadable (e.g. before secrets are provisioned), logs a clear error (exit `0` with `--best-effort`, exit `1` otherwise).
     - Sends token ONLY via HTTP `Authorization: Bearer <token>` header; never logs or echoes token in error messages.
     - Sanitizes header values (strips CR/LF; uses RFC 2047 / UTF-8-safe encoding or JSON publish payload to `POST <base_url>` with `{"topic": ..., "title": ..., "message": ..., "priority": ..., "tags": [...], "click": ...}`!).
       - **Important detail *(Our Call)*:** Use `ntfy`'s JSON publish API (`POST <base_url>` with `Content-Type: application/json`) rather than HTTP headers for `title`/`tags`/`message`! That cleanly handles arbitrary UTF-8, emojis, and punctuation without HTTP header encoding pitfalls!
     - Tries each URL in `config.urls` in order (5s timeout per request); retries transient network/5xx errors once per URL; fails fast on HTTP 401/403/400 without retrying.

2. **`fleet-notify-desktop` (desktop SSE subscriber):**
   - Reads `/etc/fleet-notify/config.json` (or `--config`) and `subscribeTokenFile`.
   - Persists last-seen message state (`{"last_id": "...", "last_time": 1234567890}`) atomically (`0600`) to `${XDG_STATE_HOME:-~/.local/share}/fleet-notify/cursor.json`.
   - Connects via `urllib`/`http.client` streaming to `<url>/<comma-joined-desktopTopics>/json?since=<cursor>` (`since=10m` on first run when no cursor exists; `since=<last_id>` on subsequent runs/reconnects so alerts missed during laptop sleep replay once and never duplicate).
   - Processes NDJSON lines:
     - Ignores `event != "message"` (`open`, `keepalive`, `poll_request`).
     - Deduplicates against `last_id` and updates cursor atomically after dispatching.
     - Maps `ntfy` priority (`>= 4` → `critical`, `3` → `normal`, `<= 2` → `low`) and tags → freedesktop icon (`rotating_light`/`warning`/`x` → `dialog-error`, `arrows_counterclockwise` → `system-reboot`, `cd`/`floppy_disk` → `drive-harddisk`, default → `dialog-information`).
     - Calls `notify-send --app-name="NixOS Fleet" --urgency=<u > --icon=<i> -- <title> <message>` (with bounded timeout so a stuck notification daemon cannot hang the stream).
     - Reconnects with capped exponential backoff (`2s` → `60s`, resetting on a healthy stream), rotating through `config.urls` (`notify.benway.me` → `zita.<tailnet>:2587`).
     - Handles `SIGTERM`/`SIGINT` cleanly for fast systemd restarts.

### 5.6 Desktop Integration (`modules/plasma.nix`)

To ensure workstations can switch desktops without changing `modules/notify.nix`:
- Add the desktop notification consumer inside **`modules/plasma.nix`** (guarded by `config.plasma.enable && config.notify.client.enable && config.notify.client.subscribeTokenFile != null`):
  - For each user in `config.plasma.users`, define `home-manager.users.${user}.systemd.user.services.fleet-notify-desktop`:
    - `Unit`: `Description = "Stream fleet ntfy alerts to KDE Plasma notifications"`, `After = ["graphical-session.target" "network-online.target"]`, `PartOf = ["graphical-session.target"]`, `ConditionPathExists = toString config.notify.client.subscribeTokenFile`.
    - `Service`: `Type = "simple"`, `ExecStart = "${config.notify.client.package}/bin/fleet-notify-desktop"`, `Restart = "always"`, `RestartSec = "5s"`.
    - `Install`: `WantedBy = ["graphical-session.target"]`.
- No desktop-specific option or unit lives in `modules/notify.nix` or `modules/auto-update.nix`.

### 5.7 Producer Integrations

1. **`modules/auto-update.nix` + `pkgs/auto-update/`:**
   - **Remove:** `statusServer` options/service/firewall (`status-server.py`, port `9105`), `desktopNotifications` options/service/timer (`desktop-notify.sh`, `fleet-health-notify`), and `auto-update.desktopNotifications.enable = true` in `hosts/common/workstation.nix`.
   - **Keep:** Local `/var/lib/nixos-auto-update/status.json` (still used by `boot-verify.sh` for attended reboot verification).
   - **Wire `write-status.sh`:**
     - Add `config.notify.client.package` (when `config.notify.client.enable`) to `writeStatusScript`'s `runtimeInputs`.
     - Read prior `status.json`'s `(status, summary, lastNotifiedDate)` BEFORE atomically replacing it.
     - Publish via `fleet-notify --best-effort`:
       - `update_failed` / `rollback_failed`: topic `fleet-alerts`, priority `urgent`, tags `rotating_light,nix`, title `[<host>] <summary>`.
       - `reboot_required_attended`:
         - If `severity == "critical"` (TPM PCR drift / boot guard failure): topic `fleet-alerts`, priority `high`, tags `warning,arrows_counterclockwise`.
         - Else (normal workstation kernel update): topic `fleet-updates`, priority `default`, tags `arrows_counterclockwise`.
         - Deduplicate: if prior status & summary are identical AND `lastNotifiedDate == today`, skip re-notifying so unchanged attended-reboot reminders appear at most once per day.
       - `reboot_scheduled`: topic `fleet-updates`, priority `low`, tags `clock3`.
       - `healthy`: ONLY notify if prior status was non-healthy (`update_failed`, `rollback_failed`, `reboot_required_attended`, `reboot_scheduled`) → topic `fleet-updates`, priority `low`, tags `white_check_mark`. Routine already-healthy runs stay silent.
   - **Single-alert guarantee on crashes (`auto-update.sh` & `boot-verify.sh`):**
     - Do **not** add `nixos-auto-update` to `notify.client.onFailureUnits` (which would fire a second duplicate alert right after `write-status.sh` on handled `exit 1` paths). Instead, track a `STATUS_REPORTED=false` flag in `auto-update.sh` and add an `EXIT` trap that calls `write-status.sh` (`update_failed`, `critical`) only on unhandled non-zero exits, while still exiting non-zero so `systemctl --failed` and Beszel remain accurate.
     - In `boot-verify.sh`, also call `write-status.sh` (`update_failed`, `critical`) when an attended-reboot post-boot canary fails (currently lines 29–41 exit `1` without calling `write-status.sh` when `PENDING_BOOT_FILE` is absent).
2. **`modules/smartd.nix`:**
   - Add `smartd.notifications.fleetNotify` (`bool`, default `config.notify.client.enable`).
   - When enabled:
     - Explicitly disable nixpkgs' built-in `services.smartd.notifications.{wall,mail,x11}.enable` (prevents duplicate `-M exec` in `smartd.conf` and avoids broken `xmessage` on Wayland).
     - Inject `-m <nomailer> -M exec ${smartdNotifyScript}` into `defaultOpts` (`defaults.autodetected` & `defaults.monitored`), where `smartdNotifyScript`:
       - Invokes `fleet-notify --best-effort --topic fleet-alerts --priority high --tags warning,cd --title "[${hostname}] SMART: ${SMARTD_FAILTYPE:-Alert} (${SMARTD_DEVICE:-disk})" "${SMARTD_FULLMESSAGE:-${SMARTD_MESSAGE:-SMART warning}}"`.
       - Also runs `wall` if `cfg.notifications.wall` is explicitly kept `true` (change `cfg.notifications.wall` default to `!cfg.notifications.fleetNotify`).
3. **`modules/beszel.nix` & `docs/howto/beszel-hermes-prompt.md`:**
   - No Nix code change needed in `beszel-hub` itself (notifications are configured in Beszel Hub's UI per user); update `docs/howto/beszel-hermes-prompt.md` so Beszel Hub's notification URL uses direct loopback Shoutrrr `ntfy://` (verifying Beszel's Shoutrrr `ntfy://` HTTP/auth parameter syntax — e.g. `ntfy://:tk_<pub_token>@127.0.0.1:2586/fleet-alerts?priority=high&scheme=http` or `disabletls=yes` against the pinned Beszel package).
   - Update Hermes's self-config guidance in `docs/howto/beszel-hermes-prompt.md` to reflect its read-only on-demand `beszel-query` role (no webhook listener required for alerts).
4. **Systemd `OnFailure=` defaults *(Our Call)*:**
   - Wire key always-on infrastructure units that don't emit their own structured alerts via `notify.client.onFailureUnits`:
     - `zita`: `["caddy" "beszel-hub" "vaultwarden" "forgejo"]` (never adding `ntfy-sh` to its own `onFailureUnits` to avoid loops, and omitting `nixos-auto-update` since it reports directly via `write-status.sh`).
     - `michael`: `["pihole-ftl" "unbound"]`.
     - Workstations (`francis`, `agnes`, `jerome`): `[]` by default (can opt in per host/module anytime).

### 5.8 Documentation (`docs/howto/fleet-notify.md`)

Add a concise how-to covering:
1. One-time secret bootstrap (`ntfy-server.env.age`, `fleet-notify-pub.token.age`, `fleet-notify-sub.token.age` + `secrets/agenix-rules.nix` rules + `ntfy user hash` command to generate bcrypt hashes).
2. Connecting the Android `ntfy` app to `https://notify.benway.me` with `joel`'s admin token and subscribing to `fleet-alerts` + `fleet-updates`.
3. Updating Beszel Hub's notification URL to `ntfy://:tk_<pub_token>@127.0.0.1:2586/fleet-alerts?priority=high&disabletls=yes`.
4. How any NixOS module or user script wires into the bus (`fleet-notify`, `notify.client.onFailureUnits`, and adding `fleet-notify-desktop` to a new desktop module).

---

## 6. Left to the Builder

- Exact Python module layout inside `pkgs/fleet-notify/` (single script vs small modules) and `default.nix` wrapper details.
- Exact `pytest` test cases covering `fleet-notify` JSON publish, fallback URLs, 4xx vs 5xx retry, `--best-effort`, `--unit` journal capture, `fleet-notify-desktop` SSE parsing, cursor persistence/dedup, priority-to-urgency & tag-to-icon mapping, reconnect backoff, and secret redaction.
- Checking any existing references to `status-server.py`, `desktop-notify.sh`, `fleet-health-notify`, or port `9105` in docs/tests and updating or removing them cleanly.
