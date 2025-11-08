#!/usr/bin/env bash
# scripts/factory-status.sh
set -euo pipefail

echo "=== TARPN RPi-OEM Factory Status ==="
echo

# --- Basic system info ---
echo "[system]"
echo "  Hostname      : $(hostname)"
if command -v hostnamectl >/dev/null 2>&1; then
  echo "  Pretty name   : $(hostnamectl --static 2>/dev/null || true)"
  echo "  Chassis/VM    : $(hostnamectl | awk -F: '/Virtualization/ {gsub(/^[ \t]+/,\"\",$2); print $2}' 2>/dev/null || echo '?')"
fi
echo

# --- Virtualization detection ---
echo "[virtualization]"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
else
  VIRT="unknown"
fi
echo "  Detected type : ${VIRT}"
echo

# --- Guest tools per hypervisor ---
echo "[guest tools]"
case "$VIRT" in
  kvm|qemu)
    echo "  Expect: qemu-guest-agent, spice-vdagent"
    systemctl is-active qemu-guest-agent >/dev/null 2>&1 && \
      echo "  qemu-guest-agent : active" || echo "  qemu-guest-agent : NOT active"
    ;;
  oracle|virtualbox)
    echo "  Expect: virtualbox-guest-dkms, virtualbox-guest-utils"
    dpkg -s virtualbox-guest-dkms >/dev/null 2>&1 && \
      echo "  virtualbox-guest-dkms : installed" || echo "  virtualbox-guest-dkms : NOT installed"
    dpkg -s virtualbox-guest-utils >/dev/null 2>&1 && \
      echo "  virtualbox-guest-utils: installed" || echo "  virtualbox-guest-utils: NOT installed"
    ;;
  vmware)
    echo "  Expect: open-vm-tools"
    systemctl is-active open-vm-tools >/dev/null 2>&1 && \
      echo "  open-vm-tools : active" || echo "  open-vm-tools : NOT active"
    ;;
  microsoft)
    echo "  Expect: Hyper-V daemons (best-effort)"
    dpkg -l | grep -E 'hyperv|linux-cloud-tools' >/dev/null 2>&1 && \
      echo "  Hyper-V tools : present (check dpkg -l for details)" || \
      echo "  Hyper-V tools : not detected"
    ;;
  *)
    echo "  No specific guest tools expected for: ${VIRT}"
    ;;
esac
echo

# --- Avahi / mDNS status ---
echo "[network / mDNS]"
if systemctl is-active avahi-daemon >/dev/null 2>&1; then
  echo "  avahi-daemon : active"
else
  echo "  avahi-daemon : NOT active"
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "  IPv4 address : ${IP:-unknown}"

if [ -f /etc/avahi/hosts ]; then
  echo "  /etc/avahi/hosts:"
  sed 's/^/    /' /etc/avahi/hosts
else
  echo "  /etc/avahi/hosts: (none)"
fi
echo

# --- Project tree / repo health ---
echo "[project]"
PROJECT_DIR="/srv/TARPN-Contrib/rpi-oem"
REPO_DIR="/srv/TARPN-Contrib"

if [ -d "$PROJECT_DIR" ]; then
  echo "  Project dir   : ${PROJECT_DIR}"
else
  echo "  Project dir   : MISSING (${PROJECT_DIR})"
fi

if [ -d "${REPO_DIR}/.git" ]; then
  cd "${REPO_DIR}"
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
  echo "  Git status    : branch ${BRANCH}, commit ${COMMIT}"
else
  echo "  Git status    : NOT a git repo in ${REPO_DIR}"
fi
echo

# --- Factory tools ---
echo "[factory tools]"
for cmd in rpi-build rpi-test; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  ${cmd} : $(command -v "$cmd")"
  else
    echo "  ${cmd} : NOT found"
  fi
done

STATUS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/factory-status.sh"
echo "  factory-status script : ${STATUS_SCRIPT}"
echo

# --- Bootstrap log ---
echo "[bootstrap log]"
if [ -f /root/factory-bootstrap.log ]; then
  echo "  /root/factory-bootstrap.log (last 10 lines):"
  tail -n 10 /root/factory-bootstrap.log | sed 's/^/    /'
else
  echo "  /root/factory-bootstrap.log : not found"
fi

echo
echo "=== End of factory status ==="
