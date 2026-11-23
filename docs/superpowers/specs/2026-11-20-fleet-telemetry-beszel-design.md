# Fleet Telemetry & Hermes Alerting (Beszel) — Design Spec

- **Date:** 2026-11-20
- **Status:** Ready for Approval
- **Owner:** Joel Benway
- **Scope:** Fleet-wide machine telemetry via Beszel (`zita`, `michael`, `francis`, `agnes`, `jerome`) + read-only Hermes query tooling and a Hermes self-configuration prompt for Signal alerting.

---

## 1. Intent & Why

Today, fleet visibility is fragmented: `modules/telemetry.nix` only runs `ntopng` in RAM on `michael` for network flows, `modules/smartd.nix` only broadcasts SMART warnings locally via `wall`, and `modules/auto-update.nix` serves a narrow `status.json` for KDE desktop notifications. There is no single place to view machine health, load, thermals, storage, GPU, or `systemd` service health across the five NixOS hosts—and no way for Hermes (running 24/7 on `zita` with Signal messaging) to inspect fleet metrics or triage alerts over Signal.

The goal is a lightweight, low-maintenance, declarative telemetry setup on `zita` using Beszel for machine health and usage dashboards, paired with read-only Hermes telemetry tooling and a paste-ready onboarding prompt so Hermes can self-configure its own Signal alerting role in whichever chat Joel chooses.

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
- Collect machine health and usage metrics across all 5 fleet hosts (`zita`, `michael`, `francis`, `agnes`, `jerome`): CPU, memory, load, thermals, disk space & I/O, network throughput, SMART drive attributes, `systemd` service status & recent journal logs, plus laptop battery (`agnes`, `jerome`) and NVIDIA Quadro M2000 GPU/NVENC + tiered storage (`/mnt/cache`, `/mnt/disk1`) on `zita`.
- Host the Beszel Hub declaratively on `zita`, persisted across impermanence wipes, reachable at `https://metrics.benway.me` (LAN + Cloudflare DNS-01 TLS) and `https://zita.<tailnet>:<port>` (Tailscale).
- Keep `modules/smartd.nix` running alongside Beszel so drives continue running scheduled daily short and weekly long self-tests and retain `disk-health` / `nvme-cli`.
- Give Hermes a read-only CLI helper (`beszel-query`) backed by read-only Beszel API credentials so Hermes can inspect live/historical host vitals, SMART attributes, failed `systemd` units, and active alerts on demand or during alert triage.
- Output a paste-ready **Hermes self-configuration prompt** so Joel can drop it into whichever Signal chat/DM he chooses and let Hermes configure its own alert ingestion (e.g., native webhook receiver / triage skill), Signal target, and verification—keeping Signal chat/routing purely in Hermes config rather than hardcoding Signal recipients in NixOS.
- Alert on failed `systemd` units (enabled for always-on servers `zita` and `michael` by default), alongside standard resource/thermal/SMART/offline alerts, while handling sleeping/roaming workstations (`francis`, `agnes`, `jerome`) cleanly without false offline spam.

### Non-Goals (Explicitly Deferred)
- Periodic ISP speedtests from `michael`.
- Periodic LAN performance (`iperf3`) benchmarking.
- Odd network activity / flow anomaly detection via `ntopng` or Pi-hole DNS metrics (existing `modules/telemetry.nix` on `michael` remains untouched).
- Scraping `modules/auto-update.nix` `status.json` into Beszel.
- Replacing `modules/smartd.nix` scheduled self-tests or `disk-health`.
- Custom NixOS Signal-delivery daemon or hardcoded Signal recipient/group IDs in NixOS/agenix (Signal routing and alert triage behavior live purely in Hermes's own runtime configuration).
- Scheduled Hermes health digests (alert-driven + on-demand chat only; quiet unless something is wrong).

### Anti-Goals
- **Spinning up `zita`'s 24TB Seagate HDD unnecessarily:** SMART polling and filesystem usage checks must respect standby/spindown (`smartctl -n standby`, conservative `SMART_INTERVAL`, cached disk usage).
- **Alert fatigue from sleeping laptops:** Putting `agnes`, `jerome`, or `francis` to sleep or taking a laptop off-LAN must never trigger offline alerts.
- **Breaking NixOS impermanence or Hermes blast-radius isolation:** Hub data must survive reboots cleanly, and Hermes must only receive read-only telemetry query access (no Beszel admin credentials and no write access outside its existing `agent-env.nix` / `/var/lib/hermes` boundary).

---

## 3. Constraints

- **Impermanence on all hosts:** Root is wiped on every boot. Persistent state on `zita` must live under `/persist` (via `impermanence.directories`) or `/mnt/cache/appdata`. Note that nixpkgs's `services.beszel.hub` sets `DynamicUser = true` (putting `StateDirectory` under `/var/lib/private/beszel-hub`), so persistence and secret ownership must account for that (either overriding to a static `beszel-hub` user or persisting `/var/lib/private/beszel-hub` consistently).
- **SSD wear on `zita`:** `/mnt/cache` is backed by 2×120 GB OCZ Vertex 3 SATA SSDs. Beszel's PocketBase SQLite database has a very small write footprint, keeping SSD wear minimal.
- **Network & Firewall boundaries:**
  - `zita` (`192.168.77.20`) and `michael` (`192.168.77.1`) are always-on servers on Skylab VLAN 77 and Tailscale (`gentoo-humboldt.ts.net`).
  - `francis`, `agnes`, and `jerome` are workstations/laptops reachable over Skylab LAN and Tailscale (including when roaming off-LAN).
  - Agent ports must never be exposed on WAN or untrusted VLANs (`skynet`, `iot`)—only `tailscale0` and Skylab LAN (`192.168.77.0/24`), matching the pattern in `modules/auto-update.nix`.
- **Port registry:** All new internal, Tailscale, and agent ports must be declared in `data/ports.nix` (which enforces collision checking).
- **Secrets management:** All credentials and private keys must be encrypted with Agenix and registered in `secrets/agenix-rules.nix`.
- **Hermes runtime model:** Hermes runs natively as user `hermes` on `zita` under the Agentic GitOps model (`modules/hermes/default.nix`, `modules/hermes/agent-env.nix`, `modules/hermes/SOUL.md`), with `signal-cli` already running on `http://127.0.0.1:8085`.

---

## 4. Approaches Considered

### Approach 1: Prometheus + Alertmanager + Grafana + Hermes Triage Bridge
- **Summary:** Run `node_exporter`, `smartctl_exporter`, `nvidia_gpu_exporter`, `blackbox_exporter`, and textfile collectors across hosts; centralize in `services.prometheus` + Alertmanager + declaratively provisioned Grafana dashboards on `zita`.
- **Trade-offs:** Unified single-pane-of-glass capable of charting custom ISP speedtests, LAN `iperf3`, CAKE/Pi-hole metrics, and PromQL anomaly rules—at the cost of significant NixOS wiring, multiple daemons, and Grafana dashboard JSON maintenance.

### Approach 2: VictoriaMetrics + `vmalert` + Alertmanager + Grafana + Hermes Triage Bridge
- **Summary:** Same exporters, Grafana dashboards, and Hermes bridge as Approach 1, swapping Prometheus for VictoriaMetrics + `vmalert`.
- **Trade-offs:** 5–10× better compression and lower SSD write amplification on `zita`'s Vertex 3 cache SSDs, at the cost of one extra daemon (`vmalert`) plus full Grafana dashboard maintenance.

### Approach 3: Beszel Hub & Agents + Hermes Self-Configured Triage *(Chosen)*
- **Summary:** Use nixpkgs's first-class `services.beszel.hub` (v0.21.0) on `zita` and `services.beszel.agent` across all 5 hosts for turnkey machine health, SMART, `systemd`, battery, and GPU dashboards. Provide Hermes a read-only `beszel-query` CLI and a paste-ready onboarding prompt so Hermes configures its own Signal alerting and webhook/triage behavior natively. Defer custom network/speed metrics rather than maintaining a split sidecar.
- **Why chosen:** Joel chose to trim scope to the clean, low-maintenance pieces Beszel excels at—avoiding Grafana dashboard authoring and bespoke alert-bridge daemons while still getting fleet-wide dashboards, SMART/`systemd`/GPU visibility, and Hermes-driven Signal alerting & ad-hoc analysis.

---

## 5. Architecture & Decided Design

```
  [michael]  [francis]  [agnes]  [jerome]  [zita (local)]
   agent      agent      agent    agent     agent (+nvidia-smi, /mnt/cache, /mnt/disk1)
     |          |          |        |         |
     +----------+----------+--------+---------+
                SSH pull (:45876 over tailscale0 / Skylab LAN / 127.0.0.1)
                            |
                            v
              [beszel-hub on zita (127.0.0.1:8090)]
                ├── Caddy TLS: https://metrics.benway.me & https://zita.<tailnet>:8091
                ├── PocketBase REST API (127.0.0.1:8090/api/...)
                │        ^
                │        |  (read-only queries via `beszel-query`)
                ├── Shoutrrr generic webhook ──► [hermes-agent on zita (localhost)]
                │                                  (self-configured via onboarding prompt)
                │                                         │
                │                                         v
                │                                [signal-cli 127.0.0.1:8085]
                │                                         │
                │                                         v
                │                                 Joel's chosen Signal chat
```

### 5.1 NixOS Module & Host Wiring *(Our Call — verify during review)*
- **New module `modules/beszel.nix`** (auto-imported via `modules/default.nix`) exposing two cohesive option namespaces:
  - `beszel.agent`: enabled fleet-wide in `hosts/configuration.nix` with defaults:
    - `smartmon.enable = true`
    - `SMART_INTERVAL = "12h"` (conservative polling; Beszel passes `-n standby` so sleeping drives stay spun down)
    - `SKIP_SYSTEMD = false`, `SKIP_SYSTEMD_LOGS = false` (enables `systemd` service tracking + recent journal inspection)
    - Agent firewall rule (custom `networking.firewall.extraInputRules`, **not** `openFirewall = true`): allow TCP `ports.beszel.agent` (`45876`) strictly on `tailscale0` and Skylab LAN `192.168.77.0/24` (matching `modules/auto-update.nix`).
    - Host-specific overrides on `hosts/zita/default.nix`:
      - `GPU_COLLECTOR = ["nvidia-smi"]` for Quadro M2000 utilization/temp/NVENC.
      - `EXTRA_FILESYSTEMS` covering `/mnt/cache` (SSD cache) and `/mnt/disk1` (24TB bulk HDD) plus `DISK_USAGE_CACHE = "1h"` so disk usage checks don't wake `/mnt/disk1`.
    - Workstations/laptops (`agnes`, `jerome`, `francis`): Intel iGPU (`intel_sysfs`) and battery/thermals automatically detected by Beszel agent.
  - `beszel.hub`: enabled on `hosts/zita/default.nix`:
    - Runs `services.beszel.hub` bound to `127.0.0.1:${ports.beszel.internal}` (`8090`).
    - **Static system user over `DynamicUser` *(our call)*:** Override `services.beszel.hub` to run under a dedicated static `beszel-hub` user/group (or manage `/var/lib/private/beszel-hub` consistently) so agenix secret files and `/var/lib/beszel-hub` impermanence bind-mounts work cleanly without `DynamicUser` UID/permission friction.
    - Persists `/var/lib/beszel-hub` via `impermanence.directories` on `zita`.
    - Adds `beszel-hub` to `zita`'s `auto-update.canary.services`.
- **Networking, Ports, Caddy & DNS:**
  - `data/ports.nix`: add `beszel = { internal = 8090; tailscale = 8091; agent = 45876; };` (all collision-free against existing ports).
  - `hosts/zita/default.nix`:
    - Add `ports.beszel.tailscale` to `networking.firewall.allowedTCPPorts`.
    - Add Caddy blocks for `metrics.benway.me` (Cloudflare DNS-01 TLS -> `127.0.0.1:8090`) and `${hostname}.${config.tailscale.tailnet}:${ports.beszel.tailscale}` -> `127.0.0.1:8090`.
  - `hosts/michael/dns.nix`: add `"cname=metrics.benway.me,zita.skylab.home"` alongside existing `*.benway.me` CNAMEs.

### 5.2 Hub ↔ Agent Transport & Declarative Provisioning *(Our Call)*
- **SSH Pull with Agenix-Managed Keypair:**
  - Generate a dedicated ed25519 keypair once offline for Beszel hub-to-agent authentication:
    - Public key stored in `data/keys.nix` (e.g. `beszelHub = "ssh-ed25519 ...";`) and passed via `KEY` to all 5 `beszel-agent` instances.
    - Private key encrypted in `secrets/beszel-hub-key.age` (accessible to `zita` + admins) and installed into `/var/lib/beszel-hub/beszel_data/id_ed25519` (`0600`) before `beszel-hub` starts.
  - **Why SSH pull over WebSocket push:** Eliminates the bootstrap chicken-and-egg of booting the hub first to generate a UI Universal Token and re-deploying secrets to all 5 hosts. Every host works on first boot and survives full impermanence rebuilds.
  - **Host targets declared in `config.yml`** (managed declaratively in `/var/lib/beszel-hub/beszel_data/config.yml`):
    - `zita` -> `127.0.0.1:45876` (always local, works even if network/Tailscale is down)
    - `michael` -> `192.168.77.1:45876` (direct Skylab LAN, works even if Tailscale is down)
    - `francis` -> `francis.gentoo-humboldt.ts.net:45876`
    - `agnes` -> `agnes.gentoo-humboldt.ts.net:45876`
    - `jerome` -> `jerome.gentoo-humboldt.ts.net:45876`
  - **Admin & Read-Only API credentials:**
    - `secrets/beszel-hub.env.age` (`zita` + admins): `USER_EMAIL` / `USER_PASSWORD` for initial hub admin provisioning.
    - `secrets/beszel-hermes.env.age` (`zita` + admins, owned by `hermes:hermes`, mode `0400`): read-only Beszel API credentials (`BESZEL_URL=http://127.0.0.1:8090`, `BESZEL_API_EMAIL`, `BESZEL_API_PASSWORD`) used strictly by `beszel-query`.

### 5.3 Alert Policy & Intermittent Host Handling
- **Always-on servers (`zita`, `michael`):**
  - **Offline/status alerts:** Enabled (after a brief grace window, e.g. 2–5 minutes, to ignore scheduled reboots/auto-updates).
  - **Failed `systemd` unit alerts:** Enabled (catches silent crashes in Caddy, Pi-hole, Unbound, Jellyfin, Forgejo, Vaultwarden, PIA WireGuard, `mergerfs-mover`, etc.).
- **Workstations & laptops (`francis`, `agnes`, `jerome`):**
  - **Offline/status alerts:** Disabled so sleep, shutdown, and roaming never generate alert noise.
  - **Failed `systemd` unit alerts:** Disabled by default *(our call — avoids offline/sleep update noise while keeping workstation `systemd` status & logs visible on the dashboard and queryable via `beszel-query`; easily toggled on per host in Beszel UI if desired)*.
- **Resource & Health alerts (fleet-wide defaults):**
  - Disk usage high (including `/mnt/cache` on `zita` above the 75% `mergerfs-mover` watermark, e.g. 85%+, and root/bulk partitions at 85–90%+).
  - High temperature (CPU/GPU/drive thermal thresholds).
  - Sustained high CPU / memory / load average (multi-minute window to ignore brief Nix builds).
  - SMART drive health warning/failure.
  - Low battery disabled unless enabled later in UI.
- **Coexistence with `modules/smartd.nix`:**
  - `smartd.nix` remains enabled fleet-wide untouched for scheduled daily short (`02:00`) and weekly long (`Sun 04:00`) self-tests and the `disk-health` CLI.

### 5.4 Hermes Integration: Read-Only Tooling & Self-Configuration Prompt

#### Component A: Read-Only CLI Helper (`beszel-query`)
- Packaged in `pkgs/beszel-query/` and installed on Hermes's `PATH` on `zita` (when both `beszel.hub` and `hermes` are enabled).
- Authenticates read-only against `http://127.0.0.1:8090/api/...` using `secrets/beszel-hermes.env.age` (isolated from Beszel admin credentials and Hermes LLM keys).
- Provides clean, structured JSON/text subcommands for Hermes:
  - Fleet overview (status, uptime, CPU/RAM/disk/temp/GPU across all 5 hosts)
  - Host detail & recent history (e.g., last 1h / 24h stats)
  - `systemd` unit status (especially failed/restarting units)
  - SMART drive health & temperatures
  - Active/recent Beszel alerts
- Briefly documented in `modules/hermes/SOUL.md` so Hermes always knows `beszel-query` is available across restarts/rebuilds.

#### Component B: Hermes Self-Configuration Prompt (No Bespoke Signal Bridge Daemon)
- Signal alert destination, webhook subscription, and triage behavior are **pure Hermes configuration**, owned and maintained by Hermes itself under its Agentic GitOps model.
- As part of the deliverables, we include a concise, ready-to-paste onboarding prompt (`docs/howto/beszel-hermes-prompt.md` and printed in the final handoff) for Joel to send to Hermes in whichever Signal chat/DM he chooses. That prompt instructs Hermes to:
  1. Verify read-only telemetry access by running `beszel-query`.
  2. Configure its native webhook ingestion (or lightweight localhost webhook receiver if the locked `hermes-agent` build lacks the native webhook gateway) listening on `127.0.0.1` and targeting the current Signal chat for delivery.
  3. Set up its triage behavior/instructions: on incoming Beszel alerts, inspect fresh context with `beszel-query` (host vitals, failed `systemd` units, SMART health) and send a concise, actionable Signal summary—staying quiet unless an alert fires or Joel asks.
  4. Output the exact local Shoutrrr webhook URL (`generic://127.0.0.1:<port>/...?template=json&disabletls=yes`) for Joel (or Beszel's notification settings) to wire into Beszel Hub.

---

## 6. Left to the Builder

The builder has full latitude to settle the following implementation details without coming back to Joel:
- Exact Beszel v0.21.0 `config.yml` YAML field schema and `preStart` hook mechanics for seeding `id_ed25519` and `config.yml` under `/var/lib/beszel-hub/beszel_data/`.
- Whether initial Beszel alert rules and read-only user creation are seeded via an idempotent PocketBase API/SQLite bootstrap script or documented as concise post-deploy steps (prefer idempotent automation where Beszel's schema supports it cleanly; document any remaining one-time UI step clearly).
- Exact PocketBase collection names, query filters, and output format of `beszel-query`.
- Checking the locked `hermes-agent` flake revision (`fbf6c6c9...`) for native webhook gateway capabilities so the self-configuration prompt in `docs/howto/beszel-hermes-prompt.md` references accurate Hermes commands/settings (and adding any needed localhost firewall/port note if applicable).
- Exact default numeric alert thresholds (within the policy in §5.3).
- Updating `docs/hosts/zita.md` and `README.md` to document Beszel monitoring and Hermes integration.
