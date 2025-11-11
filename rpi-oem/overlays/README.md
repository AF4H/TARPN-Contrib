
---

## 2) Integrate wrapper installs into `factory-bootstrap.sh`

Below is an example integration showing **where** to install `/usr/local/bin/rpi-build` and `/usr/local/bin/rpi-test` inside your `provision/factory-bootstrap.sh`.

I’ll show the core middle section where:

1. The repo is cloned to `/srv/TARPN-Contrib`.
2. `PROJECT_DIR` is set to `/srv/TARPN-Contrib/rpi-oem`.
3. Scripts are chmod’d.
4. **Wrappers are installed into `/usr/local/bin`.**
5. `setup-build-host.sh` is run.

You can splice this into your existing `factory-bootstrap.sh` (replace or merge with your current equivalent section).

```bash
#!/usr/bin/env bash
#
# provision/factory-bootstrap.sh
#
# One-time bootstrap script for the factory build host VM.
#

set -euo pipefail

log() {
  echo "[factory-bootstrap] $*" >&2
}

# Example: assume we've already created NEW_USER, installed base packages, etc.
# and now we are cloning the TARPN-Contrib repo and setting up rpi-oem.

REPO_ROOT="/srv/TARPN-Contrib"
PROJECT_DIR="${REPO_ROOT}/rpi-oem"

log "Cloning TARPN-Contrib repository into ${REPO_ROOT}..."
if [ ! -d "$REPO_ROOT/.git" ]; then
  git clone https://github.com/AF4H/TARPN-Contrib.git "$REPO_ROOT"
else
  log "Repository already present; pulling latest..."
  (cd "$REPO_ROOT" && git pull --ff-only)
fi

log "Ensuring rpi-oem project directory exists..."
if [ ! -d "$PROJECT_DIR" ]; then
  log "ERROR: rpi-oem directory not found at ${PROJECT_DIR}"
  exit 1
fi

cd "$PROJECT_DIR"

log "Ensuring all project scripts are executable..."
find "${PROJECT_DIR}" -type f -name "*.sh" -exec chmod +x {} \; || true

# --------------------------------------------------------------------
# NEW: install wrappers into /usr/local/bin
# --------------------------------------------------------------------
log "Installing rpi-oem command wrappers into /usr/local/bin..."

if [ -f "${PROJECT_DIR}/bin/rpi-build" ]; then
  install -m 0755 "${PROJECT_DIR}/bin/rpi-build" /usr/local/bin/rpi-build
else
  log "WARNING: ${PROJECT_DIR}/bin/rpi-build not found; skipping install"
fi

if [ -f "${PROJECT_DIR}/bin/rpi-test" ]; then
  install -m 0755 "${PROJECT_DIR}/bin/rpi-test" /usr/local/bin/rpi-test
else
  log "WARNING: ${PROJECT_DIR}/bin/rpi-test not found; skipping install"
fi

# Optionally you could add more wrappers later (e.g. rpi-status, etc.)
# --------------------------------------------------------------------

# Run build-host setup (qemu, binfmt, etc.)
if [ -x "${PROJECT_DIR}/scripts/setup-build-host.sh" ]; then
  log "Running scripts/setup-build-host.sh ..."
  "${PROJECT_DIR}/scripts/setup-build-host.sh"
else
  log "WARNING: scripts/setup-build-host.sh not found or not executable."
fi

log "factory-bootstrap.sh complete."
