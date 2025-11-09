#!/usr/bin/env bash
# scripts/setup-build-host.sh
# Prepare Debian 13 amd64 host for building Raspberry Pi OEM images.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[setup-build-host] Preparing build host..."

if [ "$(id -u)" -ne 0 ]; then
  echo "[setup-build-host] ERROR: must be run as root." >&2
  exit 1
fi

apt-get update -y

DEPS=(
  # Core tools
  git curl wget ca-certificates sudo gnupg lsb-release

  # Filesystem + loop + partition tools
  util-linux kpartx parted dosfstools e2fsprogs rsync

  # Emulation / chroot for ARM
  qemu-user-static binfmt-support

  # Compression / decompression
  xz-utils gzip unzip bzip2

  # Build tools (for iPXE, etc.)
  make gcc binutils liblzma-dev xorriso syslinux-utils isolinux

  # Helpers
  vim less net-tools iproute2
)

echo "[setup-build-host] Installing packages: ${DEPS[*]}"
apt-get install -y "${DEPS[@]}"

# Ensure binfmt_misc is enabled for qemu-user-static
if [ -d /proc/sys/fs/binfmt_misc ]; then
  if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
    echo "[setup-build-host] Mounting binfmt_misc..."
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
  fi
fi

echo "[setup-build-host] Build host prepared."
