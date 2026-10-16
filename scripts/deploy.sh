#!/usr/bin/env bash
# deploy.sh
# Install the newest built .deb onto the jailbroken iPhone over USB (iproxy).
# Assumes the device is jailbroken with Amethyst (Procursus bootstrap) and that
# OpenSSH is installed from Sileo/Zebra, listening on device port 22 (default).

set -euo pipefail

# Change to the repository root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Optional local, gitignored overrides (e.g. DEVICE_SSH_PASS). This keeps the
# device password out of a public repo. See scripts/device.env.example.
if [[ -f "$REPO_ROOT/scripts/device.env" ]]; then
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/device.env"
fi

# ---------------------------------------------------------------------------
# 1. Configuration (overridable via environment).
# ---------------------------------------------------------------------------
# Over USB, `iproxy` forwards a local port to the device's port 22, so we talk to
# 127.0.0.1. Set DEVICE_SSH_HOST to the phone's Wi-Fi/LAN IP to deploy wirelessly
# (no iproxy needed in that case).
DEVICE_SSH_HOST="${DEVICE_SSH_HOST:-127.0.0.1}"
DEVICE_SSH_PORT="${DEVICE_SSH_PORT:-2222}"
DEVICE_SSH_USER="${DEVICE_SSH_USER:-root}"
DEVICE_SSH_PASS="${DEVICE_SSH_PASS:-alpine}"
USB_DEVICE_SSH_PORT="${USB_DEVICE_SSH_PORT:-22}"

REMOTE_DEB="/var/mobile/walink.deb"

echo "==> Deploying to device via USB proxy"
echo "    Local proxy port: $DEVICE_SSH_PORT -> device port $USB_DEVICE_SSH_PORT"
echo "    SSH user:         $DEVICE_SSH_USER"

# ---------------------------------------------------------------------------
# 2. Verify helpers exist.
# ---------------------------------------------------------------------------
if [[ "$DEVICE_SSH_HOST" == "127.0.0.1" || "$DEVICE_SSH_HOST" == "localhost" ]] \
   && ! command -v iproxy >/dev/null 2>&1; then
    echo "ERROR: iproxy not found (required for USB deploys). Install libimobiledevice/usbmuxd," >&2
    echo "       or set DEVICE_SSH_HOST to the device's Wi-Fi IP to deploy wirelessly." >&2
    exit 1
fi

if ! command -v scp >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
    echo "ERROR: scp and ssh are required." >&2
    exit 1
fi

# Use sshpass for password-less authentication if it is available.
SSHPASS_BIN=""
if command -v sshpass >/dev/null 2>&1; then
    SSHPASS_BIN="$(command -v sshpass)"
else
    echo "WARNING: sshpass not installed. You will be prompted for the SSH password." >&2
fi

run_scp() {
    if [[ -n "$SSHPASS_BIN" ]]; then
        "$SSHPASS_BIN" -p "$DEVICE_SSH_PASS" scp "$@"
    else
        scp "$@"
    fi
}

run_ssh() {
    if [[ -n "$SSHPASS_BIN" ]]; then
        "$SSHPASS_BIN" -p "$DEVICE_SSH_PASS" ssh "$@"
    else
        ssh "$@"
    fi
}

# ---------------------------------------------------------------------------
# 3. Start iproxy in the background and clean it up on exit.
# ---------------------------------------------------------------------------
if [[ "$DEVICE_SSH_HOST" == "127.0.0.1" || "$DEVICE_SSH_HOST" == "localhost" ]]; then
    echo "==> Starting iproxy $DEVICE_SSH_PORT $USB_DEVICE_SSH_PORT (USB -> 127.0.0.1:$DEVICE_SSH_PORT)..."
    iproxy "$DEVICE_SSH_PORT" "$USB_DEVICE_SSH_PORT" >/tmp/walink-iproxy.log 2>&1 &
    IPROXY_PID=$!
    trap 'echo "==> Stopping iproxy (pid $IPROXY_PID)..."; kill "$IPROXY_PID" 2>/dev/null || true; wait "$IPROXY_PID" 2>/dev/null || true' EXIT
else
    echo "==> Using SSH host $DEVICE_SSH_HOST:$DEVICE_SSH_PORT (over the network, no iproxy)."
fi

sleep 1

# ---------------------------------------------------------------------------
# 4. Find the newest .deb package.
# ---------------------------------------------------------------------------
DEB="$(find packages -maxdepth 1 -name '*.deb' -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-)"

if [[ -z "$DEB" || ! -f "$DEB" ]]; then
    echo "ERROR: No .deb package found in packages/. Run ./scripts/build.sh first." >&2
    exit 1
fi

echo "==> Using package: $DEB"

# ---------------------------------------------------------------------------
# 5. Copy the .deb to the device.
# ---------------------------------------------------------------------------
SSH_OPTS=(-p "$DEVICE_SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
DEVICE_ADDR="$DEVICE_SSH_USER@$DEVICE_SSH_HOST"

echo "==> Copying $DEB to device ($REMOTE_DEB)..."
run_scp "${SSH_OPTS[@]}" "$DEB" "$DEVICE_ADDR:$REMOTE_DEB"

# ---------------------------------------------------------------------------
# 6. Install and respring / refresh the app.
# ---------------------------------------------------------------------------
echo "==> Installing package on device..."
run_ssh "${SSH_OPTS[@]}" "$DEVICE_ADDR" "
set -e

dpkg -i '$REMOTE_DEB' || apt-get -f install -y

# Re-sign the embedded Node framework so it can execute on the device.
ldid -S /Applications/Walink.app/Frameworks/NodeMobile.framework/NodeMobile || true

# Refresh the SpringBoard icon / UI cache for the app.
uicache -p /Applications/Walink.app || true

# Kill the app if it is running so it starts fresh on next launch.
killall -9 Walink || true
"

echo ""
echo "=== Deployment complete ==="
echo "Walink should now be installed/updated on the device."
echo ""
echo "REMINDER: Amethyst is semi-untethered. If you reboot the device, re-open"
echo "          the Amethyst app to re-jailbreak before Walink will run."
echo "          OpenSSH must be installed from Sileo/Zebra (default root pw: alpine)."
