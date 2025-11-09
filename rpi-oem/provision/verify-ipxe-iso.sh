#!/usr/bin/env bash
# verify-ipxe-iso.sh
# Confirm that an ISO (like factory-bootstrap.iso) has a BIOS boot entry.

ISO="${1:-rpi-oem/artifacts/factory-bootstrap.iso}"

if [[ ! -f "$ISO" ]]; then
  echo "❌ ISO not found: $ISO"
  echo "Usage: $0 /path/to/factory-bootstrap.iso"
  exit 1
fi

echo "🔍 Checking ISO boot catalog for BIOS boot entry..."
echo

# Requires 'xorriso' and 'isoinfo'
sudo apt-get update -y >/dev/null
sudo apt-get install -y xorriso genisoimage >/dev/null

# Show El Torito info
echo "=== El Torito Boot Info (should show 'Bootable' entry) ==="
isoinfo -d -i "$ISO" | grep -E 'Boot|System|Volume'
echo

echo "=== Detailed El Torito Report (xorriso) ==="
xorriso -indev "$ISO" -report_el_torito 2>/dev/null | sed 's/^/  /'
echo

# Look for telltale BIOS boot indicators
if xorriso -indev "$ISO" -report_el_torito 2>/dev/null | grep -qi 'bootable'; then
  echo "✅ BIOS boot entry detected in ISO."
else
  echo "⚠️  No explicit BIOS boot entry found. This may not boot on legacy BIOS."
fi

echo
echo "To test interactively, you can boot the ISO using:"
echo "  qemu-system-x86_64 -cdrom $ISO -boot d -m 512 -serial stdio"
echo
