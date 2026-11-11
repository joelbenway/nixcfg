#!/usr/bin/env bash
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
set -euo pipefail

HOST_NAME="${AUTO_UPDATE_HOST_NAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")}"
STATE_DIR="${AUTO_UPDATE_STATE_DIR:-/var/lib/nixos-auto-update}"
REPO_DIR="${STATE_DIR}/nixcfg"
ZITA_HOST="${AUTO_UPDATE_ZITA_HOST:-zita.skylab.home}"
ZITA_REMOTE_URL="git://${ZITA_HOST}:9418/nixcfg"
ZITA_SECRETS_URL="git://${ZITA_HOST}:9418/nixos-secrets"
ORIGIN_URL="${AUTO_UPDATE_REPO_URL:-https://github.com/joelbenway/nixcfg.git}"
SECRETS_ORIGIN_URL="${AUTO_UPDATE_SECRETS_REPO_URL:-git@github.com:joelbenway/nixos-secrets.git}"
DEPLOY_KEY_PATH="${AUTO_UPDATE_DEPLOY_KEY_PATH:-}"
GIT_MIRROR_ENABLE="${AUTO_UPDATE_GIT_MIRROR:-false}"
HERMES_ENABLE="${AUTO_UPDATE_HERMES_ENABLE:-false}"
HERMES_RUNTIME_LEAF="${AUTO_UPDATE_HERMES_LEAF:-/var/lib/hermes/agent-env.nix}"
CACHE_WARMER_ENABLE="${AUTO_UPDATE_CACHE_WARMER:-false}"
CACHE_WARMER_HOSTS="${AUTO_UPDATE_CACHE_WARMER_HOSTS:-}"
TPM_ENABLE="${AUTO_UPDATE_TPM_ENABLE:-false}"
REBOOT_ENABLE="${AUTO_UPDATE_REBOOT_ENABLE:-true}"
REBOOT_WINDOW="${AUTO_UPDATE_REBOOT_WINDOW:-03:30}"

mkdir -p "${STATE_DIR}"

# Serialize updater executions across manual and timer-driven runs
exec 9>"${STATE_DIR}/update.lock"
if ! flock -n 9; then
  echo "==> [Auto-Update] Another nixos-auto-update instance is already running; exiting."
  exit 0
fi

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="safe.directory"
export GIT_CONFIG_VALUE_0="*"

if [ -n "$DEPLOY_KEY_PATH" ] && [ -r "$DEPLOY_KEY_PATH" ]; then
  export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
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

echo "==> [Auto-Update] Synchronizing nixcfg repository in ${REPO_DIR}..."
if [ ! -d "${REPO_DIR}/.git" ]; then
  rm -rf "${REPO_DIR}"
  if [ "$HOST_NAME" != "zita" ] && git clone "$ZITA_REMOTE_URL" "${REPO_DIR}" 2>/dev/null; then
    echo "Cloned nixcfg from zita mirror."
  else
    git clone "$ORIGIN_URL" "${REPO_DIR}"
  fi
fi

configure_remotes "${REPO_DIR}" "$ORIGIN_URL" "$ZITA_REMOTE_URL"

# Wait for network connectivity (up to 45 seconds, e.g. on resume from sleep)
echo "==> [Auto-Update] Verifying network connectivity before fetching..."
NET_OK=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if git ls-remote "$ORIGIN_URL" HEAD >/dev/null 2>&1 ||
    ([ "$HOST_NAME" != "zita" ] && git ls-remote "$ZITA_REMOTE_URL" HEAD >/dev/null 2>&1); then
    NET_OK=true
    break
  fi
  sleep 3
done

if [ "$NET_OK" != true ]; then
  echo "WARNING: Network not reachable after 45s wait; proceeding with fetch attempt..." >&2
fi

# Fetch latest master from origin (falling back to zita if GitHub is unreachable, or vice-versa)
FETCHED_REF=""
FETCH_ERROR=""
if FETCH_OUT=$(git -C "${REPO_DIR}" fetch --prune origin master 2>&1); then
  FETCHED_REF="origin/master"
  if [ "$HOST_NAME" != "zita" ]; then
    git -C "${REPO_DIR}" fetch --prune zita master >/dev/null 2>&1 || true
  fi
else
  FETCH_ERROR="origin: ${FETCH_OUT}"
  if [ "$HOST_NAME" != "zita" ]; then
    if ZITA_FETCH_OUT=$(git -C "${REPO_DIR}" fetch --prune zita master 2>&1); then
      echo "WARNING: GitHub unreachable; falling back to zita git mirror." >&2
      FETCHED_REF="zita/master"
    else
      FETCH_ERROR="${FETCH_ERROR} | zita: ${ZITA_FETCH_OUT}"
    fi
  fi
fi

if [ -z "$FETCHED_REF" ]; then
  echo "ERROR: Unable to fetch nixcfg updates from either origin or zita!" >&2
  echo "$FETCH_ERROR" >&2
  nixos-auto-update-write-status \
    "update_failed" \
    "critical" \
    "Failed to fetch nixcfg updates on ${HOST_NAME}" \
    "Unable to fetch nixcfg updates from either origin or zita: ${FETCH_ERROR}"
  exit 1
fi

git -C "${REPO_DIR}" reset --hard
git -C "${REPO_DIR}" clean -fd
git -C "${REPO_DIR}" checkout -f -B master "$FETCHED_REF"
git -C "${REPO_DIR}" reset --hard "$FETCHED_REF"
git -C "${REPO_DIR}" clean -fd

# Synchronize secrets submodule and configure both origin and zita remotes on it
echo "==> [Auto-Update] Synchronizing secrets submodule..."
if ! SUB_OUT=$(git -C "${REPO_DIR}" submodule update --init --recursive 2>&1); then
  if [ "$HOST_NAME" != "zita" ]; then
    echo "Retrying secrets submodule fetch via zita mirror..."
    git -C "${REPO_DIR}" config submodule.secrets.url "$ZITA_SECRETS_URL"
    if [ -d "${REPO_DIR}/secrets/.git" ] || [ -f "${REPO_DIR}/secrets/.git" ]; then
      git -C "${REPO_DIR}/secrets" remote set-url origin "$ZITA_SECRETS_URL" 2>/dev/null || true
    fi
    if ! SUB_ZITA_OUT=$(git -C "${REPO_DIR}" submodule update --init --recursive 2>&1); then
      echo "ERROR: Failed to update secrets submodule via zita mirror on ${HOST_NAME}!" >&2
      echo "$SUB_ZITA_OUT" >&2
      nixos-auto-update-write-status \
        "update_failed" \
        "critical" \
        "Failed to synchronize secrets submodule on ${HOST_NAME}" \
        "Could not update secrets submodule from origin (${SUB_OUT}) or zita mirror (${SUB_ZITA_OUT})."
      exit 1
    fi
  else
    echo "ERROR: Failed to update secrets submodule on ${HOST_NAME}!" >&2
    echo "$SUB_OUT" >&2
    nixos-auto-update-write-status \
      "update_failed" \
      "critical" \
      "Failed to synchronize secrets submodule on ${HOST_NAME}" \
      "Could not update secrets submodule on ${HOST_NAME}: ${SUB_OUT}"
    exit 1
  fi
fi

if [ -d "${REPO_DIR}/secrets/.git" ] || [ -f "${REPO_DIR}/secrets/.git" ]; then
  configure_remotes "${REPO_DIR}/secrets" "$SECRETS_ORIGIN_URL" "$ZITA_SECRETS_URL"
fi

# Export git daemon magic file and secrets symlink for Zita mirror
if [ "$GIT_MIRROR_ENABLE" = "true" ]; then
  touch "${REPO_DIR}/.git/git-daemon-export-ok"
  if [ -d "${REPO_DIR}/.git/modules/secrets" ]; then
    touch "${REPO_DIR}/.git/modules/secrets/git-daemon-export-ok"
    ln -sfn "${REPO_DIR}/.git/modules/secrets" "${STATE_DIR}/nixos-secrets"
  fi
fi

# Also configure 'zita' remote on interactive workstation/server repo (/home/joel/Projects/nixcfg) if present
INTERACTIVE_REPO="/home/joel/Projects/nixcfg"
if [ -d "${INTERACTIVE_REPO}/.git" ]; then
  git -C "${INTERACTIVE_REPO}" remote set-url zita "ssh://joel@${ZITA_HOST}${INTERACTIVE_REPO}" 2>/dev/null ||
    git -C "${INTERACTIVE_REPO}" remote add zita "ssh://joel@${ZITA_HOST}${INTERACTIVE_REPO}" 2>/dev/null || true
  if [ -d "${INTERACTIVE_REPO}/secrets/.git" ] || [ -f "${INTERACTIVE_REPO}/secrets/.git" ]; then
    git -C "${INTERACTIVE_REPO}/secrets" remote set-url zita "$ZITA_SECRETS_URL" 2>/dev/null ||
      git -C "${INTERACTIVE_REPO}/secrets" remote add zita "$ZITA_SECRETS_URL" 2>/dev/null || true
  fi
fi

# Stage Hermes runtime leaf on Zita (if enabled) before evaluating flake
cleanup_staged_leaf() {
  git -C "${REPO_DIR}" checkout -- modules/hermes/agent-env.nix 2>/dev/null || true
}
trap cleanup_staged_leaf EXIT

if [ "$HERMES_ENABLE" = "true" ]; then
  RUNTIME_LEAF="$HERMES_RUNTIME_LEAF"
  if [ -f "${RUNTIME_LEAF}" ]; then
    echo "==> [Auto-Update] Validating and staging Hermes leaf from ${RUNTIME_LEAF}..."
    if nix-instantiate --parse "${RUNTIME_LEAF}" >/dev/null 2>&1; then
      cp "${RUNTIME_LEAF}" "${REPO_DIR}/modules/hermes/agent-env.nix"
    else
      echo "WARNING: Syntax error in ${RUNTIME_LEAF}; keeping repository baseline agent-env.nix." >&2
    fi
  fi
fi

# Evaluate target system derivation and compare with current-system
echo "==> [Auto-Update] Building target system closure for ${HOST_NAME}..."
PREV_SYSTEM=$(readlink -f /run/current-system)
if ! NEW_SYSTEM=$(nix build --no-link --print-out-paths "${REPO_DIR}#nixosConfigurations.${HOST_NAME}.config.system.build.toplevel"); then
  echo "ERROR: Target system build failed on ${HOST_NAME}!" >&2
  nixos-auto-update-write-status \
    "update_failed" \
    "critical" \
    "Auto-update build failed on ${HOST_NAME}" \
    "Failed to build nixosConfigurations.${HOST_NAME}.config.system.build.toplevel."
  exit 1
fi

rollback() {
  echo "ERROR: Update or canary verification failed on ${HOST_NAME}! Rolling back to ${PREV_SYSTEM}..." >&2
  nix-env -p /nix/var/nix/profiles/system --set "${PREV_SYSTEM}" 2>/dev/null || true
  if "${PREV_SYSTEM}/bin/switch-to-configuration" switch; then
    nixos-auto-update-write-status \
      "rollback_failed" \
      "critical" \
      "Update rolled back on ${HOST_NAME}" \
      "Failed to activate or pass canaries for ${NEW_SYSTEM}; rolled back to ${PREV_SYSTEM}."
  else
    nixos-auto-update-write-status \
      "rollback_failed" \
      "critical" \
      "CRITICAL: Update and rollback failed on ${HOST_NAME}" \
      "Failed while attempting to roll back from ${NEW_SYSTEM} to ${PREV_SYSTEM}."
  fi
  exit 1
}

if [ "${NEW_SYSTEM}" = "${PREV_SYSTEM}" ]; then
  echo "==> [Auto-Update] ${HOST_NAME} is already running target closure (${NEW_SYSTEM})."
else
  echo "==> [Auto-Update] Staging new configuration in RAM (test)..."
  if ! nixos-rebuild test --flake "${REPO_DIR}#${HOST_NAME}"; then
    rollback
  fi

  echo "==> [Auto-Update] Running canary verification suite..."
  if ! nixos-auto-update-canary; then
    rollback
  fi

  echo "==> [Auto-Update] Persisting verified configuration (switch)..."
  if ! nixos-rebuild switch --flake "${REPO_DIR}#${HOST_NAME}"; then
    rollback
  fi

  if ! nixos-auto-update-canary; then
    rollback
  fi
  echo "==> [Auto-Update] Successfully switched ${HOST_NAME} to ${NEW_SYSTEM}."
fi

# Pre-warm Harmonia binary cache on Zita for all other fleet hosts
if [ "$CACHE_WARMER_ENABLE" = "true" ]; then
  echo "==> [Cache-Warmer] Pre-building fleet closures on ${HOST_NAME} for Harmonia..."
  mkdir -p "${STATE_DIR}/gcroots"
  if [ -n "$CACHE_WARMER_HOSTS" ]; then
    read -r -a warmer_array <<<"$CACHE_WARMER_HOSTS"
    for target_host in "${warmer_array[@]}"; do
      [ -z "$target_host" ] && continue
      echo "  -> Building nixosConfigurations.${target_host}..."
      nix build --out-link "${STATE_DIR}/gcroots/${target_host}" "${REPO_DIR}#nixosConfigurations.${target_host}.config.system.build.toplevel" ||
        echo "WARNING: Cache pre-warm build failed for ${target_host} (continuing)." >&2
    done
  fi
  echo "==> [Cache-Warmer] Fleet cache pre-warming complete."
fi

# Check whether a reboot is needed (comparing booted-system vs current-system kernel/initrd/params)
BOOTED_KERNEL=$(readlink -f /run/booted-system/kernel)
CURRENT_KERNEL=$(readlink -f /run/current-system/kernel)
BOOTED_INITRD=$(readlink -f /run/booted-system/initrd)
CURRENT_INITRD=$(readlink -f /run/current-system/initrd)
BOOTED_PARAMS=$(cat /run/booted-system/kernel-params 2>/dev/null || echo "")
CURRENT_PARAMS=$(cat /run/current-system/kernel-params 2>/dev/null || echo "")

if [ "$BOOTED_KERNEL" = "$CURRENT_KERNEL" ] &&
  [ "$BOOTED_INITRD" = "$CURRENT_INITRD" ] &&
  [ "$BOOTED_PARAMS" = "$CURRENT_PARAMS" ]; then
  nixos-auto-update-write-status \
    "healthy" \
    "info" \
    "${HOST_NAME} is up to date" \
    "Running ${NEW_SYSTEM} (no reboot required)."
  exit 0
fi

echo "==> [Auto-Update] Kernel/initrd change detected between booted-system and current-system."

# If TPM is enabled, run pre-reboot PCR safety check
if [ "$TPM_ENABLE" = "true" ]; then
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
      "${HOST_NAME} requires an attended reboot (TPM PCR drift risk)" \
      "Skipped unattended reboot into ${CURRENT_KERNEL}: ${SAFETY_OUT}"
    exit 0
  fi
fi

if [ "$REBOOT_ENABLE" != "true" ]; then
  nixos-auto-update-write-status \
    "reboot_required_attended" \
    "normal" \
    "${HOST_NAME} updated kernel; reboot required at your convenience" \
    "Updated to ${CURRENT_KERNEL} (auto-reboot disabled on this host)."
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
  if [ -z "$BOOTED_ID" ] || [ -z "$TARGET_ID" ] || [ "$BOOTED_ID" = "$TARGET_ID" ] ||
    ! bootctl set-default "$BOOTED_ID" ||
    ! bootctl set-oneshot "$TARGET_ID"; then
    echo "WARNING: Could not establish bootctl oneshot fallback guard (booted=${BOOTED_ID:-none}, target=${TARGET_ID:-none}); skipping unattended reboot!" >&2
    nixos-auto-update-write-status \
      "reboot_required_attended" \
      "critical" \
      "${HOST_NAME} requires an attended reboot (boot guard setup failed)" \
      "Could not configure bootctl default/oneshot entries for ${NEW_SYSTEM}."
    exit 0
  fi
  echo "==> [Boot-Guard] Set known-good booted entry ($BOOTED_ID) as default and new entry ($TARGET_ID) as oneshot."
fi

jq -n \
  --arg target "$(readlink -f /run/current-system)" \
  --arg previous "$(readlink -f /run/booted-system)" \
  --arg scheduledAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{targetSystem: $target, previousSystem: $previous, scheduledAt: $scheduledAt}' >"${STATE_DIR}/pending-reboot.json"

echo "==> [Auto-Update] Scheduling maintenance reboot at ${REBOOT_WINDOW}..."
shutdown -r "${REBOOT_WINDOW}" "NixOS auto-update scheduled kernel reboot" || true
nixos-auto-update-write-status \
  "reboot_scheduled" \
  "info" \
  "${HOST_NAME} scheduled kernel reboot for ${REBOOT_WINDOW}" \
  "Will boot ${CURRENT_KERNEL} via oneshot with post-boot canary verification."
