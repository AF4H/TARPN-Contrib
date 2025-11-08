#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <image.img> <output-boot-dir>" >&2
  exit 1
fi

IMG="$1"
OUTDIR="$2"

mkdir -p "$OUTDIR"

LOOPDEV="$(losetup --show -fP "$IMG")"
BOOT_PART="${LOOPDEV}p1"

MNT_BOOT="/mnt/rpi-oem-boot-extract"
mkdir -p "$MNT_BOOT"

cleanup() {
  umount "$MNT_BOOT" 2>/dev/null || true
  losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT

mount "$BOOT_PART" "$MNT_BOOT"

rsync -a "$MNT_BOOT"/ "$OUTDIR"/
sync

echo "[extract-boot] Boot files copied to $OUTDIR"
