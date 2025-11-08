# TARPN Raspberry Pi OEM Factory Environment

This project builds, tests, and distributes custom Raspberry Pi OS images pre-loaded with TARPN or AF4H-contributed packages and configuration.
It provides a reproducible build system that runs on a standard **Debian 13 (amd64)** virtual machine using only open-source tooling.

---

## 🔄 Overview

The factory environment automatically:

1. Installs a minimal Debian 13 VM (via iPXE + preseed + CloudInit)
2. Bootstraps that VM into a self-contained **OEM image factory**
3. Builds and tests Raspberry Pi images from canonical base images
4. Publishes those artifacts for distribution or deployment

---

## 🚀 QuickStart for Testers

```bash
# Clone the project
git clone https://github.com/AF4H/TARPN-Contrib.git
cd TARPN-Contrib/rpi-oem

# Prepare the host VM (Debian 13 amd64)
sudo ./scripts/setup-build-host.sh

# Build the default (STABLE) Raspberry Pi OS image
./scripts/build-image.sh

# Or build a specific label (see base-images.cfg)
./scripts/build-image.sh --label=BUSTER
```

After building, images appear in:

```
rpi-oem/artifacts/
```

---

## 🧰 Directory Layout

| Path              | Purpose                                                |
| ----------------- | ------------------------------------------------------ |
| `provision/`      | iPXE, preseed, and bootstrap automation scripts        |
| `scripts/`        | Build, setup, and test tooling                         |
| `overlay-rootfs/` | Optional files copied into each image during build     |
| `artifacts/`      | Output directory for `.img` and `.iso` files           |
| `base-images.cfg` | Label mapping for upstream Raspberry Pi OS base images |

---

## 🧩 Factory Bootstrap

The Debian 13 host installs and runs:

```
rpi-oem/provision/factory-bootstrap.sh
```

That script:

* Installs base dependencies and build tools
* Clones the `AF4H/TARPN-Contrib` repository
* Runs `scripts/setup-build-host.sh`
* Detects virtualization and installs guest agents (KVM, VirtualBox, VMware, Hyper-V)
* Configures Avahi/mDNS and dynamic hostnames (`RPI-OEM-<MACSUFFIX>.local`)
* Provides convenient wrapper commands:

```bash
rpi-build        # Build Pi images from base-images.cfg
rpi-test         # Launch a test VM or hardware run
factory-status   # Display factory info and toolchain health
```

Accessible locally as:

```
builder@RPI-OEM.local
builder@RPI-OEM-XXXXXX.local
```

---

## ⚙️ Base Image Configuration (`base-images.cfg`)

Example:

```ini
# Default label just aliases STABLE
DEFAULT=STABLE

# Latest 32-bit Raspberry Pi OS Lite (Bookworm)
STABLE=https://downloads.raspberrypi.org/raspios_lite_armhf_latest

# Older releases
BUSTER=https://downloads.raspberrypi.org/raspios_oldstable_armhf/images/raspios_oldstable_armhf-2021-05-28/2021-05-07-raspios-buster-armhf-lite.img.xz
```

**Alias logic:**

* `DEFAULT=STABLE` means a plain `rpi-build` pulls whatever `STABLE` currently points to.
* Any label may alias another (chains up to 8 levels deep).
* The final value may be a URL or a local path (`.img`, `.xz`, `.gz`, `.zip`).

---

## 🤩 Script Reference

### `scripts/setup-build-host.sh`

Installs the full toolchain required to manipulate Raspberry Pi images:

* `qemu-user-static`, `binfmt-support`
* `kpartx`, `losetup`, `rsync`, `parted`, `dosfstools`, `e2fsprogs`
* `xz-utils`, `gzip`, `unzip`, `bzip2`
* `vim`, `less`, and networking utilities

Safe to re-run; missing packages are added automatically.

### `scripts/build-image.sh`

Builds a new OEM image from a base image label, file, or URL.

Features:

* Label aliasing (`DEFAULT → STABLE`)
* Redirect-aware downloads (preserves real filenames)
* Auto-decompression of `.xz`, `.gz`, `.zip` archives
* Optional overlay of `overlay-rootfs/`
* Optional package installation inside chroot (via `package-list.txt`)
* Produces ready-to-flash `.img` in `artifacts/`

Example:

```bash
# Use default (DEFAULT=STABLE)
rpi-build

# Explicit label
rpi-build --label=BUSTER

# Explicit URL
rpi-build https://example.com/my-base.img.xz
```

### `provision/make-ipxe-iso.sh`

Builds a **self-contained iPXE ISO** with embedded bootstrap script:

* Enables HTTPS, DNS, and CloudInit support in iPXE
* Embeds `ipxe-bootstrap.ipxe` (chainloads runtime config from GitHub)
* Produces `rpi-oem/artifacts/factory-bootstrap.iso`

---

## 🧮 Automated GitHub Builds

The ISO is rebuilt automatically on every change to provisioning scripts.

| Workflow             | Trigger                                           | Artifact / Output                       |
| -------------------- | ------------------------------------------------- | --------------------------------------- |
| **Build iPXE ISO**   | Push to `rpi-oem/provision/**` or manual dispatch | ISO artifact in Actions tab             |
| **Release iPXE ISO** | Git tag `rpi-oem-v*`                              | Published release with downloadable ISO |

**Latest ISO artifact:**
[➡️ Actions › Build iPXE ISO](https://github.com/AF4H/TARPN-Contrib/actions/workflows/build-ipxe-iso.yml)

**Stable release download:**
[⬇️ factory-bootstrap.iso (latest)](https://github.com/AF4H/TARPN-Contrib/releases/latest/download/factory-bootstrap.iso)

Badge:

[![Build iPXE ISO](https://github.com/AF4H/TARPN-Contrib/actions/workflows/build-ipxe-iso.yml/badge.svg)](https://github.com/AF4H/TARPN-Contrib/actions/workflows/build-ipxe-iso.yml)

---

## 🧠 Advanced Topics

### Hostname and Avahi behavior

Each VM’s hostname is derived from the last 3 octets of its primary NIC MAC:

```
RPI-OEM-<MACSUFFIX>.local
```

and advertised over mDNS together with a generic alias:

```
RPI-OEM.local
```

### Virtualization support

`factory-bootstrap.sh` automatically detects and installs the correct guest tools:

* **KVM/QEMU:** `qemu-guest-agent`, `spice-vdagent`
* **VirtualBox:** `virtualbox-guest-dkms`, `virtualbox-guest-utils`
* **VMware:** `open-vm-tools`
* **Hyper-V:** `hyperv-daemons`

---

## 🧾 Maintenance Notes

* Keep all project URLs in `base-images.cfg` — no need to re-embed into scripts.
* To test installer changes without rebuilding the ISO, just edit `ipxe-bootstrap.ipxe` or related GitHub-hosted scripts; the ISO chainloads them dynamically.
* The iPXE ISO can safely be treated as static between releases.

---

## 📜 License

All scripts are released under the MIT License unless otherwise noted.
© 2025 Donald McMorris (AF4H)
