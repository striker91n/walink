#!/usr/bin/env bash
# engine-log.sh
# Print the on-device engine log (last N lines) over the USB tunnel.
#
# The Node runtime's stdout/stderr are discarded on iOS, so engine/main.js mirrors its
# log to <Documents>/.walink/engine.log and serves it from GET /api/log.
#
# Usage:
#   ./scripts/engine-log.sh [lines]      # default 200
#
# Env:
#   WALINK_PORT   engine loopback port on the device (default 8787)

set -euo pipefail

LINES="${1:-200}"
PORT="${WALINK_PORT:-8787}"
URL="http://127.0.0.1:${PORT}/api/log?tail=${LINES}"

# pgrep -x iproxy only lists processes actually named "iproxy", so this cannot match this
# script's own command line the way an inline `pgrep -f "iproxy <port>"` can.
if ! pgrep -x iproxy -a 2>/dev/null | grep -q "iproxy ${PORT} ${PORT}"; then
    echo "==> starting iproxy ${PORT} ${PORT}" >&2
    setsid iproxy "$PORT" "$PORT" >/dev/null 2>&1 < /dev/null &
    sleep 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required." >&2
    exit 1
fi

BODY="$(curl -s -m 10 "$URL" || true)"
if [[ -z "$BODY" ]]; then
    echo "ERROR: no response from $URL" >&2
    echo "       Is Walink running, and is the device connected over USB?" >&2
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.stdout.write(sys.stdin.read())
    raise SystemExit(0)
print(f"# {doc.get(\"file\", \"?\")}")
lines = doc.get("lines") or []
if not lines:
    print("# (log is empty)")
for line in lines:
    print(line)
'
else
    printf '%s\n' "$BODY"
fi
