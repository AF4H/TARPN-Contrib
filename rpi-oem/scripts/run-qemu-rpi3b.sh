#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <image.img> <bootfiles-dir> [ssh-port]" >&2
  exit 1
fi

IMG="$1"
BOOTDIR="$2"
SSH_PORT="${3:-2222}"

KERNEL="${BOOTDIR}/kernel7l.img"
DTB="${BOOTDIR}/bcm2710-rpi-3-b.dtb"

if [[ ! -f "$KERNEL" ]]; then
  echo "[run-qemu-rpi3b] kernel7l.img not found in $BOOTDIR" >&2
  exit 1
fi

if [[ ! -f "$DTB" ]]; then
  echo "[run-qemu-rpi3b] bcm2710-rpi-3-b.dtb not found in $BOOTDIR" >&2
  exit 1
fi

echo "[run-qemu-rpi3b] Starting QEMU on port ${SSH_PORT}..."

exec qemu-system-aarch64 \
  -M raspi3b \
  -cpu cortex-a53 \
  -m 1024 \
  -drive file="$IMG",if=sd,format=raw \
  -kernel "$KERNEL" \
  -dtb "$DTB" \
  -append "console=ttyAMA0,115200 root=/dev/mmcblk0p2 rw rootwait fsck.repair=yes" \
  -display none \
  -serial mon:stdio \
  -device usb-net,netdev=usn0 \
  -netdev user,id=usn0,hostfwd=tcp::${SSH_PORT}-:22
