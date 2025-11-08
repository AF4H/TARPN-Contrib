#!/usr/bin/env bash
# scripts/setup-build-host.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (or via sudo)." >&2
  exit 1
fi

echo "[setup-build-host] Updating apt..."
apt-get update -y

DEPS=(
  git
  ca-certificates
  curl
  wget
  qemu-system-arm
  qemu-system-misc
  qemu-user-static
  qemu-utils
  binfmt-support
  kpartx
  losetup
  parted
  dosfstools
  e2fsprogs
  rsync
  xz-utils
  vim
  less
)

echo "[setup-build-host] Installing deps: ${DEPS[*]}"
apt-get install -y "${DEPS[@]}" || {
  echo "[setup-build-host] Failed to install dependencies." >&2
  exit 1
}

echo "[setup-build-host] Enabling binfmt handlers (if needed)..."
# Usually automatic when installing qemu-user-static, but no harm re-running.
update-binfmts --enable qemu-arm || true
update-binfmts --enable qemu-aarch64 || true

echo "[setup-build-host] Done."
