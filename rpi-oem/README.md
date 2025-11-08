# TARPN-Contrib: Raspberry Pi OEM Image Factory

**Project:** `AF4H/TARPN-Contrib/rpi-oem`
**Purpose:** Automate building and testing customized Raspberry Pi OS images (“OEM images”) entirely from a stock Debian 13 (amd64) virtual machine.

---

## 🧭 Overview

This system creates a **reproducible Raspberry Pi image factory** inside a fresh Debian 13 VM.

The VM can be launched automatically from an iPXE ISO, which installs Debian 13 unattended and runs a bootstrap script that sets up the entire factory.

Once provisioned, the factory can:

* Download base Raspberry Pi OS images by label (e.g. `DEFAULT`, `BUSTER`)
* Apply overlays and package customizations
* Build new “OEM” images
* Test those images under QEMU emulation (Pi 3B)

No prebuilt VM images are distributed — everything builds from upstream Debian and the files in this repository.

---

## 🧉 Directory Layout

```
rpi-oem/
├─ provision/
│  ├─ ipxe-bootstrap.ipxe      # Tiny static script baked into ISO
│  ├─ ipxe-runtime.ipxe        # Live script chained from GitHub
│  ├─ preseed.cfg              # Debian 13 unattended installer config
│  ├─ factory-bootstrap.sh     # Bootstraps Debian into build factory
│  ├─ make-ipxe-iso.sh         # Builds the static iPXE ISO
│
├─ scripts/
│  ├─ setup-build-host.sh      # Installs QEMU + build tools
│  ├─ build-image.sh           # Builds OEM images from base images
│  ├─ extract-boot.sh          # Extracts /boot partition for QEMU
│  ├─ run-qemu-rpi3b.sh        # Boots image in QEMU (Pi 3B emulation)
│  ├─ guest-smoketest.sh       # Smoke test run inside the guest
│  └─ test-image.sh            # Launches QEMU and runs smoketest
│
├─ base-images.cfg             # Label → URL map for base images
├─ package-list.txt            # Packages to install in the OEM image
├─ overlay-rootfs/             # Files to overlay into OEM image rootfs
└─ artifacts/                  # Built & tested image outputs (gitignored)
```

---

## 🚀 Provisioning the Factory VM

### 1. Build the iPXE ISO (one-time)

On any Linux host:

```bash
cd rpi-oem
sudo provision/make-ipxe-iso.sh
```

This produces:

```
artifacts/factory-bootstrap.iso
```

That ISO is **static**; it just chain-loads the live iPXE script from GitHub.
You rarely need to rebuild it unless the GitHub path changes.

### 2. Launch a new VM (any hypervisor)

| Setting | Recommended                        |
| ------- | ---------------------------------- |
| CPUs    | 2+                                 |
| RAM     | 4 GB+                              |
| Disk    | 40 GB+                             |
| Network | NAT or bridged (Internet required) |

Attach `factory-bootstrap.iso` as the CD/DVD, boot the VM, and walk away.

### 3. Automated installation flow

1. iPXE boots from the ISO.
2. iPXE downloads `ipxe-runtime.ipxe` from GitHub.
3. The runtime script downloads the Debian 13 netboot installer and `preseed.cfg`.
4. Debian installs itself automatically.
5. The installer's `late_command` downloads and runs `factory-bootstrap.sh`.
6. That script installs build tools, clones this repo, and runs `setup-build-host.sh`.
7. The VM reboots into a ready-to-use factory.

After first boot:

```bash
ssh builder@<factory-vm-ip>
# or if local console:
login: builder
password: changeme  # (set in preseed.cfg)
```

---

## 🛠️ Building OEM Images

The factory provides a command-line wrapper `rpi-build` (points to `scripts/build-image.sh`).

### Base image selection

The script can use any of:

* A **local `.img` file**
* A **direct URL** (`http(s)://...`)
* A **label** defined in `base-images.cfg`

`base-images.cfg` example:

```ini
DEFAULT=https://example.com/rpi-img/tarpn-stable.img
STABLE=https://example.com/rpi-img/tarpn-stable.img
BUSTER=https://example.com/rpi-img/tarpn-buster.img
BOOKWORM=https://example.com/rpi-img/tarpn-bookworm.img
```

### Usage examples

```bash
# Build using the DEFAULT image (from base-images.cfg)
rpi-build

# Build using a specific label
rpi-build --label=BUSTER

# Build using a direct URL
rpi-build https://example.com/rpi-img/experimental.img exp-oem

# Build using a local file
rpi-build /srv/rpi-oem/base-images/raspios-lite.img my-oem
```

All downloaded images are cached in `rpi-oem/base-cache/`.

---

## 🤪 Testing OEM Images

The factory also provides `rpi-test` (points to `scripts/test-image.sh`).

```bash
rpi-test artifacts/20251108-oem.img
```

This performs:

1. Extract `/boot` files.
2. Launch QEMU as a Raspberry Pi 3B.
3. Wait for SSH.
4. Upload and run `guest-smoketest.sh` inside the emulated Pi.
5. Log results in `artifacts/test-*/`.

Example smoketest output:

```
[smoketest] Hostname:
raspberrypi
[smoketest] Uptime:
 13:10:05 up 1 min
PASS
```

---

## 🛠️ Customization Points

| File                   | Purpose                                                    |
| ---------------------- | ---------------------------------------------------------- |
| `overlay-rootfs/`      | Files copied into the image root (configs, services, etc.) |
| `package-list.txt`     | List of Debian packages to install inside the image        |
| `guest-smoketest.sh`   | Validation checks run inside the emulated Pi               |
| `base-images.cfg`      | Maps build labels to base image URLs                       |
| `factory-bootstrap.sh` | Controls how a Debian VM becomes a build host              |
| `preseed.cfg`          | Defines how the Debian 13 installer behaves                |
| `ipxe-runtime.ipxe`    | Controls which Debian suite and preseed to use             |
| `make-ipxe-iso.sh`     | Rebuilds the static iPXE boot ISO if URLs change           |

---

## 🖥️ Supported Hypervisors

Because the factory boots via a standard ISO and installs Debian from the Internet,
it runs on any hypervisor that can boot an ISO and provide network connectivity:

* **Proxmox VE**
* **VirtualBox**
* **VMware Workstation / Fusion**
* **KVM / QEMU**
* **Bare metal x86 hardware**

No per-platform adjustments are required.

---

## 🔁 Updating the Factory

The ISO (`factory-bootstrap.iso`) only chains to a GitHub-hosted iPXE script.
You can update any of the following without touching the ISO:

* `ipxe-runtime.ipxe` — change Debian version, mirrors, or preseed URL
* `preseed.cfg` — change installer behavior or user credentials
* `factory-bootstrap.sh` — change bootstrap logic or dependency list
* `base-images.cfg` — repoint image labels (e.g., `STABLE`, `BUSTER`)

Next time anyone boots from the ISO, the new configuration takes effect automatically.

---

## ⚙️ Typical End-to-End Flow

```bash
# 1. (One-time) build the ISO
sudo provision/make-ipxe-iso.sh

# 2. Boot a blank VM with that ISO attached
#    -> Debian 13 auto-installs and configures the factory

# 3. Inside the factory VM:
cd /srv/rpi-oem

# Build the latest OEM image
rpi-build --label=STABLE

# Test the result under QEMU
LATEST=$(ls artifacts/*STABLE*.img | sort | tail -n1)
rpi-test "$LATEST"
```

---

## 🤌 Roadmap / Future Enhancements

* `--refresh` flag for `rpi-build` to force re-download of cached base images
* Integration with pi-gen for full RPi OS rebuilds
* Extended smoke-tests (services, network behavior, radio stack checks)
* Optional `factory-status.sh` for diagnostics

---

**Maintainer:** `AF4H / TARPN-Contrib`
**License:** GPLv3 or later (adjust as needed)

---

*When the Internet crashes, ham radio is ready to serve.*
