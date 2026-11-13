#!/usr/bin/env bash
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Note: Running without root privileges. Some SMART data requires root."
  echo "If drive queries fail or appear as 'REQUIRES ROOT', rerun as: sudo disk-health"
  echo ""
fi

echo "================================================================================"
echo "                           STORAGE DRIVE HEALTH SUMMARY                          "
echo "================================================================================"
printf "%-14s %-20s %-16s %-14s %-8s %-10s\n" "DEVICE" "MODEL" "SERIAL" "HEALTH" "TEMP" "SECTORS"
echo "--------------------------------------------------------------------------------"

# Collect unique block and character devices from smartctl --scan and /dev/nvme*
declare -A seen_devices

while IFS= read -r line; do
  [ -z "$line" ] && continue
  dev=$(echo "$line" | awk '{print $1}')
  [ -z "$dev" ] || [ ! -e "$dev" ] && continue
  [ "${seen_devices[$dev]:-}" = "1" ] && continue
  seen_devices["$dev"]=1

  info=$(smartctl -i "$dev" 2>&1 || true)
  health=$(smartctl -H "$dev" 2>&1 || true)
  attrs=$(smartctl -A "$dev" 2>&1 || true)

  model=$(echo "$info" | awk -F: '/Device Model:|Product:|Model Number:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  [ -z "$model" ] && model="Unknown"
  model="${model:0:19}"

  serial=$(echo "$info" | awk -F: '/Serial Number:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  [ -z "$serial" ] && serial="Unknown"
  serial="${serial:0:15}"

  status="UNKNOWN"
  if echo "$health" | grep -qi "Permission denied"; then
    status="NEED ROOT"
  elif echo "$health" | grep -qi "PASSED\|OK"; then
    status="PASSED"
  elif echo "$health" | grep -qi "FAILED"; then
    status="FAILED"
  fi

  temp=$(echo "$attrs" | awk '/Temperature_Celsius|Airflow_Temperature|Temperature:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $i > 0 && $i < 150) {print $i; exit}}')
  if [ -z "$temp" ]; then
    temp=$(echo "$health" | awk '/Temperature:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $i > 0 && $i < 150) {print $i; exit}}')
  fi
  if [ -n "$temp" ]; then
    temp="${temp}°C"
  else
    temp="N/A"
  fi

  # Check pending or reallocated sectors (SATA/HDD) and media/data errors (NVMe)
  realloc=$(echo "$attrs" | awk '/Reallocated_Sector_Ct/ {print $10; exit}')
  pending=$(echo "$attrs" | awk '/Current_Pending_Sector/ {print $10; exit}')
  media_err=$(echo "$attrs" | awk '/Media and Data Integrity Errors:/ {print $NF; exit}')
  crit_warn=$(echo "$attrs" | awk '/Critical Warning:/ {print $NF; exit}')

  sectors="0"
  if [ -n "$realloc" ] && [ "$realloc" -gt 0 ] 2>/dev/null; then
    sectors="R:${realloc}"
  fi
  if [ -n "$pending" ] && [ "$pending" -gt 0 ] 2>/dev/null; then
    sectors="${sectors} P:${pending}"
  fi
  if [ -n "$media_err" ] && [ "$media_err" != "0" ] && [ "$media_err" != "" ]; then
    sectors="Err:${media_err}"
  fi
  if [ -n "$crit_warn" ] && [ "$crit_warn" != "0x00" ] && [ "$crit_warn" != "0" ] && [ "$crit_warn" != "" ]; then
    sectors="${sectors} Warn:${crit_warn}"
  fi

  printf "%-14s %-20s %-16s %-14s %-8s %-10s\n" "$dev" "$model" "$serial" "$status" "$temp" "$sectors"
done < <(
  smartctl --scan 2>/dev/null | grep -v "^#" || true
  for d in /dev/nvme[0-9]*; do
    [ -c "$d" ] && echo "$d"
  done
)

echo "================================================================================"
echo "Short Self-Test: smartctl -t short <device>"
echo "Long Self-Test:  smartctl -t long <device>"
echo "Detailed SMART:  smartctl -x <device>"
