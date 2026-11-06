# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  pkgs,
  ...
}: let
  cfg = config.auto-update;
  tailnet = config.tailscale.tailnet or "gentoo-humboldt.ts.net";
  deployKeySecretFile = lib.custom.relativeToRoot "secrets/github-secrets-deploy-key.age";
  hasDeployKeySecret = builtins.pathExists deployKeySecretFile;

  # Write status.json helper script
  writeStatusScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-write-status";
    runtimeInputs = with pkgs; [coreutils jq];
    text = ''
      set -euo pipefail
      STATUS="''${1:-healthy}"
      SEVERITY="''${2:-info}"
      SUMMARY="''${3:-System is up to date}"
      DETAILS="''${4:-}"

      STATE_DIR="${cfg.stateDir}"
      STATUS_FILE="''${STATE_DIR}/status.json"
      mkdir -p "''${STATE_DIR}"

      BOOTED_SYS=$(readlink -f /run/booted-system 2>/dev/null || echo "unknown")
      CURRENT_SYS=$(readlink -f /run/current-system 2>/dev/null || echo "unknown")
      BOOTED_KERNEL=$(readlink -f /run/booted-system/kernel 2>/dev/null || echo "unknown")
      CURRENT_KERNEL=$(readlink -f /run/current-system/kernel 2>/dev/null || echo "unknown")

      TMP_FILE=$(mktemp "''${STATE_DIR}/status.json.XXXXXX")
      jq -n \
        --arg host "${hostname}" \
        --arg status "$STATUS" \
        --arg severity "$SEVERITY" \
        --arg summary "$SUMMARY" \
        --arg details "$DETAILS" \
        --arg bootedSystem "$BOOTED_SYS" \
        --arg currentSystem "$CURRENT_SYS" \
        --arg bootedKernel "$BOOTED_KERNEL" \
        --arg currentKernel "$CURRENT_KERNEL" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
          host: $host,
          status: $status,
          severity: $severity,
          summary: $summary,
          details: $details,
          bootedSystem: $bootedSystem,
          currentSystem: $currentSystem,
          bootedKernel: $bootedKernel,
          currentKernel: $currentKernel,
          timestamp: $timestamp
        }' > "$TMP_FILE"
      chmod 0644 "$TMP_FILE"
      mv "$TMP_FILE" "$STATUS_FILE"
    '';
  };

  # Host-specific canary check script
  canaryScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-canary";
    runtimeInputs = with pkgs; [
      bind.dnsutils
      coreutils
      glibc.bin
      systemd
    ];
    text = ''
      set -euo pipefail

      echo "==> [Canary] Checking critical systemd services..."
      for svc in ${lib.escapeShellArgs cfg.canary.services}; do
        if ! systemctl is-active --quiet "$svc"; then
          echo "ERROR: Critical service '$svc' is not active on ${hostname}!" >&2
          exit 1
        fi
      done

      if ${lib.boolToString cfg.canary.checkDns}; then
        echo "==> [Canary] Verifying local DNS resolution and upstream forwarders..."
        DNS_OK=false
        for _ in 1 2 3 4 5; do
          DNS_RES=$(dig @127.0.0.1 nixos.org +short +time=2 +tries=1 2>/dev/null || true)
          if [ -n "$DNS_RES" ]; then
            DNS_OK=true
            break
          fi
          sleep 1
        done
        if [ "$DNS_OK" != true ]; then
          echo "ERROR: Local DNS resolution query (@127.0.0.1 nixos.org) failed on ${hostname}!" >&2
          exit 1
        fi
        if ! getent hosts nixos.org >/dev/null 2>&1; then
          echo "ERROR: System hostname resolution (getent hosts nixos.org) failed on ${hostname}!" >&2
          exit 1
        fi
      else
        echo "==> [Canary] Checking overall systemd state..."
        STATE=$(systemctl is-system-running 2>/dev/null || true)
        if [ "$STATE" != "running" ] && [ "$STATE" != "degraded" ] && [ "$STATE" != "starting" ]; then
          echo "ERROR: Unexpected systemd state '$STATE' on ${hostname}!" >&2
          exit 1
        fi
      fi

      echo "==> [Canary] All health checks passed on ${hostname}."
    '';
  };

  # Post-boot verification & bootctl default promotion script
  bootVerifyScript = pkgs.writeShellApplication {
    name = "nixos-boot-verify";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      systemd
      canaryScript
      writeStatusScript
    ];
    text = ''
      set -euo pipefail

      PENDING_BOOT_FILE="${cfg.stateDir}/pending-reboot.json"
      STATUS_FILE="${cfg.stateDir}/status.json"

      # Run host canaries on boot
      if ! nixos-auto-update-canary; then
        echo "ERROR: Post-boot canary verification failed on ${hostname}!" >&2
        if [ -f "$PENDING_BOOT_FILE" ]; then
          rm -f "$PENDING_BOOT_FILE"
          nixos-auto-update-write-status \
            "rollback_failed" \
            "critical" \
            "${hostname} failed post-boot canary check after kernel update; rebooting into previous default generation" \
            "Post-boot canary failed on $(readlink -f /run/booted-system)."
          systemctl reboot
        fi
        exit 1
      fi

      # If a oneshot reboot was pending and we booted into the target system, promote @current to default
      if [ -f "$PENDING_BOOT_FILE" ]; then
        TARGET_SYS=$(jq -r '.targetSystem // ""' "$PENDING_BOOT_FILE" 2>/dev/null || echo "")
        BOOTED_SYS=$(readlink -f /run/booted-system 2>/dev/null || echo "")
        if [ -n "$TARGET_SYS" ] && [ "$BOOTED_SYS" = "$TARGET_SYS" ]; then
          echo "==> Promoting verified booted entry to default via bootctl set-default @current..."
          if bootctl set-default @current; then
            rm -f "$PENDING_BOOT_FILE"
            nixos-auto-update-write-status \
              "healthy" \
              "info" \
              "${hostname} successfully rebooted and verified new kernel" \
              "Booted and verified ''${BOOTED_SYS}."
          else
            echo "ERROR: Failed to promote @current to default via bootctl set-default on ${hostname}!" >&2
            nixos-auto-update-write-status \
              "reboot_required_attended" \
              "critical" \
              "${hostname} failed to set verified kernel as default boot entry" \
              "bootctl set-default @current failed on ''${BOOTED_SYS}. Pending reboot record retained."
          fi
        else
          echo "WARNING: Pending reboot target (''${TARGET_SYS}) does not match booted system (''${BOOTED_SYS}); skipping promotion." >&2
        fi
      elif [ -f "$STATUS_FILE" ]; then
        CUR_STATUS=$(jq -r '.status // "healthy"' "$STATUS_FILE" 2>/dev/null || echo "healthy")
        if [ "$CUR_STATUS" = "reboot_required_attended" ] || [ "$CUR_STATUS" = "reboot_scheduled" ]; then
          if [ "$(readlink -f /run/booted-system)" = "$(readlink -f /run/current-system)" ]; then
            echo "==> Attended reboot completed; clearing status to healthy."
            nixos-auto-update-write-status \
              "healthy" \
              "info" \
              "${hostname} attended reboot completed and verified" \
              "Now running $(readlink -f /run/booted-system)."
          fi
        fi
      else
        nixos-auto-update-write-status "healthy" "info" "${hostname} is healthy" ""
      fi
    '';
  };

  # Main auto-update execution script
  updateScript = pkgs.writeShellApplication {
    name = "nixos-auto-update";
    runtimeInputs =
      (with pkgs; [
        coreutils
        findutils
        git
        gnugrep
        gnused
        jq
        nix
        nixos-rebuild
        openssh
        systemd
        util-linux
        canaryScript
        writeStatusScript
      ])
      ++ lib.optional (config.tpm.enable or false) pkgs.cryptsetup;
    text = ''
      set -euo pipefail

      HOST_NAME="${hostname}"
      STATE_DIR="${cfg.stateDir}"
      REPO_DIR="''${STATE_DIR}/nixcfg"
      ZITA_REMOTE_URL="git://${cfg.zitaHost}:9418/nixcfg"
      ZITA_SECRETS_URL="git://${cfg.zitaHost}:9418/nixos-secrets"
      ORIGIN_URL="${cfg.repoUrl}"
      SECRETS_ORIGIN_URL="${cfg.secretsRepoUrl}"
      DEPLOY_KEY_PATH="${
        if cfg.secretsDeployKeyPath != null
        then toString cfg.secretsDeployKeyPath
        else ""
      }"

      mkdir -p "''${STATE_DIR}"

      # Serialize updater executions across manual and timer-driven runs
      exec 9>"''${STATE_DIR}/update.lock"
      if ! flock -n 9; then
        echo "==> [Auto-Update] Another nixos-auto-update instance is already running; exiting."
        exit 0
      fi

      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0="safe.directory"
      export GIT_CONFIG_VALUE_0="*"

      if [ -n "$DEPLOY_KEY_PATH" ] && [ -r "$DEPLOY_KEY_PATH" ]; then
        export GIT_SSH_COMMAND="ssh -i ''${DEPLOY_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
      else
        export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
      fi

      # Configure remotes on a repository (both origin and zita)
      configure_remotes() {
        local dir="$1"
        local origin_url="$2"
        local zita_url="$3"
        git -C "$dir" remote set-url origin "$origin_url" 2>/dev/null || git -C "$dir" remote add origin "$origin_url"
        git -C "$dir" remote set-url zita "$zita_url" 2>/dev/null || git -C "$dir" remote add zita "$zita_url"
      }

      echo "==> [Auto-Update] Synchronizing nixcfg repository in ''${REPO_DIR}..."
      if [ ! -d "''${REPO_DIR}/.git" ]; then
        rm -rf "''${REPO_DIR}"
        if [ "$HOST_NAME" != "zita" ] && git clone "$ZITA_REMOTE_URL" "''${REPO_DIR}" 2>/dev/null; then
          echo "Cloned nixcfg from zita mirror."
        else
          git clone "$ORIGIN_URL" "''${REPO_DIR}"
        fi
      fi

      configure_remotes "''${REPO_DIR}" "$ORIGIN_URL" "$ZITA_REMOTE_URL"

      # Fetch latest master from origin (falling back to zita if GitHub is unreachable, or vice-versa)
      FETCHED_REF=""
      if git -C "''${REPO_DIR}" fetch --prune origin master 2>/dev/null; then
        FETCHED_REF="origin/master"
        if [ "$HOST_NAME" != "zita" ]; then
          git -C "''${REPO_DIR}" fetch --prune zita master 2>/dev/null || true
        fi
      elif [ "$HOST_NAME" != "zita" ] && git -C "''${REPO_DIR}" fetch --prune zita master 2>/dev/null; then
        echo "WARNING: GitHub unreachable; falling back to zita git mirror." >&2
        FETCHED_REF="zita/master"
      else
        echo "ERROR: Unable to fetch nixcfg updates from either origin or zita!" >&2
        nixos-auto-update-write-status \
          "update_failed" \
          "critical" \
          "Failed to fetch nixcfg updates on ${hostname}" \
          "Unable to fetch nixcfg updates from either origin or zita."
        exit 1
      fi

      git -C "''${REPO_DIR}" reset --hard
      git -C "''${REPO_DIR}" clean -fd
      git -C "''${REPO_DIR}" checkout -f -B master "$FETCHED_REF"
      git -C "''${REPO_DIR}" reset --hard "$FETCHED_REF"
      git -C "''${REPO_DIR}" clean -fd

      # Synchronize secrets submodule and configure both origin and zita remotes on it
      echo "==> [Auto-Update] Synchronizing secrets submodule..."
      if ! git -C "''${REPO_DIR}" submodule update --init --recursive 2>/dev/null; then
        if [ "$HOST_NAME" != "zita" ]; then
          echo "Retrying secrets submodule fetch via zita mirror..."
          git -C "''${REPO_DIR}" config submodule.secrets.url "$ZITA_SECRETS_URL"
          if [ -d "''${REPO_DIR}/secrets/.git" ] || [ -f "''${REPO_DIR}/secrets/.git" ]; then
            git -C "''${REPO_DIR}/secrets" remote set-url origin "$ZITA_SECRETS_URL" 2>/dev/null || true
          fi
          if ! git -C "''${REPO_DIR}" submodule update --init --recursive; then
            echo "ERROR: Failed to update secrets submodule via zita mirror on ${hostname}!" >&2
            nixos-auto-update-write-status \
              "update_failed" \
              "critical" \
              "Failed to synchronize secrets submodule on ${hostname}" \
              "Could not update secrets submodule from origin or zita mirror."
            exit 1
          fi
        else
          echo "ERROR: Failed to update secrets submodule on ${hostname}!" >&2
          nixos-auto-update-write-status \
            "update_failed" \
            "critical" \
            "Failed to synchronize secrets submodule on ${hostname}" \
            "Could not update secrets submodule on ${hostname}."
          exit 1
        fi
      fi

      if [ -d "''${REPO_DIR}/secrets/.git" ] || [ -f "''${REPO_DIR}/secrets/.git" ]; then
        configure_remotes "''${REPO_DIR}/secrets" "$SECRETS_ORIGIN_URL" "$ZITA_SECRETS_URL"
      fi

      # Export git daemon magic file and secrets symlink for Zita mirror
      if ${lib.boolToString cfg.gitMirror.enable}; then
        touch "''${REPO_DIR}/.git/git-daemon-export-ok"
        if [ -d "''${REPO_DIR}/.git/modules/secrets" ]; then
          touch "''${REPO_DIR}/.git/modules/secrets/git-daemon-export-ok"
          ln -sfn "''${REPO_DIR}/.git/modules/secrets" "''${STATE_DIR}/nixos-secrets"
        fi
      fi

      # Also configure 'zita' remote on interactive workstation/server repo (/home/joel/Projects/nixcfg) if present
      INTERACTIVE_REPO="/home/joel/Projects/nixcfg"
      if [ -d "''${INTERACTIVE_REPO}/.git" ]; then
        git -C "''${INTERACTIVE_REPO}" remote set-url zita "ssh://joel@${cfg.zitaHost}''${INTERACTIVE_REPO}" 2>/dev/null \
          || git -C "''${INTERACTIVE_REPO}" remote add zita "ssh://joel@${cfg.zitaHost}''${INTERACTIVE_REPO}" 2>/dev/null || true
        if [ -d "''${INTERACTIVE_REPO}/secrets/.git" ] || [ -f "''${INTERACTIVE_REPO}/secrets/.git" ]; then
          git -C "''${INTERACTIVE_REPO}/secrets" remote set-url zita "$ZITA_SECRETS_URL" 2>/dev/null \
            || git -C "''${INTERACTIVE_REPO}/secrets" remote add zita "$ZITA_SECRETS_URL" 2>/dev/null || true
        fi
      fi

      # Stage Hermes runtime leaf on Zita (if enabled) before evaluating flake
      cleanup_staged_leaf() {
        git -C "''${REPO_DIR}" checkout -- modules/hermes/agent-env.nix 2>/dev/null || true
      }
      trap cleanup_staged_leaf EXIT

      if ${lib.boolToString (config.hermes.enable or false)}; then
        RUNTIME_LEAF="${config.hermes.runtimeLeafPath or "/var/lib/hermes/agent-env.nix"}"
        if [ -f "''${RUNTIME_LEAF}" ]; then
          echo "==> [Auto-Update] Validating and staging Hermes leaf from ''${RUNTIME_LEAF}..."
          if nix-instantiate --parse "''${RUNTIME_LEAF}" >/dev/null 2>&1; then
            cp "''${RUNTIME_LEAF}" "''${REPO_DIR}/modules/hermes/agent-env.nix"
          else
            echo "WARNING: Syntax error in ''${RUNTIME_LEAF}; keeping repository baseline agent-env.nix." >&2
          fi
        fi
      fi

      # Evaluate target system derivation and compare with current-system
      echo "==> [Auto-Update] Building target system closure for ${hostname}..."
      PREV_SYSTEM=$(readlink -f /run/current-system)
      if ! NEW_SYSTEM=$(nix build --no-link --print-out-paths "''${REPO_DIR}#nixosConfigurations.${hostname}.config.system.build.toplevel"); then
        echo "ERROR: Target system build failed on ${hostname}!" >&2
        nixos-auto-update-write-status \
          "update_failed" \
          "critical" \
          "Auto-update build failed on ${hostname}" \
          "Failed to build nixosConfigurations.${hostname}.config.system.build.toplevel."
        exit 1
      fi

      rollback() {
        echo "ERROR: Update or canary verification failed on ${hostname}! Rolling back to ''${PREV_SYSTEM}..." >&2
        nix-env -p /nix/var/nix/profiles/system --set "''${PREV_SYSTEM}" 2>/dev/null || true
        if "''${PREV_SYSTEM}/bin/switch-to-configuration" switch; then
          nixos-auto-update-write-status \
            "rollback_failed" \
            "critical" \
            "Update rolled back on ${hostname}" \
            "Failed to activate or pass canaries for ''${NEW_SYSTEM}; rolled back to ''${PREV_SYSTEM}."
        else
          nixos-auto-update-write-status \
            "rollback_failed" \
            "critical" \
            "CRITICAL: Update and rollback failed on ${hostname}" \
            "Failed while attempting to roll back from ''${NEW_SYSTEM} to ''${PREV_SYSTEM}."
        fi
        exit 1
      }

      if [ "''${NEW_SYSTEM}" = "''${PREV_SYSTEM}" ]; then
        echo "==> [Auto-Update] ${hostname} is already running target closure (''${NEW_SYSTEM})."
      else
        echo "==> [Auto-Update] Staging new configuration in RAM (test)..."
        if ! nixos-rebuild test --flake "''${REPO_DIR}#${hostname}"; then
          rollback
        fi

        echo "==> [Auto-Update] Running canary verification suite..."
        if ! nixos-auto-update-canary; then
          rollback
        fi

        echo "==> [Auto-Update] Persisting verified configuration (switch)..."
        if ! nixos-rebuild switch --flake "''${REPO_DIR}#${hostname}"; then
          rollback
        fi

        if ! nixos-auto-update-canary; then
          rollback
        fi
        echo "==> [Auto-Update] Successfully switched ${hostname} to ''${NEW_SYSTEM}."
      fi

      # Pre-warm Harmonia binary cache on Zita for all other fleet hosts
      if ${lib.boolToString cfg.cacheWarmer.enable}; then
        echo "==> [Cache-Warmer] Pre-building fleet closures on ${hostname} for Harmonia..."
        mkdir -p "''${STATE_DIR}/gcroots"
        for target_host in ${lib.escapeShellArgs cfg.cacheWarmer.hosts}; do
          echo "  -> Building nixosConfigurations.''${target_host}..."
          nix build --out-link "''${STATE_DIR}/gcroots/''${target_host}" "''${REPO_DIR}#nixosConfigurations.''${target_host}.config.system.build.toplevel" || \
            echo "WARNING: Cache pre-warm build failed for ''${target_host} (continuing)." >&2
        done
        echo "==> [Cache-Warmer] Fleet cache pre-warming complete."
      fi

      # Check whether a reboot is needed (comparing booted-system vs current-system kernel/initrd/params)
      BOOTED_KERNEL=$(readlink -f /run/booted-system/kernel)
      CURRENT_KERNEL=$(readlink -f /run/current-system/kernel)
      BOOTED_INITRD=$(readlink -f /run/booted-system/initrd)
      CURRENT_INITRD=$(readlink -f /run/current-system/initrd)
      BOOTED_PARAMS=$(cat /run/booted-system/kernel-params 2>/dev/null || echo "")
      CURRENT_PARAMS=$(cat /run/current-system/kernel-params 2>/dev/null || echo "")

      if [ "$BOOTED_KERNEL" = "$CURRENT_KERNEL" ] && \
         [ "$BOOTED_INITRD" = "$CURRENT_INITRD" ] && \
         [ "$BOOTED_PARAMS" = "$CURRENT_PARAMS" ]; then
        nixos-auto-update-write-status \
          "healthy" \
          "info" \
          "${hostname} is up to date" \
          "Running ''${NEW_SYSTEM} (no reboot required)."
        exit 0
      fi

      echo "==> [Auto-Update] Kernel/initrd change detected between booted-system and current-system."

      # If TPM is enabled, run pre-reboot PCR safety check
      if ${lib.boolToString (config.tpm.enable or false)}; then
        echo "==> [TPM-Guard] Running pre-reboot TPM/PCR safety check..."
        set +e
        SAFETY_OUT=$(/run/current-system/sw/bin/tpm-reenroll --check-reboot-safety 2>&1)
        SAFETY_RC=$?
        set -e
        if [ "$SAFETY_RC" -ne 0 ]; then
          echo "WARNING: Pre-reboot TPM safety check flagged a risk; skipping automatic reboot!" >&2
          echo "$SAFETY_OUT" >&2
          nixos-auto-update-write-status \
            "reboot_required_attended" \
            "critical" \
            "${hostname} requires an attended reboot (TPM PCR drift risk)" \
            "Skipped unattended reboot into ''${CURRENT_KERNEL}: ''${SAFETY_OUT}"
          exit 0
        fi
      fi

      if ! ${lib.boolToString cfg.reboot.enable}; then
        nixos-auto-update-write-status \
          "reboot_required_attended" \
          "normal" \
          "${hostname} updated kernel; reboot required at your convenience" \
          "Updated to ''${CURRENT_KERNEL} (auto-reboot disabled on this host)."
        exit 0
      fi

      # Stage safe oneshot boot entry so a panic/watchdog reset falls back to the currently booted generation
      if command -v bootctl >/dev/null 2>&1; then
        BOOT_LIST=$(bootctl list --json=short 2>/dev/null || echo "[]")
        BOOTED_ID=$(echo "$BOOT_LIST" | jq -r '.[] | select(.isSelected == true) | .id' | head -n1 || true)
        TARGET_ID=$(echo "$BOOT_LIST" | jq -r --arg sys "$NEW_SYSTEM" '.[] | select((.options // "") | contains("init=" + $sys + "/init")) | .id' | head -n1 || true)
        if [ -z "$TARGET_ID" ]; then
          TARGET_ID=$(echo "$BOOT_LIST" | jq -r '.[] | select(.isDefault == true) | .id' | head -n1 || true)
        fi
        if [ -z "$BOOTED_ID" ] || [ -z "$TARGET_ID" ] || [ "$BOOTED_ID" = "$TARGET_ID" ] || \
           ! bootctl set-default "$BOOTED_ID" || \
           ! bootctl set-oneshot "$TARGET_ID"; then
          echo "WARNING: Could not establish bootctl oneshot fallback guard (booted=''${BOOTED_ID:-none}, target=''${TARGET_ID:-none}); skipping unattended reboot!" >&2
          nixos-auto-update-write-status \
            "reboot_required_attended" \
            "critical" \
            "${hostname} requires an attended reboot (boot guard setup failed)" \
            "Could not configure bootctl default/oneshot entries for ''${NEW_SYSTEM}."
          exit 0
        fi
        echo "==> [Boot-Guard] Set known-good booted entry ($BOOTED_ID) as default and new entry ($TARGET_ID) as oneshot."
      fi

      jq -n \
        --arg target "$(readlink -f /run/current-system)" \
        --arg previous "$(readlink -f /run/booted-system)" \
        --arg scheduledAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{targetSystem: $target, previousSystem: $previous, scheduledAt: $scheduledAt}' > "''${STATE_DIR}/pending-reboot.json"

      echo "==> [Auto-Update] Scheduling maintenance reboot at ${cfg.reboot.window}..."
      shutdown -r "${cfg.reboot.window}" "NixOS auto-update scheduled kernel reboot" || true
      nixos-auto-update-write-status \
        "reboot_scheduled" \
        "info" \
        "${hostname} scheduled kernel reboot for ${cfg.reboot.window}" \
        "Will boot ''${CURRENT_KERNEL} via oneshot with post-boot canary verification."
    '';
  };

  # Tiny HTTP status server script (serves status.json on tailscale0:9105)
  statusServerScript = pkgs.writeShellApplication {
    name = "nixos-auto-update-status-server";
    runtimeInputs = with pkgs; [python3];
    text = ''
      exec python3 - "${cfg.stateDir}/status.json" "${toString cfg.statusServer.port}" << 'PYEOF'
      import http.server
      import os
      import socket
      import sys

      status_file = sys.argv[1]
      port = int(sys.argv[2])

      class StatusHandler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path not in ("/", "/status", "/status.json"):
                  self.send_response(404)
                  self.end_headers()
                  return
              if os.path.exists(status_file):
                  with open(status_file, "rb") as f:
                      data = f.read()
              else:
                  data = b'{"status":"healthy","severity":"info","summary":"No status recorded yet"}'
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(data)))
              self.end_headers()
              self.wfile.write(data)
          def log_message(self, format, *args):
              return

      class HTTPServerV6(http.server.HTTPServer):
          address_family = socket.AF_INET6

      try:
          server = HTTPServerV6(("::", port), StatusHandler)
      except Exception:
          server = http.server.HTTPServer(("0.0.0.0", port), StatusHandler)
      server.serve_forever()
      PYEOF
    '';
  };

  # KDE Plasma desktop notification poller script for workstations
  desktopNotifyScript = pkgs.writeShellApplication {
    name = "fleet-health-notify";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      libnotify
    ];
    text = ''
      set -euo pipefail

      RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/tmp}"
      SEEN_FILE="''${RUNTIME_DIR}/fleet-alerts-seen.json"
      if [ ! -f "$SEEN_FILE" ]; then
        echo "{}" > "$SEEN_FILE"
      fi

      TODAY=$(date +%Y-%m-%d)

      for host in ${lib.escapeShellArgs cfg.desktopNotifications.monitoredHosts}; do
        URL="http://''${host}.${tailnet}:${toString cfg.statusServer.port}/status.json"
        RESP=$(curl -fsS --max-time 3 "$URL" 2>/dev/null || true)
        if [ -z "$RESP" ]; then
          continue
        fi

        STATUS=$(echo "$RESP" | jq -r '.status // "healthy"' 2>/dev/null || echo "healthy")
        if [ "$STATUS" != "reboot_required_attended" ] && [ "$STATUS" != "rollback_failed" ] && [ "$STATUS" != "update_failed" ]; then
          # Clear any seen key if host recovered
          TMP_SEEN=$(mktemp)
          jq --arg h "$host" 'del(.[$h])' "$SEEN_FILE" > "$TMP_SEEN" && mv "$TMP_SEEN" "$SEEN_FILE"
          continue
        fi

        SUMMARY=$(echo "$RESP" | jq -r '.summary // "Host requires attention"')
        DETAILS=$(echo "$RESP" | jq -r '.details // ""')
        TS=$(echo "$RESP" | jq -r '.timestamp // ""')
        DEDUP_KEY="''${STATUS}:''${TS}:''${TODAY}"

        LAST_SEEN=$(jq -r --arg h "$host" '.[$h] // ""' "$SEEN_FILE")
        if [ "$LAST_SEEN" = "$DEDUP_KEY" ]; then
          continue
        fi

        URGENCY="critical"
        ICON="system-reboot"
        if [ "$STATUS" = "rollback_failed" ] || [ "$STATUS" = "update_failed" ]; then
          ICON="dialog-error"
        fi

        notify-send \
          --app-name="NixOS Fleet" \
          --urgency="$URGENCY" \
          --icon="$ICON" \
          "[$host] $SUMMARY" \
          "$DETAILS"

        TMP_SEEN=$(mktemp)
        jq --arg h "$host" --arg k "$DEDUP_KEY" '.[$h] = $k' "$SEEN_FILE" > "$TMP_SEEN" && mv "$TMP_SEEN" "$SEEN_FILE"
      done
    '';
  };
in {
  options.auto-update = {
    enable = lib.mkEnableOption "Declarative NixOS fleet auto-update with canary rollback and TPM reboot guard";

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/joelbenway/nixcfg.git";
      description = "Upstream Git repository URL for nixcfg.";
    };

    secretsRepoUrl = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:joelbenway/nixos-secrets.git";
      description = "Upstream Git repository URL for the private nixos-secrets submodule.";
    };

    zitaHost = lib.mkOption {
      type = lib.types.str;
      default = "zita.${tailnet}";
      description = "Hostname of Zita on Tailscale for secondary Git remote and binary cache.";
    };

    secretsDeployKeyPath = lib.mkOption {
      type = with lib.types; nullOr (either path str);
      default =
        if hasDeployKeySecret
        then config.age.secrets.github-secrets-deploy-key.path
        else null;
      description = "Path to the read-only SSH deploy key for fetching nixos-secrets.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixos-auto-update";
      description = "Persistent directory storing the local nixcfg checkout and status.json.";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:00:00";
      description = "Systemd OnCalendar schedule for running nixos-auto-update.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Randomized delay before starting nixos-auto-update.";
    };

    gitMirror = {
      enable = lib.mkEnableOption "Serve nixcfg and nixos-secrets read-only over git:// on tailscale0:9418";
    };

    cacheWarmer = {
      enable = lib.mkEnableOption "Pre-build fleet host closures into local Nix store for Harmonia";
      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["michael" "francis" "agnes" "jerome"];
        description = "Hostnames whose system closures should be pre-built after updating this host.";
      };
    };

    reboot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Automatically schedule a reboot during the maintenance window when kernel/initrd changes and TPM safety passes.";
      };
      window = lib.mkOption {
        type = lib.types.str;
        default = "03:30";
        description = "Time of day (HH:MM) to schedule unattended kernel reboots.";
      };
      hardwareWatchdog = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Configure systemd runtime and reboot hardware watchdog timers for automatic reset on kernel hang.";
      };
    };

    canary = {
      services = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Critical systemd services that must be active for canary verification to pass.";
      };
      checkDns = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Verify local DNS resolution (@127.0.0.1) during canary checks.";
      };
    };

    statusServer = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose /var/lib/nixos-auto-update/status.json on tailscale0 for desktop notifications.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9105;
        description = "TCP port on tailscale0 for status.json HTTP server.";
      };
    };

    desktopNotifications = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.plasma.enable or false;
        description = "Poll fleet status.json endpoints and show native KDE Plasma notifications when human attention is needed.";
      };
      monitoredHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["michael" "zita" "francis" "agnes" "jerome"];
        description = "Fleet hosts to poll for attended reboot or rollback alerts.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        updateScript
        canaryScript
        bootVerifyScript
      ];

      impermanence.directories = lib.optionals (config.impermanence.enable or false) [
        cfg.stateDir
      ];

      age.secrets = lib.mkIf hasDeployKeySecret {
        github-secrets-deploy-key = {
          file = deployKeySecretFile;
          mode = "0400";
          owner = "root";
          group = "root";
        };
      };

      systemd.services.nixos-auto-update = {
        description = "Declarative NixOS Auto-Update with Canary Rollback and TPM Guard";
        after = ["network-online.target" "tailscaled.service"];
        wants = ["network-online.target"];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${updateScript}/bin/nixos-auto-update";
        };
      };

      systemd.timers.nixos-auto-update = {
        description = "Timer for Declarative NixOS Auto-Update";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.dates;
          RandomizedDelaySec = cfg.randomizedDelaySec;
          Persistent = true;
        };
      };

      systemd.services.nixos-boot-verify = {
        description = "Verify post-boot health canaries and promote bootctl oneshot entry to default";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"] ++ (map (s: "${s}.service") cfg.canary.services);
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${bootVerifyScript}/bin/nixos-boot-verify";
        };
      };
    }

    (lib.mkIf cfg.reboot.hardwareWatchdog {
      systemd.settings.Manager = {
        RuntimeWatchdogSec = "30s";
        RebootWatchdogSec = "2m";
      };
    })

    (lib.mkIf cfg.statusServer.enable {
      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [cfg.statusServer.port];
      networking.firewall.extraInputRules = ''
        iifname "tailscale0" tcp dport ${toString cfg.statusServer.port} accept
      '';

      systemd.services.nixos-auto-update-status = {
        description = "Expose NixOS Auto-Update status.json over Tailscale";
        after = ["network.target" "tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${statusServerScript}/bin/nixos-auto-update-status-server";
          Restart = "always";
          RestartSec = "5s";
          DynamicUser = true;
          ReadOnlyPaths = [cfg.stateDir];
        };
      };
    })

    (lib.mkIf cfg.gitMirror.enable {
      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [9418];

      systemd.services.nixos-auto-update-git-mirror = {
        description = "Read-only Git daemon serving nixcfg and nixos-secrets on Tailscale";
        after = ["network.target" "tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.git}/bin/git daemon --reuseaddr --export-all --base-path=${cfg.stateDir} ${cfg.stateDir}";
          Restart = "always";
          RestartSec = "5s";
          DynamicUser = true;
          ReadOnlyPaths = [cfg.stateDir];
        };
      };
    })

    (lib.mkIf cfg.desktopNotifications.enable {
      systemd.user.services.fleet-health-notify = {
        description = "Notify KDE Plasma desktop when a NixOS fleet host requires an attended reboot or rolled back";
        after = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${desktopNotifyScript}/bin/fleet-health-notify";
        };
      };

      systemd.user.timers.fleet-health-notify = {
        description = "Periodic check for NixOS fleet health alerts in active desktop session";
        wantedBy = ["graphical-session.target"];
        timerConfig = {
          OnStartupSec = "45s";
          OnUnitActiveSec = "30m";
        };
      };
    })
  ]);
}
