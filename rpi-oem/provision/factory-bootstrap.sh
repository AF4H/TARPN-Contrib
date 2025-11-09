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

echo "[factory-bootstrap] Ensuring all project scripts are executable..."
find "${PROJECT_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || true

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

# Extra check: some environments under VirtualBox may mis-report
if [ -d /sys/class/dmi/id ]; then
  if grep -qi "virtualbox" /sys/class/dmi/id/product_name 2>/dev/null; then
    VIRT="virtualbox"
  fi
fi

echo "[factory-bootstrap] systemd-detect-virt (adjusted): ${VIRT}"

case "$VIRT" in
  kvm|qemu)
    echo "[factory-bootstrap] Installing QEMU/KVM guest tools..."
    apt-get install -y qemu-guest-agent spice-vdagent || true
    systemctl enable qemu-guest-agent 2>/dev/null || true
    systemctl restart qemu-guest-agent 2>/dev/null || true
    ;;

  oracle|virtualbox)
    echo "[factory-bootstrap] Installing VirtualBox guest tools..."
    apt-get install -y dkms linux-headers-$(uname -r) || true
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
# 6. Default hostname = rpi-oem + Avahi/mDNS
###############################################################################

echo "[factory-bootstrap] Configuring default hostname 'rpi-oem'..."

NEW_HOSTNAME="rpi-oem"

echo "$NEW_HOSTNAME" > /etc/hostname
if command-vox hostnamectl >/dev/null 2>&1 2>/dev/null; then
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

# Helper to keep /etc/avahi/hosts in sync with current IP + hostname
echo "[factory-bootstrap] Installing update-avahi-aliases helper..."

cat >/usr/local/bin/update-avahi-aliases.sh <<'EOF'
#!/bin/sh
# Auto-regenerate /etc/avahi/hosts based on current IP and hostname.

set -eu

AVAHI_HOSTS="/etc/avahi/hosts"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HN="$(hostname 2>/dev/null || true)"

if [ -z "${IP:-}" ] || [ -z "${HN:-}" ]; then
  echo "[update-avahi-aliases] Missing IP or hostname; skipping." >&2
  exit 0
fi

# Write Avahi hosts file with both current hostname and generic alias
cat > "${AVAHI_HOSTS}" <<EOF_INNER
# Auto-generated by update-avahi-aliases.sh
${IP} ${HN}.local rpi-oem.local
EOF_INNER

systemctl restart avahi-daemon 2>/dev/null || true
echo "[update-avahi-aliases] Updated ${AVAHI_HOSTS} -> ${IP} ${HN}.local rpi-oem.local"
EOF

chmod +x /usr/local/bin/update-avahi-aliases.sh

cat >/etc/systemd/system/update-avahi-aliases.service <<'EOF'
[Unit]
Description=Update Avahi aliases on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-avahi-aliases.sh
EOF

systemctl enable update-avahi-aliases.service 2>/dev/null || true

# Optional: dhclient hook (if using isc-dhcp-client) to run on DHCP renew
if [ -d /etc/dhcp/dhclient-exit-hooks.d ]; then
  echo "[factory-bootstrap] Installing DHCP hook for Avahi alias refresh..."
  cat >/etc/dhcp/dhclient-exit-hooks.d/99-avahi-refresh <<'EOF'
#!/bin/sh
# DHCP hook to update Avahi aliases when IP address changes.
case "$reason" in
  BOUND|RENEW|REBIND|REBOOT)
    /usr/local/bin/update-avahi-aliases.sh || true
    ;;
esac
EOF
  chmod +x /etc/dhcp/dhclient-exit-hooks.d/99-avahi-refresh
fi

# Initialize Avahi hosts once now
/usr/local/bin/update-avahi-aliases.sh || true

echo "[factory-bootstrap] You should be able to SSH using (from same LAN):"
echo "  builder@rpi-oem.local"
echo "  builder@$(hostname).local"


###############################################################################
# 7. First-login setup (rename host, new admin user, disable builder)
###############################################################################

echo "[factory-bootstrap] Installing first-login setup hooks..."

mkdir -p /var/lib/rpi-oem

# Install the first-login script from the repo into /usr/local/sbin
if [ -f "${PROJECT_DIR}/provision/rpi-oem-first-login.sh" ]; then
  install -m 0755 "${PROJECT_DIR}/provision/rpi-oem-first-login.sh" /usr/local/sbin/rpi-oem-first-login.sh
else
  echo "[factory-bootstrap] WARNING: rpi-oem-first-login.sh not found in provision/; skipping."
fi

# Profile hook to run first-login script on interactive shell
cat >/etc/profile.d/rpi-oem-first-login.sh <<'EOF'
#!/bin/sh
# Run first-login setup (if not already done) on interactive shells.
if [ -t 0 ] && [ -x /usr/local/sbin/rpi-oem-first-login.sh ]; then
  if [ ! -f /var/lib/rpi-oem/first-login-done ]; then
    /usr/local/sbin/rpi-oem-first-login.sh || true
  fi
fi
EOF

chmod +x /etc/profile.d/rpi-oem-first-login.sh

###############################################################################
# 8. GRUB timeout = 3 seconds
###############################################################################

echo "[factory-bootstrap] Setting GRUB timeout to 3 seconds (if GRUB present)..."

if [ -f /etc/default/grub ] && command -v update-grub >/dev/null 2>&1; then
  if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
  else
    echo 'GRUB_TIMEOUT=3' >> /etc/default/grub
  fi
  update-grub || true
else
  echo "[factory-bootstrap] GRUB not found or update-grub unavailable; skipping."
fi

###############################################################################
# 9. Done
###############################################################################

echo "[factory-bootstrap] Bootstrap complete."
echo "[factory-bootstrap] Default hostname : rpi-oem"
echo "[factory-bootstrap] Default user     : builder (will be replaced on first login as root)."
echo "[factory-bootstrap] On first login as root you will:"
echo "  - Optionally rename the host"
echo "  - Create a new admin user"
echo "  - Disable 'builder'"
echo "[factory-bootstrap] Reboot is recommended."
