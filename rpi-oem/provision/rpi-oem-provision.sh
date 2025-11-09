#!/bin/sh
# /usr/local/sbin/rpi-oem-first-login.sh
# Run on first interactive login to:
#   - Optionally rename the host
#   - Create a new admin user
#   - Disable 'builder'
# Self-deletes when done and writes a flag file.

set -eu

FLAG="/var/lib/rpi-oem/first-login-done"

# Only run once
if [ -f "$FLAG" ]; then
  exit 0
fi

# Only run in interactive shells
if [ ! -t 0 ]; then
  exit 0
fi

CURRENT_USER="$(id -un 2>/dev/null || echo "")"

# Require root to actually perform changes; non-root gets a hint
if [ "$CURRENT_USER" != "root" ]; then
  echo
  echo "RPI-OEM first-login setup has not been completed yet."
  echo "Please log in as root (or run 'sudo -i') and run this shell again."
  echo
  exit 0
fi

echo
echo "=== RPI-OEM First Login Setup ==="
echo

# 1) Hostname change
CUR_HN="$(hostname)"
printf "Current hostname is '%s'.\n" "$CUR_HN"
printf "Enter new hostname (leave blank to keep '%s'): " "$CUR_HN"
read -r NEW_HN || NEW_HN=""

if [ -n "$NEW_HN" ] && [ "$NEW_HN" != "$CUR_HN" ]; then
  echo "[first-login] Renaming host to '$NEW_HN'..."
  echo "$NEW_HN" > /etc/hostname
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$NEW_HN" || true
  else
    hostname "$NEW_HN" || true
  fi
  sed -i '/^127\.0\.1\.1\s/d' /etc/hosts 2>/dev/null || true
  echo "127.0.1.1   ${NEW_HN}" >> /etc/hosts

  if [ -x /usr/local/bin/update-avahi-aliases.sh ]; then
    /usr/local/bin/update-avahi-aliases.sh || true
  fi
fi

# 2) New admin user creation
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

echo "[first-login] Creating user '$NEW_USER' (you will be prompted for a password)..."
adduser "$NEW_USER"

echo "[first-login] Adding '$NEW_USER' to sudo group..."
usermod -aG sudo "$NEW_USER" || true

# Copy SSH keys from builder if present
if id builder >/dev/null 2>&1 && [ -d "/home/builder/.ssh" ]; then
  echo "[first-login] Copying SSH keys from 'builder' to '$NEW_USER'..."
  mkdir -p "/home/${NEW_USER}/.ssh"
  if [ -f /home/builder/.ssh/authorized_keys ]; then
    cp -a /home/builder/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/" 2>/dev/null || true
  fi
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
  chmod 700 "/home/${NEW_USER}/.ssh"
  [ -f "/home/${NEW_USER}/.ssh/authorized_keys" ] && chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys" || true
fi

# 3) Disable builder account
if id builder >/dev/null 2>&1; then
  echo "[first-login] Disabling 'builder' account..."
  passwd -l builder 2>/dev/null || true
  usermod -L builder 2>/dev/null || true
  usermod -s /usr/sbin/nologin builder 2>/dev/null || true
fi

# Mark as done and self-clean
mkdir -p /var/lib/rpi-oem
date_str="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "${date_str} by ${NEW_USER}" > "$FLAG"

echo "[first-login] Cleaning up setup scripts..."
rm -f /usr/local/sbin/rpi-oem-first-login.sh /etc/profile.d/rpi-oem-first-login.sh 2>/dev/null || true

echo
echo "First-login setup complete."
echo "You should now:"
echo "  - Open a new SSH session as: ${NEW_USER}@$(hostname).local"
echo "  - Stop using the 'builder' account."
echo "  - The first-login wizard has been removed (flag saved at $FLAG)."
echo
