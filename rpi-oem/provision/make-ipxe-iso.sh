#!/usr/bin/env bash
set -euo pipefail

# This script is intended to live in: rpi-oem/provision/make-ipxe-iso.sh
# You can run it from *any* directory, including directly from provision/.

# --- Locate repo and key paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/artifacts}"
OUT_ISO="${OUT_ISO:-${OUT_DIR}/factory-bootstrap.iso}"
IPXE_SRC_DIR="${IPXE_SRC_DIR:-${REPO_ROOT}/ipxe-src}"

EMBED_FILE="${SCRIPT_DIR}/ipxe-bootstrap.ipxe"

echo "[make-ipxe-iso] Script directory : ${SCRIPT_DIR}"
echo "[make-ipxe-iso] Repo root        : ${REPO_ROOT}"
echo "[make-ipxe-iso] iPXE src dir     : ${IPXE_SRC_DIR}"
echo "[make-ipxe-iso] Embed file       : ${EMBED_FILE}"
echo "[make-ipxe-iso] Output ISO       : ${OUT_ISO}"

# --- Sanity checks ---
if [[ ! -f "${EMBED_FILE}" ]]; then
  echo "[make-ipxe-iso] ERROR: ${EMBED_FILE} not found."
  echo "  Expected ipxe-bootstrap.ipxe to be in the same directory as this script."
  exit 1
fi

mkdir -p "${OUT_DIR}"

echo "[make-ipxe-iso] Installing build deps (if needed)..."
apt-get update -y
apt-get install -y git build-essential binutils mtools syslinux isolinux liblzma-dev

# --- Clone iPXE if needed ---
if [[ ! -d "${IPXE_SRC_DIR}/.git" ]]; then
  echo "[make-ipxe-iso] Cloning iPXE into ${IPXE_SRC_DIR}..."
  git clone https://github.com/ipxe/ipxe.git "${IPXE_SRC_DIR}"
fi

# --- Build ISO from iPXE src/ ---
cd "${IPXE_SRC_DIR}/src"

echo "[make-ipxe-iso] Cleaning previous build..."
make clean || true

echo "[make-ipxe-iso] Building iPXE ISO with embedded script: ${EMBED_FILE}"
# Use absolute path for EMBED to avoid relative-path issues
make bin/ipxe.iso EMBED="${EMBED_FILE}"

cp bin/ipxe.iso "${OUT_ISO}"

echo "[make-ipxe-iso] Done. ISO at: ${OUT_ISO}"
