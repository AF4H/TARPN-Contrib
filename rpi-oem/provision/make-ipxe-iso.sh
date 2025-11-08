#!/usr/bin/env bash
set -euo pipefail

# Where to put the finished ISO
OUT_DIR="${OUT_DIR:-artifacts}"
OUT_ISO="${OUT_ISO:-${OUT_DIR}/factory-bootstrap.iso}"

# Where to put/build iPXE source
IPXE_SRC_DIR="${IPXE_SRC_DIR:-ipxe-src}"

# Script to embed
EMBED_SCRIPT="${EMBED_SCRIPT:-provision/ipxe-bootstrap.ipxe}"

mkdir -p "$OUT_DIR"

echo "[make-ipxe-iso] Installing build deps (if needed)..."
apt-get update -y
apt-get install -y git build-essential binutils mtools syslinux isolinux

if [ ! -d "$IPXE_SRC_DIR/.git" ]; then
  echo "[make-ipxe-iso] Cloning iPXE..."
  git clone https://github.com/ipxe/ipxe.git "$IPXE_SRC_DIR"
fi

cd "$IPXE_SRC_DIR/src"

echo "[make-ipxe-iso] Building iPXE ISO with embedded script: $EMBED_SCRIPT"
make clean
make bin/ipxe.iso EMBED="../../${EMBED_SCRIPT}"

cp bin/ipxe.iso "../../${OUT_ISO}"

echo "[make-ipxe-iso] Done. ISO at: ${OUT_ISO}"
