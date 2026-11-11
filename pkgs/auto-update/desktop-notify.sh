#!/usr/bin/env bash
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
set -euo pipefail

TAILNET="${FLEET_NOTIFY_TAILNET:-gentoo-humboldt.ts.net}"
PORT="${FLEET_NOTIFY_PORT:-9105}"
HOSTS="${FLEET_NOTIFY_HOSTS:-}"

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
SEEN_FILE="${RUNTIME_DIR}/fleet-alerts-seen.json"
if [ ! -f "$SEEN_FILE" ]; then
  echo "{}" >"$SEEN_FILE"
fi

TODAY=$(date +%Y-%m-%d)

if [ -n "$HOSTS" ]; then
  read -r -a host_array <<<"$HOSTS"
  for host in "${host_array[@]}"; do
    [ -z "$host" ] && continue
    RESP=""
    for target in "${host}.${TAILNET}" "${host}.skylab.home" "${host}"; do
      URL="http://${target}:${PORT}/status.json"
      if RESP=$(curl -fsS --max-time 2 "$URL" 2>/dev/null); then
        [ -n "$RESP" ] && break
      fi
    done
    if [ -z "$RESP" ]; then
      continue
    fi

    STATUS=$(echo "$RESP" | jq -r '.status // "healthy"' 2>/dev/null || echo "healthy")
    if [ "$STATUS" != "reboot_required_attended" ] && [ "$STATUS" != "rollback_failed" ] && [ "$STATUS" != "update_failed" ]; then
      # Clear any seen key if host recovered
      TMP_SEEN=$(mktemp)
      jq --arg h "$host" 'del(.[$h])' "$SEEN_FILE" >"$TMP_SEEN" && mv "$TMP_SEEN" "$SEEN_FILE"
      continue
    fi

    SUMMARY=$(echo "$RESP" | jq -r '.summary // "Host requires attention"')
    DETAILS=$(echo "$RESP" | jq -r '.details // ""')
    TS=$(echo "$RESP" | jq -r '.timestamp // ""')
    DEDUP_KEY="${STATUS}:${TS}:${TODAY}"

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
    jq --arg h "$host" --arg k "$DEDUP_KEY" '.[$h] = $k' "$SEEN_FILE" >"$TMP_SEEN" && mv "$TMP_SEEN" "$SEEN_FILE"
  done
fi
