#!/usr/bin/env bash
# setup-build-host.sh
# Installs all packages required to build and customize Raspberry Pi OEM images.
# Safe to re-run; it only installs missing packages.

set -euo pipefail

echo "[setup-build-host] Starting setup for build host..."
export DEBIAN_FRONTEND=noninteractive

# -------------------------------------------------------------------
# Dependency list
# -------------------------------------------------------------------
DEPS=(
  # Core build & system utilities
  git curl wget sudo ca-certificates gnupg lsb-release

  # Loopback and filesystem tools
  kpartx losetup util-linux mount rsync parted dosfstools e2fsprogs

  # Emulation / chroot for ARM images
  qemu-user-static binfmt-support

  # Compression / decompression tools
  xz-utils gzip unzip bzip2

  # Debugging and editing utilities
  vim less

  # Networking helpers (for robust fetch / debugging)
  net-tools iproute2
)

MISSING=()
for pkg in "${DEPS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING+=("$pkg")
  fi
done

if (( ${#MISSING[@]} > 0 )); then
  echo "[setup-build-host] Missing packages: ${MISSING[*]}"
  echo "[setup-build-host] Updating apt cache and installing dependencies..."
  apt-get update -y
  apt-get install -y --no-install-recommends "${MISSING[@]}"
else
  echo "[setup-build-host] All required packages already installed."
fi

# -------------------------------------------------------------------
# Enable binfmt for qemu-arm-static (if not already registered)
# -------------------------------------------------------------------
if [ -x /usr/bin/qemu-arm-static ]; then
  echo "[setup-build-host] Verifying binfmt registration for qemu-arm-static..."
  if ! update-binfmts --display qemu-arm >/dev/null 2>&1; then
    echo "[setup-build-host] Registering qemu-arm-static with binfmt_misc..."
    update-binfmts --enable qemu-arm || true
  else
    echo "[setup-build-host] qemu-arm already registered with binfmt_misc."
  fi
else
  echo "[setup-build-host] WARNING: /usr/bin/qemu-arm-static not found (should be installed via qemu-user-static)."
fi

# -------------------------------------------------------------------
# Final checks and report
# -------------------------------------------------------------------
echo "[setup-build-host] Tool versions:"
printf "  %-20s %s\n" "qemu-user-static" "$(qemu-arm-static --version 2>/dev/null | head -n1 || echo 'not installed')"
printf "  %-20s %s\n" "rsync" "$(rsync --version 2>/dev/null | head -n1 || echo 'not installed')"
printf "  %-20s %s\n" "xz" "$(xz --version 2>/dev/null | head -n1 || echo 'not installed')"
printf "  %-20s %s\n" "gzip" "$(gzip --version 2>/dev/null | head -n1 || echo 'not installed')"
printf "  %-20s %s\n" "unzip" "$(unzip -v 2>/dev/null | head -n1 || echo 'not installed')"

echo
echo "[setup-build-host] Setup complete. This VM can now:"
echo "  - Mount and modify Raspberry Pi .img files"
echo "  - Decompress .xz/.gz/.zip images automatically"
echo "  - Chroot into ARM images for customization"
echo "  - Build OEM images using rpi-build"
echo
echo "[setup-build-host] Re-run anytime; missing tools will be installed as needed."
