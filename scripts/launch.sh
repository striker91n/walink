#!/usr/bin/env bash
# launch.sh
# (Re)launch the Walink app on the jailbroken device over the USB tunnel.
#
# Why this exists as a script: on this install
#     uiopen --path /Applications/Walink.app   -> "No application at path: ..." (rc=1)
#     uiopen /Applications/Walink.app          -> rc=0 but nothing starts
# while
#     uiopen --bundleid com.striker91n.walink  -> works reliably
# so all launches should go through here rather than being hand-typed.
#
# Usage: ./scripts/launch.sh
# Env overrides: BUNDLE_ID, DEVICE_SSH_HOST, DEVICE_SSH_PORT, DEVICE_SSH_USER, DEVICE_SSH_PASS

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Optional local, gitignored overrides (e.g. DEVICE_SSH_PASS).
if [[ -f "$REPO_ROOT/scripts/device.env" ]]; then
    # shellcheck disable=SC1091
    . "$REPO_ROOT/scripts/device.env"
fi

BUNDLE_ID="${BUNDLE_ID:-com.striker91n.walink}"
DEVICE_SSH_HOST="${DEVICE_SSH_HOST:-127.0.0.1}"
DEVICE_SSH_PORT="${DEVICE_SSH_PORT:-2222}"
DEVICE_SSH_USER="${DEVICE_SSH_USER:-root}"
DEVICE_SSH_PASS="${DEVICE_SSH_PASS:-alpine}"
USB_DEVICE_SSH_PORT="${USB_DEVICE_SSH_PORT:-22}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# Over USB we need iproxy forwarding a local port to the device's ssh port.
if [[ "$DEVICE_SSH_HOST" == "127.0.0.1" || "$DEVICE_SSH_HOST" == "localhost" ]]; then
    if ! pgrep -x iproxy -a 2>/dev/null | grep -q "iproxy ${DEVICE_SSH_PORT} "; then
        echo "==> starting iproxy ${DEVICE_SSH_PORT} ${USB_DEVICE_SSH_PORT}"
        setsid iproxy "$DEVICE_SSH_PORT" "$USB_DEVICE_SSH_PORT" >/dev/null 2>&1 < /dev/null &
        sleep 1
    fi
fi

run_ssh() {
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$DEVICE_SSH_PASS" ssh "${SSH_OPTS[@]}" \
            -p "$DEVICE_SSH_PORT" "$DEVICE_SSH_USER@$DEVICE_SSH_HOST" "$@"
    else
        ssh "${SSH_OPTS[@]}" -p "$DEVICE_SSH_PORT" "$DEVICE_SSH_USER@$DEVICE_SSH_HOST" "$@"
    fi
}

echo "==> Launching $BUNDLE_ID"
run_ssh "uiopen --bundleid '$BUNDLE_ID'" || true

# Give SpringBoard a moment, then confirm it actually came up.
sleep 4
if run_ssh 'ps -A -o pid,comm | grep -q "[W]alink"'; then
    echo "==> Walink is running"
else
    echo "WARNING: Walink is not in the process list." >&2
    echo "         Most common cause: the device is locked/asleep — wake it and retry." >&2
    echo "         If it is awake, the SpringBoard icon cache may be stale:" >&2
    echo "             ssh ... 'killall SpringBoard'   # respring, safe on a JB device" >&2
    exit 1
fi
