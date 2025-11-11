#!/bin/sh
# factory-status.sh
# Show high-level status of the RPI-OEM factory VM.

set -eu

PROJECT_DIR="/srv/TARPN-Contrib/rpi-oem"
BASE_CFG="${PROJECT_DIR}/base-images.cfg"

echo "=== RPI-OEM Factory Status ==="
echo

###############################################################################
# Repo info
###############################################################################

if [ -d "$PROJECT_DIR/.git" ]; then
  cd "$PROJECT_DIR"
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  REV_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "Project directory : $PROJECT_DIR"
  echo "Git branch        : $BRANCH"
  echo "Git revision      : $REV_SHORT"
else
  echo "Project directory : $PROJECT_DIR (not a git repo?)"
fi

echo

###############################################################################
# First-login / account status
###############################################################################

first_login_status="UNKNOWN"
builder_shell="(missing)"
if id builder >/dev/null 2>&1; then
  builder_shell="$(getent passwd builder | cut -d: -f7 || echo '?')"
  case "$builder_shell" in
    ""|"/usr/sbin/nologin"|"/bin/false")
      if [ -x /usr/local/sbin/rpi-oem-first-login.sh ]; then
        first_login_status="PENDING (builder disabled, but first-login script still present?)"
      else
        first_login_status="COMPLETE (builder disabled)"
      fi
      ;;
    *)
      if [ -x /usr/local/sbin/rpi-oem-first-login.sh ]; then
        first_login_status="PENDING (builder enabled; first login wizard active)"
      else
        first_login_status="INCONSISTENT (builder enabled; wizard missing)"
      fi
      ;;
  esac
else
  if [ -x /usr/local/sbin/rpi-oem-first-login.sh ]; then
    first_login_status="INCONSISTENT (no builder; wizard still present)"
  else
    first_login_status="COMPLETE (no builder account; wizard gone)"
  fi
fi

echo "First-login status : $first_login_status"
echo "builder shell      : $builder_shell"

###############################################################################
# Hostname / mDNS / Avahi
###############################################################################

HN="$(hostname 2>/dev/null || echo '?')"
IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

echo
echo "Hostname           : $HN"
[ -n "$IP" ] && echo "Primary IP         : $IP"

if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
  echo "Avahi daemon       : active"
else
  echo "Avahi daemon       : NOT active"
fi

if [ -f /etc/avahi/hosts ]; then
  echo "Avahi hosts        :"
  sed -e 's/^/  /' /etc/avahi/hosts
fi

echo

###############################################################################
# Virtualization & guest tools
###############################################################################

if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT="$(systemd-detect-virt 2>/dev/null || echo 'none')"
else
  VIRT="unknown"
fi

echo "Virtualization     : $VIRT"

check_service() {
  svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "  $svc : active"
  else
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      echo "  $svc : installed, NOT active"
    else
      echo "  $svc : not installed"
    fi
  fi
}

case "$VIRT" in
  kvm|qemu)
    echo "Guest tools        :"
    check_service "qemu-guest-agent"
    check_service "spice-vdagent"
    ;;
  oracle|virtualbox)
    echo "Guest tools        : VirtualBox (dkms, guest utils)"
    dpkg -l 2>/dev/null | awk '/virtualbox-guest-|linux-headers/ {print "  " $2 " " $3}'
    ;;
  vmware)
    echo "Guest tools        :"
    check_service "open-vm-tools"
    ;;
  microsoft)
    echo "Guest tools        : Hyper-V daemons"
    dpkg -l 2>/dev/null | awk '/hyperv-daemons|linux-cloud-tools/ {print "  " $2 " " $3}'
    ;;
  *)
    echo "Guest tools        : (no specific tools detected for '"$VIRT"')"
    ;;
esac

echo

###############################################################################
# Core tools for image building
###############################################################################

echo "Core build tools   :"

check_cmd() {
  cmd="$1"
  pkg_hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  %-15s : OK\n" "$cmd"
  else
    printf "  %-15s : MISSING (try: apt install %s)\n" "$cmd" "$pkg_hint"
  fi
}

check_cmd qemu-arm-static qemu-user-static
check_cmd kpartx kpartx
check_cmd losetup util-linux
check_cmd rsync rsync
check_cmd parted parted
check_cmd mkfs.vfat dosfstools
check_cmd mkfs.ext4 e2fsprogs
check_cmd xz xz-utils
check_cmd gzip gzip
check_cmd unzip unzip

echo

###############################################################################
# Base image configuration (base-images.cfg)
###############################################################################

if [ -f "$BASE_CFG" ]; then
  echo "Base images        : (from $(basename "$BASE_CFG"))"
  # List raw labels and values
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      split($0, a, "=");
      if (length(a[1]) > 0 && length(a[2]) > 0) {
        printf "  %-12s = %s\n", a[1], a[2];
      }
    }
  ' "$BASE_CFG"

  # Resolve DEFAULT chain (up to 8 levels)
  DEFAULT_TARGET="$(awk -F= '/^DEFAULT=/ {print $2; exit}' "$BASE_CFG" | tr -d " \t")"

  if [ -n "$DEFAULT_TARGET" ]; then
    echo
    echo "Default build chain:"
    chain="DEFAULT"
    label="$DEFAULT_TARGET"
    final=""
    depth=0

    while [ -n "$label" ] && [ $depth -lt 8 ]; do
      val="$(awk -F= -v key="$label" '$1==key {print $2}' "$BASE_CFG" | tail -n1 | tr -d " \t")"

      if [ -z "$val" ]; then
        # No further alias; label is likely literal URL/path
        final="$label"
        chain="$chain -> $label"
        label=""
        break
      fi

      case "$val" in
        http://*|https://*|ftp://*|file:*|/*|*.*/*)
          # Treat as final URL/path
          chain="$chain -> $label"
          final="$val"
          label=""
          break
          ;;
        *)
          # Treat as alias to another label
          chain="$chain -> $label"
          label="$val"
          ;;
      esac

      depth=$((depth + 1))
    done

    if [ -n "$final" ]; then
      echo "  $chain"
      echo "  Final URL/path   : $final"
    else
      echo "  DEFAULT maps to  : $DEFAULT_TARGET (could not fully resolve)"
    fi
  else
    echo "Default build chain:"
    echo "  DEFAULT not defined in base-images.cfg"
  fi
else
  echo "Base images        : base-images.cfg not found at $BASE_CFG"
fi

echo
echo "Use 'rpi-build' to build images and 'rpi-test' to validate them."
echo "This report is provided by scripts/factory-status.sh"
