#!/usr/bin/env bash
set -euo pipefail

# Script location and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/artifacts}"
OUT_ISO="${OUT_ISO:-${OUT_DIR}/factory-bootstrap.iso}"
IPXE_SRC_DIR="${IPXE_SRC_DIR:-${REPO_ROOT}/ipxe-src}"

EMBED_FILE="${SCRIPT_DIR}/ipxe-bootstrap.ipxe"
EXTRA_CONFIG="${SCRIPT_DIR}/ipxe-config.local"   # our local HTTPS config

echo "[make-ipxe-iso] Script directory : ${SCRIPT_DIR}"
echo "[make-ipxe-iso] Repo root        : ${REPO_ROOT}"
echo "[make-ipxe-iso] iPXE src dir     : ${IPXE_SRC_DIR}"
echo "[make-ipxe-iso] Embed file       : ${EMBED_FILE}"
echo "[make-ipxe-iso] Extra config     : ${EXTRA_CONFIG}"
echo "[make-ipxe-iso] Output ISO       : ${OUT_ISO}"

# --- Sanity checks ---
if [[ ! -f "${EMBED_FILE}" ]]; then
  echo "[make-ipxe-iso] ERROR: ${EMBED_FILE} not found."
  exit 1
fi

if [[ ! -f "${EXTRA_CONFIG}" ]]; then
  echo "[make-ipxe-iso] ERROR: ${EXTRA_CONFIG} not found."
  echo "  Expected ipxe-config.local to be in the same directory as this script."
  exit 1
fi

mkdir -p "${OUT_DIR}"

# --- Dependency setup (only if needed) ---
DEPS=(
  git
  build-essential
  binutils
  mtools
  syslinux
  isolinux
  liblzma-dev
  libmbedtls-dev
  pkg-config
  ca-certificates
)

MISSING=()
for pkg in "${DEPS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING+=("$pkg")
  fi
done

if (( ${#MISSING[@]} > 0 )); then
  echo "[make-ipxe-iso] Missing packages: ${MISSING[*]}"
  echo "[make-ipxe-iso] Installing build dependencies..."
  apt-get update -y
  apt-get install -y "${MISSING[@]}"
else
  echo "[make-ipxe-iso] All build dependencies already installed; skipping apt-get."
fi

# --- Clone iPXE if needed ---
if [[ ! -d "${IPXE_SRC_DIR}/.git" ]]; then
  echo "[make-ipxe-iso] Cloning iPXE into ${IPXE_SRC_DIR}..."
  git clone https://github.com/ipxe/ipxe.git "${IPXE_SRC_DIR}"
fi

cd "${IPXE_SRC_DIR}/src"

# --- Install our local config in the place iPXE expects it ---
LOCAL_CFG_DIR="${IPXE_SRC_DIR}/src/config/local"
mkdir -p "${LOCAL_CFG_DIR}"

echo "[make-ipxe-iso] Writing config/local/general.h from ipxe-config.local..."
{
  echo "#ifndef CONFIG_LOCAL_GENERAL_H"
  echo "#define CONFIG_LOCAL_GENERAL_H"
  cat "${EXTRA_CONFIG}"
  echo "#endif /* CONFIG_LOCAL_GENERAL_H */"
} > "${LOCAL_CFG_DIR}/general.h"

echo "[make-ipxe-iso] Cleaning previous build..."
make clean || true

echo "[make-ipxe-iso] Building iPXE ISO with HTTPS support..."
# USE_MBEDTLS=1: enable TLS via mbedTLS
# EMBED: use absolute path to our ipxe-bootstrap.ipxe
make bin/ipxe.iso \
  EMBED="${EMBED_FILE}" \
  USE_MBEDTLS=1

cp bin/ipxe.iso "${OUT_ISO}"

echo "[make-ipxe-iso] Done. ISO at: ${OUT_ISO}"
