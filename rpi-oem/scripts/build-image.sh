#!/usr/bin/env bash
# scripts/build-image.sh
set -euo pipefail

# --------------------------------------------------------------------
# Usage:
#   build-image.sh [--label=LABEL] [SRC] [name-suffix]
#
# SRC can be:
#   - empty                -> use LABEL (default: DEFAULT) in base-images.cfg
#   - a local file path    -> .img / .img.xz / .img.gz / .zip
#   - a URL                -> http(s)://... (possibly compressed)
#
# LABEL is looked up in base-images.cfg as: LABEL=URL
# --------------------------------------------------------------------

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

SRC="${ARGS[0]:-}"              # optional: path or URL
SUFFIX="${ARGS[1]:-oem}"
DATE_STR="$(date +%Y%m%d-%H%M%S)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
CACHE_DIR="${CACHE_DIR:-${REPO_ROOT}/base-cache}"
OVERLAY_DIR="${REPO_ROOT}/overlay-rootfs"
PKG_LIST="${REPO_ROOT}/package-list.txt"
BASE_CFG="${REPO_ROOT}/base-images.cfg"

mkdir -p "${ARTIFACTS_DIR}" "${CACHE_DIR}"

# --------------------------------------------------------------------
# Helper: auto-decompress compressed images
#   Supports:
#     - *.img       -> used as is
#     - *.img.xz,
#       *.xz        -> decompressed with xz -dk
#     - *.img.gz,
#       *.gz        -> decompressed with gunzip -k
#     - *.zip       -> unzip; finds .img or compressed .img inside
# --------------------------------------------------------------------
decompress_if_needed() {
  local path="$1"
  local dir base out outdir cand

  case "$path" in
    *.img)
      echo "$path"
      ;;

    *.img.xz|*.xz)
      if ! command -v xz >/dev/null 2>&1; then
        echo "[build-image] ERROR: 'xz' not found. Please install xz-utils." >&2
        exit 1
      fi
      dir="$(dirname "$path")"
      base="$(basename "$path" .xz)"
      out="${dir}/${base}"
      if [[ ! -f "$out" ]]; then
        echo "[build-image] Decompressing $path -> $out ..."
        xz -dk "$path"
        # some xz versions may write into cwd; ensure final path is as expected
        if [[ ! -f "$out" && -f "${base}" ]]; then
          mv "${base}" "$out"
        fi
      else
        echo "[build-image] Using existing decompressed image: $out"
      fi
      echo "$out"
      ;;

    *.img.gz|*.gz)
      if ! command -v gunzip >/dev/null 2>&1; then
        echo "[build-image] ERROR: 'gunzip' not found. Please install gzip." >&2
        exit 1
      fi
      dir="$(dirname "$path")"
      base="$(basename "$path" .gz)"
      out="${dir}/${base}"
      if [[ ! -f "$out" ]]; then
        echo "[build-image] Decompressing $path -> $out ..."
        gunzip -k "$path"
      else
        echo "[build-image] Using existing decompressed image: $out"
      fi
      echo "$out"
      ;;

    *.zip)
      if ! command -v unzip >/dev/null 2>&1; then
        echo "[build-image] ERROR: 'unzip' not found. Please 'apt-get install unzip'." >&2
        exit 1
      fi
      dir="$(dirname "$path")"
      base="$(basename "$path" .zip)"
      outdir="${dir}/${base}-unzipped"
      mkdir -p "$outdir"
      echo "[build-image] Extracting ZIP $path -> $outdir ..."
      unzip -j -o "$path" '*.img*' -d "$outdir" >/dev/null

      cand="$(ls "$outdir"/*.img 2>/dev/null | head -n1 || true)"
      if [[ -n "$cand" ]]; then
        echo "$cand"
        return
      fi

      cand="$(ls "$outdir"/*.img.xz "$outdir"/*.img.gz 2>/dev/null | head -n1 || true)"
      if [[ -n "$cand" ]]; then
        decompress_if_needed "$cand"
        return
      fi

      echo "[build-image] ERROR: No .img or compressed .img files found in ZIP: $path" >&2
      exit 1
      ;;

    *)
      echo "[build-image] WARNING: Unknown extension for $path; assuming raw .img" >&2
      echo "$path"
      ;;
  esac
}

# --------------------------------------------------------------------
# Resolve base image (possibly compressed) from SRC / LABEL / URL
# --------------------------------------------------------------------

BASE_SRC=""   # may be compressed or already .img

if [[ -n "$SRC" && -f "$SRC" ]]; then
  # Local file path (could be compressed)
  BASE_SRC="$(readlink -f "$SRC")"
  echo "[build-image] Using local base image file: $BASE_SRC"

elif [[ -n "$SRC" && "$SRC" =~ ^https?:// ]]; then
  # Direct URL
  FNAME="$(basename "$SRC")"
  CACHE_FILE="${CACHE_DIR}/${FNAME}"
  echo "[build-image] Downloading base image from URL: $SRC"
  if [[ ! -f "$CACHE_FILE" ]]; then
    curl -fL "$SRC" -o "$CACHE_FILE"
  else
    echo "[build-image] Using cached file: $CACHE_FILE"
  fi
  BASE_SRC="$CACHE_FILE"

else
  # No explicit SRC: use LABEL (default DEFAULT) from base-images.cfg
  if [[ ! -f "$BASE_CFG" ]]; then
    echo "[build-image] base-images.cfg not found; cannot resolve label '$LABEL'." >&2
    exit 1
  fi

  LABEL_URL="$(grep -E "^[[:space:]]*${LABEL}=" "$BASE_CFG" | sed -e 's/^[[:space:]]*'"$LABEL"'=//' | head -n1 || true)"
  if [[ -z "$LABEL_URL" ]]; then
    echo "[build-image] Label '$LABEL' not found in base-images.cfg." >&2
    exit 1
  fi

  echo "[build-image] Resolving label '$LABEL' to URL: $LABEL_URL"
  FNAME="$(basename "$LABEL_URL")"
  CACHE_FILE="${CACHE_DIR}/${LABEL}-${FNAME}"

  if [[ ! -f "$CACHE_FILE" ]]; then
    echo "[build-image] Downloading base image for label $LABEL ..."
    curl -fL "$LABEL_URL" -o "$CACHE_FILE"
  else
    echo "[build-image] Using cached file for label $LABEL: $CACHE_FILE"
  fi
  BASE_SRC="$CACHE_FILE"
fi

if [[ ! -f "$BASE_SRC" ]]; then
  echo "[build-image] Base source '$BASE_SRC' not found after resolution." >&2
  exit 1
fi

# Auto-decompress if needed, to get a usable .img
BASE_IMG="$(decompress_if_needed "$BASE_SRC")"

if [[ ! -f "$BASE_IMG" ]]; then
  echo "[build-image] ERROR: Decompressed base image '$BASE_IMG' not found." >&2
  exit 1
fi

OUT_IMG="${ARTIFACTS_DIR}/${DATE_STR}-${SUFFIX}.img"
echo "[build-image] Copying base image to ${OUT_IMG} ..."
cp --reflink=auto "$BASE_IMG" "$OUT_IMG" 2>/dev/null || cp "$BASE_IMG" "$OUT_IMG"

# --------------------------------------------------------------------
# Loop-mount and customize image
# --------------------------------------------------------------------

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

echo "[build-image] Mounting partitions..."
mount "$BOOT_PART" "$MNT_BOOT"
mount "$ROOT_PART" "$MNT_ROOT"

# Apply overlay-rootfs if present
if [[ -d "$OVERLAY_DIR" ]]; then
  echo "[build-image] Applying overlay-rootfs from $OVERLAY_DIR ..."
  rsync -a "$OVERLAY_DIR"/ "$MNT_ROOT"/
else
  echo "[build-image] No overlay-rootfs directory found, skipping file overlay."
fi

# Copy package list into image if present
if [[ -f "$PKG_LIST" ]]; then
  echo "[build-image] Copying package-list.txt into image..."
  cp "$PKG_LIST" "$MNT_ROOT/package-list.txt"
fi

# Install packages in chroot using qemu-arm-static
if [[ -f "$MNT_ROOT/package-list.txt" ]]; then
  echo "[build-image] Installing packages inside chroot..."
  if [[ ! -x /usr/bin/qemu-arm-static ]]; then
    echo "[build-image] /usr/bin/qemu-arm-static not found (did setup-build-host.sh run?)" >&2
    exit 1
  fi

  cp /usr/bin/qemu-arm-static "$MNT_ROOT/usr/bin/"

  # Ensure resolv.conf so the chroot can reach APT
  if [[ ! -e "$MNT_ROOT/etc/resolv.conf" ]]; then
    echo "nameserver 1.1.1.1" > "$MNT_ROOT/etc/resolv.conf"
  fi

  chroot "$MNT_ROOT" /usr/bin/qemu-arm-static /bin/bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    xargs -a /package-list.txt apt-get install -y
    apt-get clean
  '

  rm -f "$MNT_ROOT/usr/bin/qemu-arm-static"
else
  echo "[build-image] No package-list.txt found in image, skipping apt installs."
fi

echo "[build-image] Syncing filesystem..."
sync

echo "[build-image] OEM image built: ${OUT_IMG}"
echo "$OUT_IMG"
