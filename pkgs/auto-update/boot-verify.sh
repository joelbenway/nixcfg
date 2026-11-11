#!/usr/bin/env bash
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
set -euo pipefail

STATE_DIR="${AUTO_UPDATE_STATE_DIR:-/var/lib/nixos-auto-update}"
HOST_NAME="${AUTO_UPDATE_HOST_NAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")}"

PENDING_BOOT_FILE="${STATE_DIR}/pending-reboot.json"
STATUS_FILE="${STATE_DIR}/status.json"

# Only perform canary verification and boot promotion if a reboot was actually pending
HAS_PENDING_BOOT=false
if [ -f "$PENDING_BOOT_FILE" ]; then
  HAS_PENDING_BOOT=true
elif [ -f "$STATUS_FILE" ]; then
  CUR_STATUS=$(jq -r '.status // "healthy"' "$STATUS_FILE" 2>/dev/null || echo "healthy")
  if [ "$CUR_STATUS" = "reboot_required_attended" ] || [ "$CUR_STATUS" = "reboot_scheduled" ]; then
    HAS_PENDING_BOOT=true
  fi
fi

if [ "$HAS_PENDING_BOOT" = false ]; then
  echo "==> [Boot Verify] No pending reboot verification on ${HOST_NAME}; exiting cleanly."
  exit 0
fi

# Run host canaries on boot
if ! nixos-auto-update-canary; then
  echo "ERROR: Post-boot canary verification failed on ${HOST_NAME}!" >&2
  if [ -f "$PENDING_BOOT_FILE" ]; then
    rm -f "$PENDING_BOOT_FILE"
    nixos-auto-update-write-status \
      "rollback_failed" \
      "critical" \
      "${HOST_NAME} failed post-boot canary check after kernel update; rebooting into previous default generation" \
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
        "${HOST_NAME} successfully rebooted and verified new kernel" \
        "Booted and verified ${BOOTED_SYS}."
    else
      echo "ERROR: Failed to promote @current to default via bootctl set-default on ${HOST_NAME}!" >&2
      nixos-auto-update-write-status \
        "reboot_required_attended" \
        "critical" \
        "${HOST_NAME} failed to set verified kernel as default boot entry" \
        "bootctl set-default @current failed on ${BOOTED_SYS}. Pending reboot record retained."
    fi
  else
    echo "WARNING: Pending reboot target (${TARGET_SYS}) does not match booted system (${BOOTED_SYS}); skipping promotion." >&2
  fi
elif [ -f "$STATUS_FILE" ]; then
  CUR_STATUS=$(jq -r '.status // "healthy"' "$STATUS_FILE" 2>/dev/null || echo "healthy")
  if [ "$CUR_STATUS" = "reboot_required_attended" ] || [ "$CUR_STATUS" = "reboot_scheduled" ]; then
    if [ "$(readlink -f /run/booted-system)" = "$(readlink -f /run/current-system)" ]; then
      echo "==> Attended reboot completed; clearing status to healthy."
      nixos-auto-update-write-status \
        "healthy" \
        "info" \
        "${HOST_NAME} attended reboot completed and verified" \
        "Now running $(readlink -f /run/booted-system)."
    fi
  fi
else
  nixos-auto-update-write-status "healthy" "info" "${HOST_NAME} is healthy" ""
fi
