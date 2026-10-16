#!/usr/bin/env bash
# fetch-runtime.sh
# Download the latest successful NodeMobile-iOS build artifact from GitHub Actions
# and place NodeMobile.framework under vendor/.

set -euo pipefail

# Change to the repository root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ART="${1:-NodeMobile-ios-arm64-jit}"

echo "==> Fetching runtime artifact: $ART"

# ---------------------------------------------------------------------------
# 1. Find the latest successful run of build-node-ios.yml.
# ---------------------------------------------------------------------------
echo "==> Querying GitHub for the latest successful build-node-ios.yml run..."
RUN_ID="$(gh run list \
    --workflow build-node-ios.yml \
    --status success \
    -L 1 \
    --json databaseId \
    -q '.[0].databaseId' 2>/dev/null || true)"

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
    echo "ERROR: No successful run of 'build-node-ios.yml' found." >&2
    echo "       Run it first with:" >&2
    echo "           gh workflow run build-node-ios.yml" >&2
    echo "       Then wait for completion and re-run this script." >&2
    exit 1
fi

echo "==> Found successful run: $RUN_ID"

# ---------------------------------------------------------------------------
# 2. Download the artifact into a temporary directory.
# ---------------------------------------------------------------------------
TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

echo "==> Downloading artifact '$ART' from run $RUN_ID..."
gh run download "$RUN_ID" -n "$ART" -D "$TMPDIR_DL"

# ---------------------------------------------------------------------------
# 3. Move NodeMobile.framework into vendor/.
# ---------------------------------------------------------------------------
SRC_FRAMEWORK="$TMPDIR_DL/NodeMobile.framework"
if [[ ! -d "$SRC_FRAMEWORK" ]]; then
    echo "ERROR: Downloaded artifact does not contain NodeMobile.framework." >&2
    echo "       Contents of $TMPDIR_DL:" >&2
    find "$TMPDIR_DL" -maxdepth 2 -print >&2 || true
    exit 1
fi

mkdir -p vendor
DEST_FRAMEWORK="vendor/NodeMobile.framework"
if [[ -d "$DEST_FRAMEWORK" ]]; then
    echo "==> Removing existing $DEST_FRAMEWORK"
    rm -rf "$DEST_FRAMEWORK"
fi

mv "$SRC_FRAMEWORK" "$DEST_FRAMEWORK"
echo "==> Installed framework to: $DEST_FRAMEWORK"

# ---------------------------------------------------------------------------
# 4. Verify the framework binary exists and report its size.
# ---------------------------------------------------------------------------
BINARY="$DEST_FRAMEWORK/NodeMobile"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: $DEST_FRAMEWORK/NodeMobile not found." >&2
    exit 1
fi

SIZE="$(stat -c%s "$BINARY" 2>/dev/null || wc -c < "$BINARY")"
echo "==> Verified framework binary: $BINARY"
echo "    Size: $SIZE bytes"

# ---------------------------------------------------------------------------
# 5. (Optional) Report MinimumOSVersion from Info.plist.
# ---------------------------------------------------------------------------
INFO_PLIST="$DEST_FRAMEWORK/Info.plist"
if [[ -f "$INFO_PLIST" ]] && command -v python3 >/dev/null 2>&1; then
    MIN_OS="$(python3 -c "
import plistlib, sys
try:
    with open('$INFO_PLIST', 'rb') as f:
        pl = plistlib.load(f)
    print(pl.get('MinimumOSVersion', 'not specified'))
except Exception as e:
    print('unknown:', e)
" 2>/dev/null || true)"
    echo "    MinimumOSVersion: $MIN_OS"
fi
