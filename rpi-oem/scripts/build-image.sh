#!/usr/bin/env bash
# scripts/build-image.sh
set -euo pipefail

# --- Parse args ---
LABEL="DEFAULT"
ARGS=()

for arg in "$@"; do
  case "$arg" in
    --label=*)
      LABEL="${arg#--label=}"
      ;;
    --label)
      echo "Error: --label requires an argument (--label=BUSTER)" >&2
      exit 1
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

SRC="${ARGS[0]:-}"              # optional manual image or URL
SUFFIX="${ARGS[1]:-oem}"
DATE_STR="$(date +%Y%m%d-%H%M%S)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"
CACHE_DIR="${REPO_ROOT}/base-cache"
OVERLAY_DIR="${REPO_ROOT}/overlay-rootfs"
PKG_LIST="${REPO_ROOT}/package-list.txt"
BASE_CFG="${REPO_ROOT}/base-images.cfg"

mkdir -p "${ARTIFACTS_DIR}" "${CACHE_DIR}"

# --- Determine the base image path ---
BASE_IMG=""

if [[ -n "$SRC" && -f "$SRC" ]]; then
  # Local file path
  BASE_IMG="$(readlink -f "$SRC")"
  echo "[build-image] Using local base image: $BASE_IMG"

elif [[ -n "$SRC" && "$SRC" =~ ^https?:// ]]; then
  # Direct URL input
  FNAME="$(basename "$SRC")"
  CACHE_IMG="${CACHE_DIR}/${FNAME}"
  echo "[build-image] Downloading base image from URL: $SRC"
  if [[ ! -f "$CACHE_IMG" ]]; then
    curl -fL "$SRC" -o "$CACHE_IMG"
  else
    echo "[build-image] Using cached file: $CACHE_IMG"
  fi
  BASE_IMG="$CACHE_IMG"

else
  # No explicit path/URL: use LABEL or DEFAULT
  if [[ ! -f "$BASE_CFG" ]]; then
    echo "[build-image] base-images.cfg not found; cannot resolve labels." >&2
    exit 1
  fi

  LABEL_URL="$(grep -E "^[[:space:]]*${LABEL}=" "$BASE_CFG" | sed -e 's/^[[:space:]]*'"$LABEL"'=//' | head -n1 || true)"

  if [[ -z "$LABEL_URL" ]]; then
    echo "[build-image] Label '$LABEL' not found in base-images.cfg." >&2
    exit 1
  fi

  echo "[build-image] Resolving label '$LABEL' to URL: $LABEL_URL"
  FNAME="$(basename "$LABEL_URL")"
  CACHE_IMG="${CACHE_DIR}/${LABEL}-${FNAME}"

  if [[ ! -f "$CACHE_IMG" ]]; then
    echo "[build-image] Downloading base image for label $LABEL ..."
    curl -fL "$LABEL_URL" -o "$CACHE_IMG"
  else
    echo "[build-image] Using cached file for label $LABEL: $CACHE_IMG"
  fi
  BASE_IMG="$CACHE_IMG"
fi

if [[ ! -f "$BASE_IMG" ]]; then
  echo "[build-image] Base image '$BASE_IMG' not found after resolution." >&2
  exit 1
fi

OUT_IMG="${ARTIFACTS_DIR}/${DATE_STR}-${SUFFIX}.img"
echo "[build-image] Copying base image to ${OUT_IMG} ..."
cp --reflink=auto "$BASE_IMG" "$OUT_IMG" || cp "$BASE_IMG" "$OUT_IMG"

# --- Mount and modify ---
LOOPDEV="$(losetup --show -fP "$OUT_IMG")"
echo "[build-image] Using loop device ${LOOPDEV}"

BOOT_PART="${LOOPDEV}p1"
ROOT_PART="${LOOPDEV}p2"

MNT_BOOT="/mnt/rpi-oem-boot"
MNT_ROOT="/mnt/rpi-oem-root"
mkdir -p "$MNT_BOOT" "$MNT_ROOT"

cleanup() {
  echo "[build-image] Cleaning up mounts and loop device..."
  sync || true
  umount "$MNT_BOOT" 2>/dev/null || true
  umount "$MNT_ROOT" 2>/dev/null || true
  losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT

mount "$BOOT_PART" "$MNT_BOOT"
mount "$ROOT_PART" "$MNT_ROOT"

# --- Apply overlays ---
if [[ -d "$OVERLAY_DIR" ]]; then
  echo "[build-image] Applying overlay-rootfs ..."
  rsync -a "$OVERLAY_DIR"/ "$MNT_ROOT"/
else
  echo "[build-image] No overlay-rootfs found, skipping."
fi

# --- Copy package list ---
if [[ -f "$PKG_LIST" ]]; then
  echo "[build-image] Copying package-list.txt into image..."
  cp "$PKG_LIST" "$MNT_ROOT/package-list.txt"
fi

# --- Install packages inside chroot ---
if [[ -f "$MNT_ROOT/package-list.txt" ]]; then
  echo "[build-image] Installing packages inside chroot..."
  cp /usr/bin/qemu-arm-static "$MNT_ROOT/usr/bin/"
  echo "nameserver 1.1.1.1" > "$MNT_ROOT/etc/resolv.conf"

  chroot "$MNT_ROOT" /usr/bin/qemu-arm-static /bin/bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    xargs -a /package-list.txt apt-get install -y
    apt-get clean
  '

  rm -f "$MNT_ROOT/usr/bin/qemu-arm-static"
else
  echo "[build-image] No package-list.txt found, skipping apt installs."
fi

echo "[build-image] Syncing filesystem..."
sync

echo "[build-image] OEM image built: ${OUT_IMG}"
echo "$OUT_IMG"
