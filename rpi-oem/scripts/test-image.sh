#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <image.img> [ssh-port]" >&2
  exit 1
fi

IMG="$1"
SSH_PORT="${2:-2222}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${RPI_OEM_WORKDIR:-${REPO_ROOT}/artifacts}"
WORKDIR="${WORK_ROOT}/test-$(date +%Y%m%d-%H%M%S)"
BOOTDIR="${WORKDIR}/bootfiles"
LOGFILE="${WORKDIR}/qemu-console.log" 

mkdir -p "$WORKDIR" "$BOOTDIR"

echo "[test-image] Extracting boot files..."
"${REPO_ROOT}/scripts/extract-boot.sh" "$IMG" "$BOOTDIR"

echo "[test-image] Launching QEMU..."
"${REPO_ROOT}/scripts/run-qemu-rpi3b.sh" "$IMG" "$BOOTDIR" "$SSH_PORT" \
  >"$LOGFILE" 2>&1 &
QEMU_PID=$!

cleanup() {
  echo "[test-image] Cleaning up QEMU..."
  kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "[test-image] Waiting for SSH (port ${SSH_PORT})..."
for i in $(seq 1 120); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=1 -p "$SSH_PORT" pi@localhost 'echo up' 2>/dev/null; then
    echo "[test-image] SSH is up."
    break
  fi
  sleep 1
  if [[ $i -eq 120 ]]; then
    echo "[test-image] Timeout waiting for SSH." >&2
    exit 1
  fi
done

echo "[test-image] Copying smoketest script..."
scp -P "$SSH_PORT" -o StrictHostKeyChecking=no \
  "${REPO_ROOT}/scripts/guest-smoketest.sh" pi@localhost:/home/pi/ >/dev/null

echo "[test-image] Running smoketest..."
ssh -P "$SSH_PORT" -o StrictHostKeyChecking=no \
  pi@localhost 'sudo bash /home/pi/guest-smoketest.sh' | tee "${WORKDIR}/smoketest.log"

echo "[test-image] Done. Logs in ${WORKDIR}"
