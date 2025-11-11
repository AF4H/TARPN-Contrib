#!/bin/sh
# rpi-oem-first-login.sh
# Run ONCE as root (via sudo) on first interactive login to:
#   - Optionally rename the host
#   - Create a new admin user
#   - Disable 'builder' and remove its sudo access
#   - Self-delete and reboot

set -eu

# Only run in interactive shells (has a TTY)
if [ ! -t 0 ]; then
  exit 0
fi

# Must be root – this script is expected to be invoked via sudo
if [ "$(id -u)" -ne 0 ]; then
  echo "rpi-oem-first-login.sh: must be run as root (via sudo)." >&2
  exit 1
fi

echo
echo "=== RPI-OEM First Login Setup ==="
echo

###############################################################################
# 1) Hostname change
###############################################################################

CUR_HN="$(hostname)"
printf "Current hostname is '%s'.\n" "$CUR_HN"
printf "Enter new hostname (leave blank to keep '%s'): " "$CUR_HN"
read -r NEW_HN || NEW_HN=""

if [ -n "$NEW_HN" ] && [ "$NEW_HN" != "$CUR_HN" ]; then
  echo "[first-login] Renaming host to '$NEW_HN'..."
  printf "%s\n" "$NEW_HN" > /etc/hostname

  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$NEW_HN" || true
  else
    hostname "$NEW_HN" || true
  fi

  # Update /etc/hosts
  sed -i '/^127\.0\.1\.1\s/d' /etc/hosts 2>/dev/null || true
  printf "127.0.1.1   %s\n" "$NEW_HN" >> /etc/hosts

  # Refresh Avahi names
  if [ -x /usr/local/bin/update-avahi-aliases.sh ]; then
    /usr/local/bin/update-avahi-aliases.sh || true
  fi
fi

###############################################################################
# 2) New admin user creation
###############################################################################

echo
echo "We will now create a new admin user to replace 'builder'."

NEW_USER=""
while :; do
  printf "Enter new admin username (must be lowercase, no spaces): "
  read -r NEW_USER || NEW_USER=""
  if [ -z "$NEW_USER" ]; then
    echo "New username cannot be empty."
    continue
  fi
  if ! printf "%s" "$NEW_USER" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
    echo "Invalid username. Use lowercase letters, digits, '-', '_'."
    continue
  fi
  if id "$NEW_USER" >/dev/null 2>&1; then
    echo "User '$NEW_USER' already exists; pick a different name."
    continue
  fi
  break
done

echo "[first-login] Creating user '$NEW_USER'..."
useradd -m -s /bin/bash -G sudo "$NEW_USER"

echo "[first-login] Set password for '$NEW_USER'..."
passwd "$NEW_USER"

# Copy SSH keys from builder if available
if id builder >/dev/null 2>&1 && [ -d "/home/builder/.ssh" ]; then
  echo "[first-login] Copying SSH keys from 'builder' to '$NEW_USER'..."
  mkdir -p "/home/${NEW_USER}/.ssh"
  if [ -f /home/builder/.ssh/authorized_keys ]; then
    cp -a /home/builder/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/" 2>/dev/null || true
  fi
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
  chmod 700 "/home/${NEW_USER}/.ssh"
  if [ -f "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
    chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys" || true
  fi
fi

###############################################################################
# 3) Disable builder account
###############################################################################

if id builder >/dev/null 2>&1; then
  echo "[first-login] Disabling 'builder' account..."
  passwd -l builder 2>/dev/null || true
  usermod -L builder 2>/dev/null || true
  usermod -s /usr/sbin/nologin builder 2>/dev/null || true
fi

###############################################################################
# 4) Remove passwordless sudo for builder
###############################################################################

if id builder >/dev/null 2>&1; then
  echo "[first-login] Removing sudo access for 'builder'..."
  rm -f /etc/sudoers.d/010_builder-nopasswd /etc/sudoers.d/builder-nopasswd 2>/dev/null || true
fi

###############################################################################
# 5) Self-clean: remove this script and its profile hook
###############################################################################

echo "[first-login] Cleaning up setup scripts..."
rm -f /usr/local/sbin/rpi-oem-first-login.sh /etc/profile.d/rpi-oem-first-login.sh 2>/dev/null || true

###############################################################################
# 6) Final notes and reboot
###############################################################################

echo
echo "First-login setup complete."
echo "You should now:"
echo "  - Open a new SSH session as: ${NEW_USER}@$(hostname).local"
echo "  - Stop using the 'builder' account."
echo
echo "[first-login] System will reboot now to finalize configuration..."
sleep 3
reboot
