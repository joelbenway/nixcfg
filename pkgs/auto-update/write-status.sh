#!/usr/bin/env bash
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
set -euo pipefail

STATUS="${1:-healthy}"
SEVERITY="${2:-info}"
SUMMARY="${3:-System is up to date}"
DETAILS="${4:-}"

STATE_DIR="${AUTO_UPDATE_STATE_DIR:-/var/lib/nixos-auto-update}"
HOST_NAME="${AUTO_UPDATE_HOST_NAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")}"
STATUS_FILE="${STATE_DIR}/status.json"
mkdir -p "${STATE_DIR}"

TODAY=$(date -u +%Y-%m-%d)
PREV_STATUS=""
PREV_SUMMARY=""
PREV_NOTIFIED_DATE=""
if [ -f "$STATUS_FILE" ]; then
  PREV_STATUS=$(jq -r '.status // ""' "$STATUS_FILE" 2>/dev/null || echo "")
  PREV_SUMMARY=$(jq -r '.summary // ""' "$STATUS_FILE" 2>/dev/null || echo "")
  PREV_NOTIFIED_DATE=$(jq -r '.lastNotifiedDate // ""' "$STATUS_FILE" 2>/dev/null || echo "")
fi

SHOULD_NOTIFY=false
TOPIC="fleet-alerts"
PRIORITY="default"
TAGS=""

case "$STATUS" in
  update_failed | rollback_failed | boot_verify_failed)
    SHOULD_NOTIFY=true
    TOPIC="fleet-alerts"
    PRIORITY="urgent"
    TAGS="rotating_light,nix"
    ;;
  reboot_required_attended)
    if [ "$PREV_STATUS" != "$STATUS" ] || [ "$PREV_SUMMARY" != "$SUMMARY" ] || [ "$PREV_NOTIFIED_DATE" != "$TODAY" ]; then
      SHOULD_NOTIFY=true
    fi
    if [ "$SEVERITY" = "critical" ]; then
      TOPIC="fleet-alerts"
      PRIORITY="high"
      TAGS="warning,arrows_counterclockwise"
    else
      TOPIC="fleet-updates"
      PRIORITY="default"
      TAGS="arrows_counterclockwise"
    fi
    ;;
  reboot_scheduled)
    if [ "$PREV_STATUS" != "$STATUS" ] || [ "$PREV_SUMMARY" != "$SUMMARY" ] || [ "$PREV_NOTIFIED_DATE" != "$TODAY" ]; then
      SHOULD_NOTIFY=true
    fi
    TOPIC="fleet-updates"
    PRIORITY="low"
    TAGS="clock3"
    ;;
  healthy)
    case "$PREV_STATUS" in
      update_failed | rollback_failed | boot_verify_failed | reboot_required_attended | reboot_scheduled)
        SHOULD_NOTIFY=true
        TOPIC="fleet-updates"
        PRIORITY="low"
        TAGS="white_check_mark"
        ;;
    esac
    ;;
esac

LAST_NOTIFIED_DATE="$PREV_NOTIFIED_DATE"
if [ "$SHOULD_NOTIFY" = true ]; then
  LAST_NOTIFIED_DATE="$TODAY"
fi

BOOTED_SYS=$(readlink -f /run/booted-system 2>/dev/null || echo "unknown")
CURRENT_SYS=$(readlink -f /run/current-system 2>/dev/null || echo "unknown")
BOOTED_KERNEL=$(readlink -f /run/booted-system/kernel 2>/dev/null || echo "unknown")
CURRENT_KERNEL=$(readlink -f /run/current-system/kernel 2>/dev/null || echo "unknown")

TMP_FILE=$(mktemp "${STATE_DIR}/status.json.XXXXXX")
jq -n \
  --arg host "$HOST_NAME" \
  --arg status "$STATUS" \
  --arg severity "$SEVERITY" \
  --arg summary "$SUMMARY" \
  --arg details "$DETAILS" \
  --arg bootedSystem "$BOOTED_SYS" \
  --arg currentSystem "$CURRENT_SYS" \
  --arg bootedKernel "$BOOTED_KERNEL" \
  --arg currentKernel "$CURRENT_KERNEL" \
  --arg lastNotifiedDate "$LAST_NOTIFIED_DATE" \
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
    lastNotifiedDate: $lastNotifiedDate,
    timestamp: $timestamp
  }' >"$TMP_FILE"
chmod 0644 "$TMP_FILE"
mv "$TMP_FILE" "$STATUS_FILE"

if [ "$SHOULD_NOTIFY" = true ] && command -v fleet-notify >/dev/null 2>&1; then
  fleet-notify \
    --best-effort \
    --topic "$TOPIC" \
    --priority "$PRIORITY" \
    --tags "$TAGS" \
    --title "[${HOST_NAME}] ${SUMMARY}" \
    -- "${DETAILS:-${SUMMARY}}"
fi
