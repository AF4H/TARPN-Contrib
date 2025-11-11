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

echo "[factory-bootstrap] Updating APT package index..."
apt-get update -y

echo "[factory-bootstrap] Installing core packages..."
apt-get install -y \
  ca-certificates curl wget git jq vim sudo less \
  avahi-daemon avahi-utils net-tools dnsutils \
  lsb-release locales tzdata \
  bash-completion systemd-sysv eject

###############################################################################
# 1a. Locale and timezone sanity
###############################################################################

# Set a sane default locale (en_US.UTF-8) if not already configured
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
  echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
fi

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Set timezone to UTC unless something else is explicitly configured
if [ ! -f /etc/timezone ] || ! grep -q "." /etc/timezone 2>/dev/null; then
  echo "Etc/UTC" > /etc/timezone
  ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata || true
fi

###############################################################################
# 1b. Hostname and Avahi baseline
###############################################################################

DEFAULT_HOSTNAME="rpi-oem"
CURRENT_HOSTNAME="$(hostname)"

if [ "$CURRENT_HOSTNAME" != "$DEFAULT_HOSTNAME" ]; then
  echo "[factory-bootstrap] Setting hostname to ${DEFAULT_HOSTNAME}"
  echo "${DEFAULT_HOSTNAME}" > /etc/hostname
  sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${DEFAULT_HOSTNAME}/" /etc/hosts || true
  hostnamectl set-hostname "${DEFAULT_HOSTNAME}" || true
fi

echo "[factory-bootstrap] Ensuring Avahi is enabled..."
systemctl enable avahi-daemon 2>/dev/null || true
systemctl restart avahi-daemon 2>/dev/null || true

###############################################################################
# 2. Clone or update TARPN-Contrib and rpi-oem
###############################################################################

mkdir -p "${BASE_DIR}"

if [ ! -d "${REPO_DIR}/.git" ]; then
  echo "[factory-bootstrap] Cloning TARPN-Contrib repository..."
  git clone "${REPO_URL}" "${REPO_DIR}"
else
  echo "[factory-bootstrap] Repository already exists; pulling latest..."
  (
    cd "${REPO_DIR}"
    git fetch --all --prune
    git reset --hard origin/HEAD || git reset --hard origin/main || true
  )
fi

if [ ! -d "${PROJECT_DIR}" ]; then
  echo "[factory-bootstrap] ERROR: rpi-oem project directory not found at ${PROJECT_DIR}"
  exit 1
fi

cd "${PROJECT_DIR}"
echo "[factory-bootstrap] Now in project dir: $(pwd)"

echo "[factory-bootstrap] Ensuring all project scripts are executable..."
find "${PROJECT_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || true

###############################################################################
# 3. Install rpi-oem command wrappers into /usr/local/bin
###############################################################################

echo "[factory-bootstrap] Installing rpi-oem command wrappers into /usr/local/bin..."

if [ -f "${PROJECT_DIR}/bin/rpi-build" ]; then
  install -m 0755 "${PROJECT_DIR}/bin/rpi-build" /usr/local/bin/rpi-build
else
  echo "[factory-bootstrap] WARNING: ${PROJECT_DIR}/bin/rpi-build not found; skipping install"
fi

if [ -f "${PROJECT_DIR}/bin/rpi-test" ]; then
  install -m 0755 "${PROJECT_DIR}/bin/rpi-test" /usr/local/bin/rpi-test
else
  echo "[factory-bootstrap] WARNING: ${PROJECT_DIR}/bin/rpi-test not found; skipping install"
fi

###############################################################################
# 4. Run setup-build-host.sh (installs QEMU, kpartx, etc.)
###############################################################################
if [ -x "./scripts/setup-build-host.sh" ]; then
  echo "[factory-bootstrap] Running scripts/setup-build-host.sh ..."
  ./scripts/setup-build-host.sh
else
  echo "[factory-bootstrap] WARNING: scripts/setup-build-host.sh not found or not executable."
fi

###############################################################################
# 5. VM guest tools (VirtualBox, QEMU/KVM, VMware, Hyper-V)
###############################################################################

echo "[factory-bootstrap] Detecting virtualization for guest tools..."
if command -v systemd-detect-virt >/devnull 2>&1; then
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
    apt-get install -y dkms "linux-headers-$(uname -r)" || true
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

  none|container|*)
    echo "[factory-bootstrap] No special guest tools installed for virtualization=${VIRT}"
    ;;
esac

###############################################################################
# 6. Create temporary 'builder' user and grant sudo for first login
###############################################################################

NEW_USER="builder"

if ! id "${NEW_USER}" >/dev/null 2>&1; then
  echo "[factory-bootstrap] Creating temporary user '${NEW_USER}'..."
  useradd -m -s /bin/bash "${NEW_USER}"
  echo "${NEW_USER}:${NEW_USER}" | chpasswd
else
  echo "[factory-bootstrap] User '${NEW_USER}' already exists; not recreating."
fi

# Add builder to sudo
if ! grep -q "^${NEW_USER} " /etc/sudoers 2>/dev/null; then
  echo "[factory-bootstrap] Granting passwordless sudo to ${NEW_USER} for bootstrap..."
  echo "${NEW_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/90-${NEW_USER}-bootstrap
  chmod 440 /etc/sudoers.d/90-${NEW_USER}-bootstrap
fi

# Let builder own /srv/TARPN-Contrib if helpful
chown -R "${NEW_USER}:${NEW_USER}" "${REPO_DIR}" || true

###############################################################################
# 6a. MOTD and pre-login banner (console)
###############################################################################

# MOTD (shown *after* login)
cat >/etc/motd <<'EOF'
TARPN Raspberry Pi OEM Factory VM
---------------------------------

This system was provisioned as a build factory for Raspberry Pi images.

Default user:     builder
Default password: builder

On first login, a wizard will:
  - Allow you to rename the host
  - Create a new admin user
  - Disable 'builder' and remove its sudo access

To begin, log in as 'builder' and follow the instructions.
EOF

# Pre-login banner on console: /etc/issue
cat >/etc/issue <<'EOF'
TARPN Raspberry Pi OEM Factory VM
---------------------------------

Login as 'builder' (password: builder) to run the first-boot wizard.

Hostname: \n
EOF

###############################################################################
# 6b. Install factory-status script (if present)
###############################################################################

if [ -x "${PROJECT_DIR}/scripts/factory-status.sh" ]; then
  echo "[factory-bootstrap] Installing factory-status.sh to /usr/local/bin/factory-status ..."
  install -m 0755 "${PROJECT_DIR}/scripts/factory-status.sh" /usr/local/bin/factory-status
else
  echo "[factory-bootstrap] factory-status.sh not found; skipping."
fi

###############################################################################
# 6c. Avahi alias updater (so rpi-oem.local always works)
###############################################################################

cat >/usr/local/bin/update-avahi-aliases.sh <<'EOF'
#!/bin/sh
set -eu

AVAHI_HOSTS="/etc/avahi/hosts"

# Determine current IPv4 address on primary interface (best effort)
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HN="$(hostname)"

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
  cat >/etc/dhcp/dhclient-exit-hooks.d/update-avahi-aliases <<'EOF'
#!/bin/sh
if [ "$reason" = "BOUND" ] || [ "$reason" = "RENEW" ] || [ "$reason" = "REBIND" ] || [ "$reason" = "REBOOT" ]; then
  /usr/local/bin/update-avahi-aliases.sh || true
fi
EOF
  chmod +x /etc/dhcp/dhclient-exit-hooks.d/update-avahi-aliases
fi

###############################################################################
# 7. First-login setup (rename host, new admin user, disable builder)
###############################################################################

echo "[factory-bootstrap] Installing first-login setup (on first login)..."

# Install the first-login script from the repo into /usr/local/sbin
mkdir -p /var/lib/rpi-oem

if [ -f "${PROJECT_DIR}/provision/rpi-oem-first-login.sh" ]; then
  install -m 0755 "${PROJECT_DIR}/provision/rpi-oem-first-login.sh" /usr/local/sbin/rpi-oem-first-login.sh
else
  echo "[factory-bootstrap] WARNING: rpi-oem-first-login.sh not found in project; first login wizard will be unavailable."
fi

# Marker file so the first-login script knows it hasn't run yet
touch /var/lib/rpi-oem/first-login-pending

# Ensure builder home exists and is owned correctly
if [ -d "/home/${NEW_USER}" ]; then
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}"
fi

# Configure builder's login shell to run the first-login script once, on first login
cat >/home/${NEW_USER}/.profile <<'EOF'
# ~/.profile for builder - runs the first-boot wizard once on first login.

# If the first-login marker exists, run the wizard as root via sudo.
if [ -f /var/lib/rpi-oem/first-login-pending ]; then
  if [ -x /usr/local/sbin/rpi-oem-first-login.sh ]; then
    echo
    echo ">>> Running TARPN RPi OEM first-boot wizard (as root via sudo) ..."
    echo
    sudo /usr/local/sbin/rpi-oem-first-login.sh
  else
    echo "WARNING: first-login script /usr/local/sbin/rpi-oem-first-login.sh not found or not executable."
  fi
fi

# After first boot is complete, a normal interactive shell is fine.
# If this is an interactive session, drop into bash.
if [ -n "$PS1" ]; then
  [ -x /bin/bash ] && exec /bin/bash --login || true
fi
EOF

chown "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.profile"
chmod 0644 "/home/${NEW_USER}/.profile"

echo "[factory-bootstrap] First-login is now triggered by builder's first login (SSH or console)."
echo "[factory-bootstrap] Builder login hint:"
echo "  builder@$(hostname).local"

###############################################################################
# 8. SSH and basic security defaults
###############################################################################

echo "[factory-bootstrap] Ensuring SSH server is installed..."
apt-get install -y openssh-server

# Disable root SSH login and password auth for root (best effort)
if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
  # Password auth for builder remains enabled initially.
  systemctl restart ssh 2>/dev/null || true
fi

###############################################################################
# 9. Post-bootstrap cleanup
###############################################################################

echo "[factory-bootstrap] Attempting to eject virtual CD-ROM (if present)..."
eject /dev/cdrom 2>/dev/null || eject /dev/sr0 2>/dev/null || true

echo "[factory-bootstrap] Bootstrap complete."
echo "[factory-bootstrap] Default hostname : rpi-oem"
echo "[factory-bootstrap] Default user     : builder (temporary, for first login only)."
echo "[factory-bootstrap] On first login as 'builder' you will:"
echo "  - Optionally rename the host"
echo "  - Create a new admin user"
echo "  - Disable 'builder' and remove its sudo access"
echo "[factory-bootstrap] The first-login wizard will reboot the system automatically when done (depending on its logic)."
