---
type: howto
title: "How-To: Beszel Fleet Telemetry & Hermes Self-Configuration"
description: "One-time Agenix secret bootstrap, Beszel alert policy setup, and the ready-to-paste prompt for Hermes to self-configure its Signal alerting role."
status: active
trust: verified
owner: joel
timestamp: "2026-11-20"
tags:
  - howto
  - telemetry
  - beszel
  - hermes
  - signal
  - monitoring
---

# Beszel Fleet Telemetry & Hermes Setup

This guide covers the one-time secret bootstrap, Beszel Hub alert policy setup on `https://metrics.benway.me`, and the prompt to paste into Signal so **Hermes** configures its own alert webhook and triage behavior.

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
   - Because NixOS sets `SHARE_ALL_SYSTEMS=true`, this read-only account automatically sees all 5 hosts without write or admin access.
2. **Verify all 5 systems appear** (seeded automatically from `beszel_data/config.yml`): `zita`, `michael`, `francis`, `agnes`, `jerome`.
3. **Configure alert policy:**
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
4. **Add Hermes's webhook URL:** After running the Hermes self-configuration prompt below, paste the Shoutrrr URL Hermes outputs into **Settings -> Notifications** (typically `generic://127.0.0.1:8644/webhooks/beszel?template=json&disabletls=yes`) and click **Send test notification**.

---

## 3. Hermes Self-Configuration Prompt

Open whichever Signal chat (your 1:1 DM with Hermes or a dedicated homelab alerts group) you want fleet alerts delivered to, and paste the prompt below directly to Hermes:

```text
You now have read-only access to fleet telemetry from Beszel Hub on zita via the `beszel-query` CLI (documented in your SOUL.md). Please configure yourself for your role in our fleet telemetry and alerting scheme targeting THIS Signal chat:

1. Verify read-only telemetry access right now by running:
   - `beszel-query summary`
   - `beszel-query smart`
   - `beszel-query systemd --failed`
   Report any missing credentials or errors immediately before continuing.

2. Enable your built-in webhook adapter bound strictly to localhost (`127.0.0.1`, port `8644`). Set `WEBHOOK_ENABLED=true` and `WEBHOOK_PORT=8644` in `~/.hermes/.env`, and explicitly pin the bind host to loopback in `config.yaml` by setting `platforms.webhook.extra.host = "127.0.0.1"` via `agent-env.nix` `extraSettings` (do NOT rely on `WEBHOOK_HOST` in `~/.hermes/.env`, which the webhook env loader ignores; without `platforms.webhook.extra.host`, the adapter binds all interfaces and rejects/skips unsigned `INSECURE_NO_AUTH` routes for both static and dynamic subscriptions). Configure webhook routes under `platforms.webhook` in `config.yaml` (via `agent-env.nix` `extraSettings` or `hermes webhook subscribe`), followed by a detached reload if needed. Do NOT expose the webhook port beyond localhost.

3. Create a webhook route/subscription named `beszel` (accepting Beszel Shoutrrr generic JSON `{ "title": "...", "message": "..." }`) that delivers to THIS Signal chat and runs a triage prompt with these rules:
   - Because Beszel's Shoutrrr generic webhook sends unsigned JSON POSTs by default, either configure this loopback-only (`127.0.0.1`) route with `secret: INSECURE_NO_AUTH` (or equivalent unsigned loopback setting) OR configure header-based auth and include the matching Shoutrrr `@Header=Value` query parameter in the URL you return in step 4.
   - Inspect the alert payload (`title` and `message`).
   - Run targeted `beszel-query` checks for context (e.g., `beszel-query host <name> --hours 1`, `beszel-query systemd --host <name> --failed`, `beszel-query systemd --host <name> --logs <unit>`, or `beszel-query smart --host <name>`).
   - Send ONE concise, actionable Signal message summarizing: severity, affected host, what actually triggered, relevant context/logs, and suggested next check.
   - Remember: `zita` and `michael` are always-on servers; `francis`, `agnes`, and `jerome` are workstations/laptops that sleep normally. Stay quiet unless an alert fires or I ask you a question.

4. Verify the webhook listener is healthy (`curl -sf http://127.0.0.1:8644/health`), test the `beszel` route end-to-end with a synthetic test payload (`{"title":"[TEST] Beszel -> Hermes","message":"Verify Signal triage pipeline"}`), and reply with the exact Shoutrrr URL for me to paste into Beszel Hub's Settings -> Notifications (e.g., `generic://127.0.0.1:8644/webhooks/beszel?template=json&disabletls=yes`, plus any `@Header` parameter if you enabled header auth).
```
