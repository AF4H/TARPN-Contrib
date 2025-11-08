#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/srv/rpi-oem"

mkdir -p "$REPO_DIR"
curl -L https://github.com/AF4H/TARPN-Contrib/tarball/main | tar xz --strip-components=2 -C "$REPO_DIR" TARPN-Contrib-main/rpi-oem

echo "[factory-bootstrap] Updating apt..."
apt-get update -y

echo "[factory-bootstrap] Installing base tooling..."
DEPS=(
  git
  ca-certificates
  qemu-system-aarch64
  qemu-user-static
  qemu-utils
  kpartx
  rsync
  xz-utils
  curl
  sudo
  vim
  less
)
apt-get install -y "${DEPS[@]}"

# Optional: pi-gen / build deps as you flesh this out
# apt-get install -y debootstrap dosfstools parted zip ...

echo "[factory-bootstrap] Cloning OEM repo..."
mkdir -p "$(dirname "$REPO_DIR")"
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
else
  cd "$REPO_DIR"
  git fetch --all
  git reset --hard origin/main
fi

cd "$REPO_DIR"

echo "[factory-bootstrap] Running setup-build-host.sh if present..."
if [ -x "./rpi-oem/scripts/setup-build-host.sh" ]; then
  ./rpi-oem/scripts/setup-build-host.sh
fi

echo "[factory-bootstrap] Installing convenience commands..."
cat >/usr/local/bin/rpi-build <<"EOF"
#!/usr/bin/env bash
set -e
cd /srv/rpi-oem
./scripts/build-image.sh "$@"
EOF

cat >/usr/local/bin/rpi-test <<"EOF"
#!/usr/bin/env bash
set -e
cd /srv/rpi-oem
./scripts/test-image.sh "$@"
EOF

chmod +x /usr/local/bin/rpi-build /usr/local/bin/rpi-test

echo "[factory-bootstrap] Done. Reboot recommended."
