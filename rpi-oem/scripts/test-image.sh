#!/usr/bin/env bash
#
# rpi-oem/scripts/test-image.sh
#
# Smoke-test a Raspberry Pi image using QEMU + guest-smoketest.sh.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${RPI_OEM_WORKDIR:-${REPO_ROOT}/artifacts}"

usage() {
  cat <<EOF
Usage: $0 IMAGE_PATH [SSH_PORT]

Run a QEMU-based smoketest on IMAGE_PATH.

Arguments:
  IMAGE_PATH   Path to the .img file to test.
  SSH_PORT     Host port for SSH into guest (default: 2222)

Environment:
  RPI_OEM_WORKDIR  Root under which test working dirs are created.
EOF
}

log() {
  echo "[test-image] $*" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

IMG_PATH="$1"
SSH_PORT="${2:-2222}"

if [[ ! -f "$IMG_PATH" ]]; then
  log "Image not found: ${IMG_PATH}"
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
WORKDIR="${WORK_ROOT}/test-${timestamp}"

BOOTDIR="${WORKDIR}/bootfiles"
LOGFILE="${WORKDIR}/qemu-console.log"

mkdir -p "$WORKDIR"

log "Test workdir: ${WORKDIR}"
log "Extracting boot files..."
"${REPO_ROOT}/scripts/extract-boot.sh" "$IMG_PATH" "$BOOTDIR"

log "Launching QEMU on ${IMG_PATH} (SSH port ${SSH_PORT})"
# run-qemu-rpi3b.sh should:
#   - boot the image
#   - map SSH_PORT to guest port 22
#   - print console to LOGFILE if you wish
"${REPO_ROOT}/scripts/run-qemu-rpi3b.sh" "$IMG_PATH" "$BOOTDIR" "$SSH_PORT" >"$LOGFILE" 2>&1 &
QEMU_PID=$!

cleanup() {
  set +e
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    log "Stopping QEMU (pid ${QEMU_PID})"
    kill "$QEMU_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$QEMU_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "Waiting for SSH to become available..."
for i in {1..60}; do
  if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "pi@localhost" true 2>/dev/null; then
    log "SSH is up."
    break
  fi
  sleep 2
done

if ! ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "pi@localhost" true 2>/dev/null; then
  log "SSH did not come up in time; see log: ${LOGFILE}"
  exit 1
fi

log "Running guest smoketest..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "pi@localhost" 'sudo /usr/local/sbin/guest-smoketest.sh'

log "Test complete. Logs at: ${LOGFILE}"
