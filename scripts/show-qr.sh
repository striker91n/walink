#!/usr/bin/env bash
# show-qr.sh
# Continuously render the current WhatsApp companion-linking QR from the engine's loopback
# API, refreshing in place whenever WhatsApp rotates it (~every 20 s), so the code can be
# scanned from the terminal screen instead of the phone's own display.
#
# Usage: ./scripts/show-qr.sh [seconds]     # default 120
# Env:   WALINK_PORT (default 8787)
#
# Exits early once the device is linked.

set -euo pipefail

RUN_SECONDS="${1:-120}"
PORT="${WALINK_PORT:-8787}"
URL="http://127.0.0.1:${PORT}/api/state"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required." >&2
    exit 1
fi

# Make sure the USB tunnel to the engine's port exists.
if ! pgrep -x iproxy -a 2>/dev/null | grep -q "iproxy ${PORT} ${PORT}"; then
    if command -v iproxy >/dev/null 2>&1; then
        echo "==> starting iproxy ${PORT} ${PORT}" >&2
        setsid iproxy "$PORT" "$PORT" >/dev/null 2>&1 < /dev/null &
        sleep 1
    fi
fi

extract() {
    # $1 = field, stdin = /api/state JSON
    python3 -c '
import json, sys
field = sys.argv[1]
try:
    doc = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
value = doc.get(field)
print("" if value is None else value)
' "$1"
}

render_qr() {
    if command -v qrencode >/dev/null 2>&1; then
        printf '%s' "$1" | qrencode -t ANSIUTF8
    else
        echo "(qrencode not installed — raw QR payload follows; render it elsewhere)"
        printf '%s\n' "$1"
    fi
}

deadline=$(( $(date +%s) + RUN_SECONDS ))
last=""
while [[ "$(date +%s)" -lt "$deadline" ]]; do
    state="$(curl -s -m 5 "$URL" || true)"
    if [[ -z "$state" ]]; then
        echo "ERR no response from $URL (is Walink running?)" >&2
        sleep 2
        continue
    fi

    connected="$(printf '%s' "$state" | extract connected)"
    if [[ "$connected" == "True" || "$connected" == "true" ]]; then
        who="$(printf '%s' "$state" | extract user)"
        if command -v clear >/dev/null 2>&1; then clear; fi
        echo "Linked. The device is connected as: $who"
        exit 0
    fi

    qr="$(printf '%s' "$state" | extract qr)"
    if [[ -n "$qr" && "$qr" != "$last" ]]; then
        if command -v clear >/dev/null 2>&1; then clear; fi
        echo "WhatsApp (on the phone with your number) > Settings > Linked devices > Link a device"
        echo "Then scan this code — it refreshes automatically as WhatsApp rotates it:"
        echo
        render_qr "$qr"
        last="$qr"
    fi

    sleep 2
done

echo
echo "(stopped after ${RUN_SECONDS}s — re-run if you still need a code)"
