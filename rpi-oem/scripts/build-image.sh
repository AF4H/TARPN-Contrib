#!/usr/bin/env bash
#
# rpi-oem/scripts/build-image.sh
#
# Build a customized Raspberry Pi image from a base image label and optional overlay.
#
# Key env vars:
#   RPI_OEM_WORKDIR  - if set, all artifacts/cache go under this directory.
#
# Key options:
#   --label=NAME         : base image label from base-images.cfg (DEFAULT if omitted)
#   --overlay=SPEC       : overlay name / URL / path (consult overlay-map.cfg when needed)
#   --overlay-map=PATH   : override path/URL to overlay-map.cfg
#   --overlay-image=PATH : direct archive (local file or URL), bypass overlay-map.cfg
#

set -euo pipefail

########################################
# Paths and defaults
########################################

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${RPI_OEM_WORKDIR:-${REPO_ROOT}}"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-${WORK_ROOT}/artifacts}"
CACHE_DIR="${CACHE_DIR:-${WORK_ROOT}/base-cache}"
DEFAULT_OVERLAY_MAP="${REPO_ROOT}/overlays/overlay-map.cfg"
BASE_IMAGES_CFG="${REPO_ROOT}/base-images.cfg"

mkdir -p "${ARTIFACTS_DIR}" "${CACHE_DIR}"

########################################
# Helpers
########################################

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --label=NAME          Base image label from base-images.cfg (default: DEFAULT)
  --overlay=SPEC        Overlay to apply. SPEC can be:
                          - URL (http:// or https://)
                          - local path to file or directory
                          - logical name found in overlay-map.cfg (e.g. TADD/Buster)
  --overlay-map=PATH    Override overlay-map.cfg location (local path or URL)
  --overlay-image=SPEC  Direct overlay archive (local or URL); bypasses overlay-map
  --help                Show this help

Environment:
  RPI_OEM_WORKDIR       Root for artifacts/cache. Defaults to repo root.

EOF
}

log() {
  echo "[build-image] $*" >&2
}

error() {
  echo "[build-image] ERROR: $*" >&2
  exit 1
}

download_to_cache() {
  local url="$1"
  local basename dest

  basename="$(basename "${url%%\?*}")"
  mkdir -p "${CACHE_DIR}/downloads"
  dest="${CACHE_DIR}/downloads/${basename}"

  if [[ ! -f "$dest" ]]; then
    log "Downloading ${url} -> ${dest}"
    curl -L --fail -o "$dest" "$url"
  else
    log "Using cached download: ${dest}"
  fi

  echo "$dest"
}

extract_archive_to_dir() {
  local archive="$1"
  local dest_dir="$2"

  mkdir -p "$dest_dir"

  case "$archive" in
    *.zip)
      unzip -o "$archive" -d "$dest_dir"
      ;;
    *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2)
      tar -xf "$archive" -C "$dest_dir"
      ;;
    *)
      error "Unsupported archive type for overlay: ${archive}"
      ;;
  esac
}

resolve_overlay_map_file() {
  local spec="$1"

  if [[ -z "$spec" ]]; then
    echo "$DEFAULT_OVERLAY_MAP"
    return 0
  fi

  case "$spec" in
    http://*|https://*)
      mkdir -p "${CACHE_DIR}/overlay-maps"
      local path
      path="$(download_to_cache "$spec")"
      echo "$path"
      return 0
      ;;
  esac

  if [[ -f "$spec" ]]; then
    echo "$spec"
    return 0
  fi

  error "overlay map not found: ${spec}"
}

lookup_overlay_in_map() {
  local key="$1"
  local map_file="$2"

  if [[ ! -f "$map_file" ]]; then
    error "overlay-map.cfg not found at ${map_file}"
  fi

  local line k v
  while IFS= read -r line; do
    # strip comments
    line="${line%%#*}"
    # trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    k="${line%%=*}"
    v="${line#*=}"

    # trim
    k="${k#"${k%%[![:space:]]*}"}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"

    if [[ "$k" == "$key" ]]; then
      echo "$v"
      return 0
    fi
  done < "$map_file"

  error "overlay key '${key}' not found in ${map_file}"
}

resolve_base_image_url() {
  local label="$1"
  local cfg="$2"

  if [[ ! -f "$cfg" ]]; then
    error "base-images.cfg not found at ${cfg}"
  fi

  local cur="$label"
  local depth=0
  local max_depth=10
  local line k v

  while :; do
    (( depth++ ))
    if (( depth > max_depth )); then
      error "base image resolution loop exceeded max depth for label ${label}"
    fi

    local found=0
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue

      k="${line%%=*}"
      v="${line#*=}"

      k="${k#"${k%%[![:space:]]*}"}"
      k="${k%"${k##*[![:space:]]}"}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"

      if [[ "$k" == "$cur" ]]; then
        found=1
        if [[ "$v" == http://* || "$v" == https://* ]]; then
          echo "$v"
          return 0
        else
          cur="$v"
          break
        fi
      fi
    done < "$cfg"

    if (( ! found )); then
      error "base image label '${cur}' not found in ${cfg}"
    fi
  done
}

decompress_base_image() {
  local src="$1"
  local dest_img="$2"

  case "$src" in
    *.img)
      cp "$src" "$dest_img"
      ;;
    *.img.xz|*.xz)
      xz -dkc "$src" > "$dest_img"
      ;;
    *.img.gz|*.gz)
      gunzip -c "$src" > "$dest_img"
      ;;
    *.zip)
      # assume only one .img inside
      local tmpdir
      tmpdir="$(mktemp -d "${CACHE_DIR}/unzip-XXXXXX")"
      unzip -o "$src" -d "$tmpdir"
      local img
      img="$(find "$tmpdir" -maxdepth 1 -type f -name '*.img' | head -n1 || true)"
      [[ -z "$img" ]] && error "no .img found inside ${src}"
      cp "$img" "$dest_img"
      ;;
    *)
      error "Unsupported base image archive type: ${src}"
      ;;
  esac
}

########################################
# Argument parsing
########################################

LABEL="DEFAULT"
OVERLAY_SPEC=""
OVERLAY_MAP_SPEC=""
OVERLAY_IMAGE_SPEC=""

for arg in "$@"; do
  case "$arg" in
    --label=*)
      LABEL="${arg#*=}"
      ;;
    --overlay=*)
      OVERLAY_SPEC="${arg#*=}"
      ;;
    --overlay-map=*)
      OVERLAY_MAP_SPEC="${arg#*=}"
      ;;
    --overlay-image=*)
      OVERLAY_IMAGE_SPEC="${arg#*=}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: ${arg}"
      ;;
  esac
done

########################################
# Resolve base image
########################################

log "Using base label: ${LABEL}"
BASE_URL="$(resolve_base_image_url "$LABEL" "$BASE_IMAGES_CFG")"
log "Resolved base URL: ${BASE_URL}"

BASE_ARCHIVE="$(download_to_cache "$BASE_URL")"

timestamp="$(date +%Y%m%d-%H%M%S)"
base_name="$(basename "${BASE_ARCHIVE%.*}")"
OUT_IMG="${ARTIFACTS_DIR}/${base_name}-oem-${timestamp}.img"

log "Decompressing base image ${BASE_ARCHIVE} -> ${OUT_IMG}"
decompress_base_image "$BASE_ARCHIVE" "$OUT_IMG"

########################################
# Resolve overlay (if any)
########################################

# 1) Decide which map file to use (even if it might not be needed)
OVERLAY_MAP_FILE="$(resolve_overlay_map_file "$OVERLAY_MAP_SPEC")" || true

OVERLAY_SOURCE=""  # URL or local path
OVERLAY_DIR=""     # extracted directory

# --overlay-image wins if specified
if [[ -n "$OVERLAY_IMAGE_SPEC" ]]; then
  OVERLAY_SOURCE="$OVERLAY_IMAGE_SPEC"

elif [[ -n "$OVERLAY_SPEC" ]]; then
  case "$OVERLAY_SPEC" in
    http://*|https://*)
      # direct URL
      OVERLAY_SOURCE="$OVERLAY_SPEC"
      ;;
    /*|./*|../*)
      # path-like
      OVERLAY_SOURCE="$OVERLAY_SPEC"
      ;;
    *)
      # logical name -> consult map
      if [[ -z "$OVERLAY_MAP_FILE" ]]; then
        error "overlay specified (${OVERLAY_SPEC}) but overlay-map.cfg not available"
      fi
      OVERLAY_SOURCE="$(lookup_overlay_in_map "$OVERLAY_SPEC" "$OVERLAY_MAP_FILE")"
      ;;
  esac
fi

# Turn OVERLAY_SOURCE into an overlay directory
if [[ -n "$OVERLAY_SOURCE" ]]; then
  case "$OVERLAY_SOURCE" in
    http://*|https://*)
      local_archive="$(download_to_cache "$OVERLAY_SOURCE")"
      tmp_dir="$(mktemp -d "${CACHE_DIR}/overlay-XXXXXX")"
      log "Extracting overlay archive ${local_archive} -> ${tmp_dir}"
      extract_archive_to_dir "$local_archive" "$tmp_dir"
      OVERLAY_DIR="$tmp_dir"
      ;;
    *)
      if [[ -d "$OVERLAY_SOURCE" ]]; then
        OVERLAY_DIR="$OVERLAY_SOURCE"
      elif [[ -f "$OVERLAY_SOURCE" ]]; then
        tmp_dir="$(mktemp -d "${CACHE_DIR}/overlay-XXXXXX")"
        log "Extracting overlay archive ${OVERLAY_SOURCE} -> ${tmp_dir}"
        extract_archive_to_dir "$OVERLAY_SOURCE" "$tmp_dir"
        OVERLAY_DIR="$tmp_dir"
      else
        error "overlay source not found: ${OVERLAY_SOURCE}"
      fi
      ;;
  esac
fi

########################################
# Mount image, apply overlays
########################################

MNT_ROOT=""
MNT_BOOT=""
LOOPDEV=""

cleanup() {
  set +e
  if mountpoint -q "$MNT_BOOT"; then umount "$MNT_BOOT"; fi
  if mountpoint -q "$MNT_ROOT"; then umount "$MNT_ROOT"; fi
  if [[ -n "$LOOPDEV" ]]; then losetup -d "$LOOPDEV" || true; fi
  [[ -n "$MNT_BOOT" ]] && rmdir "$MNT_BOOT" || true
  [[ -n "$MNT_ROOT" ]] && rmdir "$MNT_ROOT" || true
}
trap cleanup EXIT

MNT_BOOT="$(mktemp -d /tmp/rpi-oem-boot-XXXXXX)"
MNT_ROOT="$(mktemp -d /tmp/rpi-oem-root-XXXXXX)"

log "Setting up loop device for ${OUT_IMG}"
LOOPDEV="$(losetup --show -Pf "$OUT_IMG")"
log "Loop device: ${LOOPDEV}"

BOOT_PART="${LOOPDEV}p1"
ROOT_PART="${LOOPDEV}p2"

log "Mounting boot partition ${BOOT_PART} -> ${MNT_BOOT}"
mount "$BOOT_PART" "$MNT_BOOT"

log "Mounting root partition ${ROOT_PART} -> ${MNT_ROOT}"
mount "$ROOT_PART" "$MNT_ROOT"

# Apply overlay from OVERLAY_DIR (if any)
if [[ -n "$OVERLAY_DIR" && -d "$OVERLAY_DIR" ]]; then
  log "Applying overlay from ${OVERLAY_DIR} ..."
  rsync -a "${OVERLAY_DIR}/" "${MNT_ROOT}/"
else
  log "No overlay specified or resolved; skipping overlay"
fi

# Apply local overlay-rootfs last, if present
LOCAL_OVERLAY_DIR="${REPO_ROOT}/overlay-rootfs"
if [[ -d "$LOCAL_OVERLAY_DIR" ]]; then
  log "Applying local overlay-rootfs from ${LOCAL_OVERLAY_DIR} ..."
  rsync -a "${LOCAL_OVERLAY_DIR}/" "${MNT_ROOT}/"
else
  log "No local overlay-rootfs directory found; skipping"
fi

log "Syncing filesystems..."
sync

log "Build complete: ${OUT_IMG}"
echo "${OUT_IMG}"
