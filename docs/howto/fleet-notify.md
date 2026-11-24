---
type: howto
title: "How-To: Fleet Notification Bus (ntfy + Desktop Subscribers)"
description: "One-time Agenix secret bootstrap for self-hosted ntfy-sh on zita, Android ntfy app setup, Beszel loopback alerting, and developer guide for wiring services and desktop modules."
status: active
trust: verified
owner: joel
timestamp: "2026-11-24"
tags:
  - howto
  - notifications
  - ntfy
  - fleet
  - plasma
  - beszel
  - smartd
  - auto-update
---

# Fleet Notification Bus (`ntfy` + Desktop Subscribers)

This guide covers bootstrapping the self-hosted **`ntfy-sh`** notification bus on `zita` (`modules/notify.nix`), connecting the Android `ntfy` app and Beszel Hub, and wiring new services or desktop environments into the bus.

## Architecture Summary

- **Server (`zita`):** `services.ntfy-sh` listens on `127.0.0.1:2586`, reverse-proxied by Caddy on `https://notify.benway.me` (LAN CNAME on `michael` + Cloudflare DNS-01 TLS) and `https://zita.gentoo-humboldt.ts.net:2587` (Tailscale HTTPS). Auth defaults to `deny-all` with least-privilege accounts (`joel` admin, `fleet-pub` write-only to `fleet-*`, `fleet-sub` read-only to `fleet-*`).
- **Clients (all 5 hosts):** `notify.client.enable = true` in `hosts/configuration.nix` installs `fleet-notify`, writes `/etc/fleet-notify/config.json`, and provides the `fleet-notify@.service` `OnFailure=` template.
- **Desktop subscribers (desktop-owned):** `modules/notify.nix` has zero desktop coupling. `modules/plasma.nix` starts `fleet-notify-desktop` (SSE → `notify-send`) as a Home Manager user service on Plasma workstations (`francis`, `agnes`, `jerome`), using the read-only `fleet-sub` token.
- **Topics:**
  - `fleet-alerts` — Actionable failures (`auto-update` failures/rollbacks/TPM drift, `smartd` disk faults, Beszel alerts, systemd `OnFailure=` crashes).
  - `fleet-updates` — Non-urgent operational notices (attended kernel reboot reminders, scheduled reboots, post-failure recoveries).

---

## 1. One-Time Secret Bootstrap (`secrets/` Submodule)

Add these three rules to `secrets/agenix-rules.nix`:

```nix
  "ntfy-server.env.age".publicKeys = [keys.hosts.zita] ++ admins;
  "fleet-notify-pub.token.age".publicKeys = [
    keys.hosts.zita
    keys.hosts.michael
    keys.hosts.francis
    keys.hosts.agnes
    keys.hosts.jerome
  ] ++ admins;
  "fleet-notify-sub.token.age".publicKeys = [
    keys.hosts.francis
    keys.hosts.agnes
    keys.hosts.jerome
  ] ++ admins;
```

Generate three random access tokens (`tk_` + 29 alphanumeric characters) and bcrypt password hashes (using `ntfy user hash`):

```bash
# 1. Generate three access tokens (save temporarily in your shell session only)
ADMIN_TOKEN="tk_$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 29)"
PUB_TOKEN="tk_$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 29)"
SUB_TOKEN="tk_$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 29)"

# 2. Generate bcrypt hashes for joel, fleet-pub, and fleet-sub
#    (fleet-pub and fleet-sub authenticate via tokens, so use strong random passwords for their hashes)
nix run nixpkgs#ntfy-sh -- user hash   # run once per user
```

Now encrypt the three Agenix files:

1. **`secrets/ntfy-server.env.age`** (mounted on `zita` only, `0400 ntfy-sh:ntfy-sh`):
   ```dotenv
   NTFY_AUTH_USERS=joel:<joel-bcrypt-hash>:admin,fleet-pub:<pub-bcrypt-hash>:user,fleet-sub:<sub-bcrypt-hash>:user
   NTFY_AUTH_TOKENS=joel:<ADMIN_TOKEN>:phone,fleet-pub:<PUB_TOKEN>:fleet-hosts,fleet-sub:<SUB_TOKEN>:desktop-sessions
   ```
   *(Note: systemd `EnvironmentFile` passes `$2a$10$...` bcrypt hashes through verbatim without variable expansion.)*
   ```bash
   (cd secrets && agenix -e ntfy-server.env.age)
   ```

2. **`secrets/fleet-notify-pub.token.age`** (all 5 hosts, `0440 root:wheel`):
   ```bash
   printf '%s\n' "$PUB_TOKEN" | (cd secrets && agenix -e fleet-notify-pub.token.age)
   ```

3. **`secrets/fleet-notify-sub.token.age`** (workstations only, `0440 root:users`):
   ```bash
   printf '%s\n' "$SUB_TOKEN" | (cd secrets && agenix -e fleet-notify-sub.token.age)
   ```

Commit the new `.age` files and `agenix-rules.nix` in `secrets/`, update the submodule pointer in `nixcfg`, and deploy `zita` first (then `michael`, `francis`, `agnes`, `jerome`).

> **Pre-bootstrap safety:** All three `.age` references are guarded with `builtins.pathExists`. Before `secrets/ntfy-server.env.age` exists, `notify.server.enable` and the `ntfy-sh` auto-update canary stay off on `zita` so builds and CI pass cleanly.

---

## 2. Android `ntfy` App Setup

Because mobile delivery targets Android over LAN/Tailscale, `upstream-base-url` is intentionally omitted (zero traffic goes through `ntfy.sh`).

1. Install the official **`ntfy`** app (F-Droid or Google Play).
2. Open **Settings → Manage users → Add new user**:
   - **Service URL:** `https://notify.benway.me` (or `https://zita.gentoo-humboldt.ts.net:2587` if away from LAN without split DNS)
   - **Auth:** Access token (`<ADMIN_TOKEN>` for `joel`, or username/password for `joel`)
3. Optionally set **Default server** to `https://notify.benway.me`.
4. Tap **+** to subscribe to:
   - `fleet-alerts`
   - `fleet-updates`
5. Ensure battery optimization is disabled for `ntfy` so instant delivery stays active over Tailscale/LAN.

---

## 3. Beszel Hub Loopback Notification URL

Beszel Hub on `zita` pushes alerts directly to `ntfy-sh` over localhost with zero LLM or Hermes dependency:

1. Open `https://metrics.benway.me` (signed in as the account that owns your alerts — see [Beszel Fleet Telemetry & Hermes Setup](./beszel-hermes-prompt.md)).
2. Go to **Settings → Notifications** and add the Shoutrrr `ntfy://` URL using `fleet-pub`'s token:
   ```text
   ntfy://:<PUB_TOKEN>@127.0.0.1:2586/fleet-alerts?disabletls=true&priority=high
   ```
   *(If an older Shoutrrr build rejects `disabletls=true`, use `scheme=http` instead: `ntfy://:<PUB_TOKEN>@127.0.0.1:2586/fleet-alerts?scheme=http&priority=high`.)*
3. Click **Send test notification** and verify it arrives on both Android and your KDE Plasma desktop.

---

## 4. Verification

After deploying `zita` and a workstation (e.g., `francis`):

```bash
# On zita: verify ntfy-sh is active and listening on 127.0.0.1:2586
systemctl status ntfy-sh

# On any host (as root or wheel user): send a test notification
fleet-notify --topic fleet-updates --priority low --tags white_check_mark \
  --title "[$(hostname)] Fleet notify test" \
  "End-to-end delivery check from $(hostname)"

# On a Plasma workstation (as desktop user): verify the SSE desktop subscriber
systemctl --user status fleet-notify-desktop
journalctl --user -u fleet-notify-desktop -n 20 --no-pager
```

---

## 5. Developer Guide: Wiring New Producers & Desktops

### Publishing from any script or service

`fleet-notify` is installed system-wide on every host. Use `--best-effort` in automated hooks so a temporary network outage never aborts the calling job:

```bash
fleet-notify \
  --best-effort \
  --topic fleet-alerts \
  --priority high \
  --tags rotating_light,gear \
  --title "[$(hostname)] Backup failed" \
  "Nightly snapshot returned exit code 1"
```

Priority values accept `1..5` or `min`, `low`, `default`, `high`, `urgent`. You can also pipe a message body via `--stdin` or attach a click target with `--click https://...`. Any `fleet-*` topic is allowed by the default `fleet-pub` ACL without editing server rules.

### Systemd `OnFailure=` crash alerts

Add any service name (without `.service`) to `notify.client.onFailureUnits` in a host or module:

```nix
notify.client.onFailureUnits = [
  "my-critical-daemon"
];
```

This wires `unitConfig.OnFailure = lib.mkAfter ["fleet-notify@%n.service"];`, which runs `fleet-notify --best-effort --unit %i`, capturing `systemctl show` state plus the last 15 lines of `journalctl -u <unit>` and posting to `fleet-alerts`.

### Supporting another desktop environment

`modules/notify.nix` intentionally never references Plasma, GNOME, Hyprland, or Home Manager. To enable desktop toast notifications in a future desktop module (for example `modules/hyprland.nix` or `modules/gnome.nix`), reuse `config.notify.client.package` directly inside that desktop module:

```nix
systemd.user.services.fleet-notify-desktop = lib.mkIf (
  config.notify.client.enable && config.notify.client.subscribeTokenFile != null
) {
  Unit = {
    Description = "Stream fleet ntfy alerts to desktop notifications";
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
  Install.WantedBy = ["graphical-session.target"];
};
```
