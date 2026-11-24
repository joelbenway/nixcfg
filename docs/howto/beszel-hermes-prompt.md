---
type: howto
title: "How-To: Beszel Fleet Telemetry & Hermes Setup"
description: "One-time Agenix secret bootstrap, Beszel alert policy setup via direct loopback ntfy, and the ready-to-paste prompt for Hermes's read-only beszel-query role."
status: active
trust: verified
owner: joel
timestamp: "2026-11-24"
tags:
  - howto
  - telemetry
  - beszel
  - hermes
  - ntfy
  - signal
  - monitoring
---

# Beszel Fleet Telemetry & Hermes Setup

This guide covers the one-time secret bootstrap, Beszel Hub alert policy setup on `https://metrics.benway.me` pushing directly to the self-hosted **`ntfy`** fleet notification bus on `zita`, and the prompt to paste into Signal so **Hermes** verifies its read-only `beszel-query` troubleshooting role.

---

## 1. One-Time Secret Bootstrap (`secrets/` Submodule)

Add these three entries to `secrets/agenix-rules.nix`:

```nix
  "beszel-hub-key.age".publicKeys = [keys.hosts.zita] ++ admins;
  "beszel-hub.env.age".publicKeys = [keys.hosts.zita] ++ admins;
  "beszel-hermes.env.age".publicKeys = [keys.hosts.zita] ++ admins;
```

Then generate a dedicated ed25519 keypair for Beszel Hub SSH-pull authentication and encrypt all three secrets:

```bash
# 1. Generate dedicated Beszel Hub SSH keypair in a temporary directory
TMPDIR=$(mktemp -d)
ssh-keygen -t ed25519 -N "" -C "beszel-hub@zita" -f "$TMPDIR/id_ed25519"

# 2. Copy this public key string into data/keys.nix as `beszelHub = "...";`
cat "$TMPDIR/id_ed25519.pub"

# 3. Encrypt the private key into secrets/beszel-hub-key.age
(cd secrets && agenix -e beszel-hub-key.age < "$TMPDIR/id_ed25519")
rm -rf "$TMPDIR"

# 4. Encrypt initial Beszel Hub admin credentials (secrets/beszel-hub.env.age)
#    Contents:
#      USER_EMAIL=joel@benway.me
#      USER_PASSWORD=<CHOOSE_ADMIN_PASSWORD>
(cd secrets && agenix -e beszel-hub.env.age)

# 5. Encrypt read-only Beszel API credentials for Hermes (secrets/beszel-hermes.env.age)
#    Contents:
#      BESZEL_URL=http://127.0.0.1:8090
#      BESZEL_API_EMAIL=hermes-ro@benway.me
#      BESZEL_API_PASSWORD=<CHOOSE_READONLY_PASSWORD>
(cd secrets && agenix -e beszel-hermes.env.age)
```

Commit the new `.age` files and `agenix-rules.nix` in the `secrets/` submodule, update `beszelHub` in `data/keys.nix`, and deploy `zita`, `michael`, `francis`, `agnes`, and `jerome`.

> **Note on `modules/smartd.nix`:** Keep `smartd` enabled fleet-wide. `smartd` actively runs daily short and weekly long drive self-tests and provides `disk-health`; Beszel passively reads cached S.M.A.R.T. attributes (`SMART_INTERVAL=12h`, `smartctl -n standby`) so `zita`'s 24TB HDD stays spun down.

---

## 2. One-Time Beszel Hub UI Configuration

Open `https://metrics.benway.me` (or `https://zita.gentoo-humboldt.ts.net:8091`) and sign in with the admin account from `beszel-hub.env.age`:

1. **Create the read-only Hermes user:**
   - Open PocketBase Admin (`https://metrics.benway.me/_/`) -> **users** collection -> **New record**.
   - Set `email` and `password` to match `secrets/beszel-hermes.env.age`, set `role` = `readonly`, and set `verified` = `true`.
   - Because NixOS sets `SHARE_ALL_SYSTEMS=true`, this `readonly` account automatically sees all 5 hosts and can read their metrics, `systemd`, and S.M.A.R.T. collections without being able to add, edit, or delete systems, tokens, or hub settings.
2. **Verify all 5 systems appear** (seeded automatically from `beszel_data/config.yml`): `zita`, `michael`, `francis`, `agnes`, `jerome`.
3. **Configure alert policy (signed in as `hermes-ro@benway.me`):**
   - **Important:** In Beszel, `alerts`, `alerts_history`, and notification webhooks (`user_settings`) are strictly per-user (`user = @request.auth.id`), and Beszel re-applies that rule on startup even with `SHARE_ALL_SYSTEMS=true`. Beszel natively allows `readonly` users to own their own alerts and notification settings while still blocking writes to systems, tokens, and hub config. Sign into `https://metrics.benway.me` as `hermes-ro@benway.me` before creating the fleet alerts and webhook below so `beszel-query alerts` and `beszel-query alerts --history` can read them cleanly without weakening PocketBase ownership rules.
   - **Always-on servers (`zita`, `michael`):**
     - **Status (offline):** Enabled (3–5 minute grace period so scheduled reboots don't page).
     - **Failed `systemd` units:** Enabled.
     - **Disk usage:** Enabled (`>= 85%`, covering `/mnt/cache` on `zita` above the 75% `mergerfs-mover` watermark).
     - **Temperature, CPU, Memory, Load:** Enabled with a multi-minute averaging window (ignores brief Nix builds).
     - **S.M.A.R.T.:** Enabled.
   - **Workstations & laptops (`francis`, `agnes`, `jerome`):**
     - **Status (offline):** **Disabled** (prevents false alerts when laptops sleep or roam).
     - **Failed `systemd` units:** **Disabled** by default (still visible on the dashboard and via `beszel-query`).
     - **Disk, Temperature, S.M.A.R.T.:** Enabled.
4. **Add the loopback `ntfy` notification URL (still signed in as `hermes-ro@benway.me`):**
   - Beszel pushes alerts directly to `zita`'s local `ntfy-sh` instance over loopback (zero LLM or Hermes dependency; instant delivery to Android `ntfy` and KDE Plasma desktops). See [Fleet Notification Bus](./fleet-notify.md) for bootstrapping the `fleet-pub` token.
   - Paste the Shoutrrr URL into **Settings → Notifications**:
     ```text
     ntfy://:<PUB_TOKEN>@127.0.0.1:2586/fleet-alerts?disabletls=true&priority=high
     ```
     *(If an older Shoutrrr build rejects `disabletls=true`, use `scheme=http` instead.)*
   - Click **Send test notification** and confirm delivery on your phone and desktop.

---

## 3. Hermes Read-Only Telemetry Check Prompt

Beszel alerts go directly to `ntfy` rather than through a Hermes webhook, so alerting keeps working even if Hermes or external LLM APIs are offline. Hermes retains read-only `beszel-query` access on `zita` for on-demand Signal questions and troubleshooting.

Paste this prompt into Signal to verify Hermes's read-only telemetry setup:

```text
You have read-only access to fleet telemetry from Beszel Hub on zita via the `beszel-query` CLI (documented in your SOUL.md). Automated Beszel alerts are now pushed directly to our self-hosted `ntfy` fleet bus on zita, so you do NOT need to run a Beszel alert webhook listener.

Please verify your on-demand fleet telemetry role:

1. Run read-only checks right now:
   - `beszel-query summary`
   - `beszel-query smart`
   - `beszel-query systemd --failed`
   - `beszel-query alerts`
   Report any missing credentials or errors immediately.

2. If you previously configured a `beszel` webhook route/subscription for alert forwarding, disable or remove it so alerts are not duplicated alongside `ntfy`.

3. Remember: `zita` and `michael` are always-on servers; `francis`, `agnes`, and `jerome` are workstations/laptops that sleep normally. Stay quiet unless I ask you a question, and use `beszel-query` whenever I ask about host health, logs, S.M.A.R.T. status, or alert history.
```
