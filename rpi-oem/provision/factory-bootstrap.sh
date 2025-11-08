#!/bin/sh
# provision/factory-bootstrap.sh
# Run inside the newly installed Debian system (via preseed late_command).
# Turns a plain Debian 13 amd64 install into a TARPN Raspberry Pi OEM factory VM.

set -eu

echo "[factory-bootstrap] Starting bootstrap on $(hostname) ..."
export DEBIAN_FRONTEND=noninteractive

BASE_DIR="/srv"
REPO_URL="https://github.com/AF4H/TARPN-Contrib.git"
REPO_DIR="${BASE_DIR}/TARPN-Contrib"
PROJECT_DIR="${REPO_DIR}/rpi-oem"

echo "[factory-bootstrap] Base dir      : ${BASE_DIR}"
echo "[factory-bootstrap] Repo dir      : ${REPO_DIR}"
echo "[factory-bootstrap] Project dir   : ${PROJECT_DIR}"
echo "[factory-bootstrap] Repo URL      : ${REPO_URL}"

###############################################################################
# 1. Core tooling for bootstrap
###############################################################################

echo "[factory-bootstrap] Installing core packages (git, curl, sudo, avahi, etc.)..."
apt-get update -y || true
apt-get install -y \
  git \
  ca-certificates \
  curl \
  sudo \
  avahi-daemon \
  libnss-mdns \
  systemd \
  iproute2

# Make sure CA bundle is up to date for GitHub HTTPS
update-ca-certificates || true

###############################################################################
# 2. Clone or update the TARPN-Contrib repo
###############################################################################

mkdir -p "${BASE_DIR}"

if [ ! -d "${REPO_DIR}/.git" ]; then
  echo "[factory-bootstrap] Cloning repo into ${REPO_DIR}..."
  git clone "${REPO_URL}" "${REPO_DIR}"
else
  echo "[factory-bootstrap] Repo already present; updating..."
  cd "${REPO_DIR}"
  git fetch --all || true
  git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null || true
fi

if [ ! -d "${PROJECT_DIR}" ]; then
  echo "[factory-bootstrap] ERROR: Project subdir ${PROJECT_DIR} not found in repo."
  exit 1
fi

cd "${PROJECT_DIR}"
echo "[factory-bootstrap] Now in project dir: $(pwd)"

###############################################################################
# 3. Run setup-build-host.sh (installs QEMU, kpartx, etc.)
###############################################################################

if [ -x "./scripts/setup-build-host.sh" ]; then
  echo "[factory-bootstrap] Running scripts/setup-build-host.sh ..."
  ./scripts/setup-build-host.sh
else
  echo "[factory-bootstrap] WARNING: scripts/setup-build-host.sh not found or not executable."
fi

###############################################################################
# 4. VM guest tools (VirtualBox, QEMU/KVM, VMware, Hyper-V)
###############################################################################

echo "[factory-bootstrap] Detecting virtualization for guest tools..."
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
else
  VIRT="unknown"
fi
echo "[factory-bootstrap] systemd-detect-virt: ${VIRT}"

case "$VIRT" in
  kvm|qemu)
    echo "[factory-bootstrap] Installing QEMU/KVM guest tools..."
    apt-get install -y qemu-guest-agent spice-vdagent || true
    systemctl enable qemu-guest-agent 2>/dev/null || true
    systemctl restart qemu-guest-agent 2>/dev/null || true
    ;;

  oracle|virtualbox)
    echo "[factory-bootstrap] Installing VirtualBox guest tools..."
    apt-get install -y virtualbox-guest-dkms virtualbox-guest-utils || true
    ;;

  vmware)
    echo "[factory-bootstrap] Installing VMware guest tools (open-vm-tools)..."
    apt-get install -y open-vm-tools || true
    systemctl enable open-vm-tools 2>/dev/null || true
    systemctl restart open-vm-tools 2>/dev/null || true
    ;;

  microsoft)
    echo "[factory-bootstrap] Installing Hyper-V guest tools (best effort)..."
    apt-get install -y linux-cloud-tools-common hyperv-daemons 2>/dev/null || true
    ;;

  *)
    echo "[factory-bootstrap] No specific guest tools for virtualization type: ${VIRT}"
    ;;
esac

###############################################################################
# 5. Install convenience wrapper commands (rpi-build, rpi-test, factory-status)
###############################################################################

echo "[factory-bootstrap] Installing rpi-build and rpi-test wrappers..."

cat >/usr/local/bin/rpi-build <<'EOF'
#!/bin/sh
set -eu
PROJECT_DIR="/srv/TARPN-Contrib/rpi-oem"
if [ ! -d "$PROJECT_DIR" ]; then
  echo "rpi-build: project dir $PROJECT_DIR not found." >&2
  exit 1
fi
cd "$PROJECT_DIR"
exec ./scripts/build-image.sh "$@"
EOF

cat >/usr/local/bin/rpi-test <<'EOF'
#!/bin/sh
set -eu
PROJECT_DIR="/srv/TARPN-Contrib/rpi-oem"
if [ ! -d "$PROJECT_DIR" ]; then
  echo "rpi-test: project dir $PROJECT_DIR not found." >&2
  exit 1
fi
cd "$PROJECT_DIR"
exec ./scripts/test-image.sh "$@"
EOF

echo "[factory-bootstrap] Installing factory-status wrapper..."

cat >/usr/local/bin/factory-status <<'EOF'
#!/bin/sh
set -eu
PROJECT_DIR="/srv/TARPN-Contrib/rpi-oem"
SCRIPT="${PROJECT_DIR}/scripts/factory-status.sh"
if [ ! -x "$SCRIPT" ]; then
  echo "factory-status: script $SCRIPT not found or not executable." >&2
  exit 1
fi
exec "$SCRIPT" "$@"
EOF

chmod +x /usr/local/bin/rpi-build /usr/local/bin/rpi-test /usr/local/bin/factory-status

echo "[factory-bootstrap] Installed:"
echo "  - /usr/local/bin/rpi-build"
echo "  - /usr/local/bin/rpi-test"
echo "  - /usr/local/bin/factory-status"

###############################################################################
# 6. Dynamic hostname based on primary NIC MAC + mDNS (.local + alias)
###############################################################################

echo "[factory-bootstrap] Setting dynamic hostname..."

# Try to get primary interface from the default route
PRIMARY_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')

# Fallback: first non-loopback interface
if [ -z "${PRIMARY_IF:-}" ]; then
  PRIMARY_IF=$(ip -o link show 2>/dev/null | awk -F': ' '!/lo/ {print $2; exit}')
fi

if [ -z "${PRIMARY_IF:-}" ] || [ ! -e "/sys/class/net/${PRIMARY_IF}/address" ]; then
  echo "[factory-bootstrap] WARNING: Could not determine primary interface; leaving hostname unchanged."
else
  MAC=$(cat "/sys/class/net/${PRIMARY_IF}/address")
  MAC_SUFFIX=$(echo "$MAC" | awk -F':' '{printf("%s%s%s", toupper($(NF-2)), toupper($(NF-1)), toupper($NF))}')

  NEW_HOSTNAME="RPI-OEM-${MAC_SUFFIX}"

  echo "[factory-bootstrap] Primary interface: ${PRIMARY_IF}"
  echo "[factory-bootstrap] MAC: ${MAC}"
  echo "[factory-bootstrap] New hostname: ${NEW_HOSTNAME}"

  # Persist hostname
  echo "$NEW_HOSTNAME" > /etc/hostname
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$NEW_HOSTNAME" || true
  else
    hostname "$NEW_HOSTNAME" || true
  fi

  # Update /etc/hosts
  sed -i '/^127\.0\.1\.1\s/d' /etc/hosts 2>/dev/null || true
  echo "127.0.1.1   ${NEW_HOSTNAME}" >> /etc/hosts

  # Ensure Avahi / mDNS NSS config
  if grep -q '^hosts:' /etc/nsswitch.conf 2>/dev/null; then
    if ! grep -q 'mdns' /etc/nsswitch.conf 2>/dev/null; then
      sed -i 's/^hosts:.*/hosts:          files mdns4_minimal [NOTFOUND=return] dns mdns4 mdns/' /etc/nsswitch.conf
    fi
  fi

  systemctl enable avahi-daemon 2>/dev/null || true
  systemctl restart avahi-daemon 2>/dev/null || true

  # Advertise both unique .local name and generic RPI-OEM.local via Avahi
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -n "${IP:-}" ]; then
    echo "[factory-bootstrap] Adding Avahi alias for RPI-OEM.local"
    cat >/etc/avahi/hosts <<EOF
${IP} ${NEW_HOSTNAME}.local
${IP} RPI-OEM.local
EOF
    systemctl restart avahi-daemon 2>/dev/null || true
  fi

  echo "[factory-bootstrap] Hostname configured:"
  echo "  ${NEW_HOSTNAME}"
  echo "[factory-bootstrap] You should be able to SSH using (from same LAN):"
  echo "  builder@${NEW_HOSTNAME}.local"
  echo "  builder@RPI-OEM.local"
fi

###############################################################################
# 7. Done
###############################################################################

echo "[factory-bootstrap] Bootstrap complete."
echo "[factory-bootstrap] You can now:"
echo "  - Build images: rpi-build"
echo "  - Test images : rpi-test <image.img>"
echo "  - Check status: factory-status"
echo "[factory-bootstrap] Reboot is recommended."
