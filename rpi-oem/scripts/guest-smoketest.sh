#!/usr/bin/env bash
set -e

echo "[smoketest] Hostname:"
hostname

echo "[smoketest] Uname:"
uname -a

if [ -f /etc/os-release ]; then
  echo "[smoketest] /etc/os-release:"
  cat /etc/os-release
fi

if [ -f /etc/oem-release ]; then
  echo "[smoketest] /etc/oem-release:"
  cat /etc/oem-release
fi

echo "[smoketest] Checking SSH service..."
if systemctl is-active ssh >/dev/null 2>&1; then
  echo "[smoketest] ssh is active"
else
  echo "FAIL: ssh service not active"
  exit 1
fi

# Optional: check for a custom service if you add one later
# if systemctl list-units | grep -q 'tarpn-oem.service'; then
#   echo "[smoketest] tarpn-oem.service present; checking status..."
#   systemctl is-active tarpn-oem.service >/dev/null 2>&1 || {
#     echo "FAIL: tarpn-oem.service not active"
#     exit 1
#   }
# fi

echo "PASS"
