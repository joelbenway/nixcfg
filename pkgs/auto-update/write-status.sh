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
  }' >"$TMP_FILE"
chmod 0644 "$TMP_FILE"
mv "$TMP_FILE" "$STATUS_FILE"
