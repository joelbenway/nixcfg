#!/usr/bin/env bash
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
set -euo pipefail

HOST_NAME="${AUTO_UPDATE_HOST_NAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")}"
CHECK_DNS="${CANARY_CHECK_DNS:-false}"
SERVICES="${CANARY_SERVICES:-}"

echo "==> [Canary] Checking critical systemd services..."
if [ -n "$SERVICES" ]; then
  read -r -a svc_array <<<"$SERVICES"
  for svc in "${svc_array[@]}"; do
    [ -z "$svc" ] && continue
    SVC_ACTIVE=false
    for _ in 1 2 3 4 5; do
      if systemctl is-active --quiet "$svc"; then
        SVC_ACTIVE=true
        break
      fi
      sleep 2
    done
    if [ "$SVC_ACTIVE" != true ]; then
      echo "ERROR: Critical service '$svc' is not active on ${HOST_NAME}!" >&2
      exit 1
    fi
  done
fi

if [ "$CHECK_DNS" = "true" ]; then
  echo "==> [Canary] Verifying local DNS resolution and upstream forwarders..."
  DNS_OK=false
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    DNS_RES=$(dig @127.0.0.1 nixos.org +short +time=2 +tries=1 2>/dev/null || true)
    if [ -n "$DNS_RES" ] && getent hosts nixos.org >/dev/null 2>&1; then
      DNS_OK=true
      break
    fi
    sleep 2
  done
  if [ "$DNS_OK" != true ]; then
    echo "ERROR: Local DNS resolution or system hostname resolution (dig @127.0.0.1 and getent hosts nixos.org) failed on ${HOST_NAME}!" >&2
    exit 1
  fi
else
  echo "==> [Canary] Checking overall systemd state..."
  STATE=$(systemctl is-system-running 2>/dev/null || true)
  if [ "$STATE" != "running" ] && [ "$STATE" != "degraded" ] && [ "$STATE" != "starting" ]; then
    echo "ERROR: Unexpected systemd state '$STATE' on ${HOST_NAME}!" >&2
    exit 1
  fi
fi

echo "==> [Canary] All health checks passed on ${HOST_NAME}."
