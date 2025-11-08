#!/usr/bin/env bash
# scripts/build-image.sh
# Build a customized Raspberry Pi OEM image from a base image (local, URL, or label).
#
# Usage:
#   build-image.sh [--label=LABEL] [SRC] [name-suffix]
#
# SRC can be:
#   - empty                -> use LABEL (default: DEFAULT) from base-images.cfg
#   - a local file         -> .img / .img.xz / .img.gz / .zip
#   - a URL                -> http(s)://... (possibly compressed)
#
# LABEL is looked up in base-images.cfg as:
#   LABEL=URL            (e.g. STABLE=https://...)
#   LABEL=OTHERLABEL     (e.g. DEFAULT=STABLE alias)

set -euo pipefail

# --------------------------------------------------------------------
# Argument parsing
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
# Sanity checks: required tools
# --------------------------------------------------------------------
REQUIRED_TOOLS=(xz gunzip unzip losetup mount curl rsync)
for t in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "[build-image] ERROR: Required tool '$t' not found in PATH." >&2
    echo "[build-image]        Make sure setup-build-host.sh has been run on this VM." >&2
    exit 1
  fi
done

# --------------------------------------------------------------------
# Helper: download a URL into CACHE_DIR, preserving final filename
#   - Follows redirects (-L)
#   - Uses remote filename from final URL (-O)
#   - Returns full path to the downloaded file
# --------------------------------------------------------------------
download_to_cache() {
  local url="$1"
  local label="$2"  # currently unused, but handy for logging / future

  mkdir -p "$CACHE_DIR"
  echo "[build-image] Downloading $url ..."
  (
    cd "$CACHE_DIR"
    # -L: follow redirects; -O: save as remote filename (from final URL)
    curl -fLO "$url"
  )

  # Pick the most recently modified file in CACHE_DIR as the one we just downloaded.
  # This is safe in practice since builds are sequential on this VM.
  local dest
  dest="$(ls -t "$CACHE_DIR" | head -n1)"
  dest="${CACHE_DIR}/${dest}"

  if [[ ! -f "$dest" ]]; then
    echo "[build-image] ERROR: Download failed for $url" >&2
    exit 1
  fi

  echo "[build-image] Saved as: $dest"
  echo "$dest"
}

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
      dir="$(dirname "$path")"
      base="$(basename "$path" .xz)"
      out="${dir}/${base}"
      if [[ ! -f "$out" ]]; then
        echo "[build-image] Decompressing $path -> $out ..."
        xz -dk "$path"
        # Some xz versions may write into cwd; fix path if needed
        if [[ ! -f "$out" && -f "${base}" ]]; then
          mv "${base}" "$out"
        fi
      else
        echo "[build-image] Using existing decompressed image: $out"
      fi
      echo "$out"
      ;;

    *.img.gz|*.gz)
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
# Helper: resolve label from base-images.cfg, supporting aliases
#   Example:
#     DEFAULT=STABLE
#     STABLE=https://downloads.raspberrypi.org/raspios_lite_armhf_latest
# --------------------------------------------------------------------
resolve_label() {
  local label="$1"
  local depth=0
  local value

  while (( depth < 8 )); do
    value="$(grep -E "^[[:space:]]*${label}=" "$BASE_CFG" | sed -e 's/^[[:space:]]*'"$label"'=//' | head -n1 || true)"

    if [[ -z "$value" ]]; then
      echo "[build-image] ERROR: Label '$label' not found in base-images.cfg." >&2
      return 1
    fi

    # If it looks like a URL, we're done
    if [[ "$value" =~ ^https?:// ]]; then
      echo "$value"
      return 0
    fi

    # Otherwise assume it's an alias to another label (e.g. DEFAULT=STABLE)
    echo "[build-image] Label '$label' is an alias to '$value'..."
    label="$value"
    (( depth++ ))
  done

  echo "[build-image] ERROR: Too many alias indirections while resolving labels (possible loop)." >&2
  return 1
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
  echo "[build-image] Downloading base image from URL: $SRC"
  BASE_SRC="$(download_to_cache "$SRC" "manual")"

else
  # No explicit SRC: use LABEL (default DEFAULT) from base-images.cfg
  if [[ ! -f "$BASE_CFG" ]]; then
    echo "[build-image] base-images.cfg not found; cannot resolve label '$LABEL'." >&2
    exit 1
  fi

  LABEL_TARGET="$(resolve_label "$LABEL")" || exit 1
  echo "[build-image] Resolving label '$LABEL' to URL: $LABEL_TARGET"

  echo "[build-image] Downloading base image for label $LABEL ..."
  BASE_SRC="$(download_to_cache "$LABEL_TARGET" "$LABEL")"
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
