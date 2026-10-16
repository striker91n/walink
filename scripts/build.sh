#!/usr/bin/env bash
# build.sh
# Local Theos build: generate launch images, copy the engine, and produce a .deb.

set -euo pipefail

# Change to the repository root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Theos setup
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"

echo "==> Building Walink with THEOS=$THEOS"

# ---------------------------------------------------------------------------
# 1. Sanity-check the Node runtime.
# ---------------------------------------------------------------------------
if [[ ! -f "vendor/NodeMobile.framework/NodeMobile" ]]; then
    echo "ERROR: vendor/NodeMobile.framework/NodeMobile is missing." >&2
    echo "       Run the following first to download the runtime:" >&2
    echo "           ./scripts/fetch-runtime.sh" >&2
    exit 1
fi

echo "==> NodeMobile.framework found."

# ---------------------------------------------------------------------------
# 2. Generate launch images.
# ---------------------------------------------------------------------------
echo "==> Generating launch images..."
./scripts/gen-launch-images.sh

# ---------------------------------------------------------------------------
# 3. Verify the engine exists and has its dependencies installed.
# ---------------------------------------------------------------------------
if [[ ! -f "engine/main.js" ]]; then
    echo "ERROR: engine/main.js not found." >&2
    exit 1
fi

if [[ ! -d "engine/node_modules/@whiskeysockets/baileys" ]]; then
    echo "ERROR: engine/node_modules/@whiskeysockets/baileys is missing." >&2
    echo "       Install engine dependencies with:" >&2
    echo "           cd engine && npm install --omit=optional --omit=dev" >&2
    exit 1
fi

echo "==> Engine sources and dependencies look good."

# ---------------------------------------------------------------------------
# 4. Copy engine/ into the iOS resource bundle.
# ---------------------------------------------------------------------------
DEST_ENGINE="ios/Resources/engine"
mkdir -p "$DEST_ENGINE"

echo "==> Copying engine/ into $DEST_ENGINE..."
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude 'node_modules/.cache' engine/ "$DEST_ENGINE/"
else
    echo "    (rsync not found; falling back to cp -R)"
    rm -rf "$DEST_ENGINE"
    cp -R engine "$DEST_ENGINE"
    # Ensure the cache directory is not bundled, even with the fallback.
    if [[ -d "$DEST_ENGINE/node_modules/.cache" ]]; then
        rm -rf "$DEST_ENGINE/node_modules/.cache"
    fi
fi

echo "==> Engine copied to $DEST_ENGINE"

# ---------------------------------------------------------------------------
# 5. Build the Theos package.
# ---------------------------------------------------------------------------
echo "==> Running 'make clean package' in ios/..."
cd ios
make clean package

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 6. Report the produced .deb.
# ---------------------------------------------------------------------------
DEB="$(find packages -maxdepth 1 -name '*.deb' -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-)"

if [[ -z "$DEB" || ! -f "$DEB" ]]; then
    echo "ERROR: No .deb package was produced in packages/." >&2
    exit 1
fi

echo ""
echo "=== Build successful ==="
echo "Produced package: $DEB"
ls -lh "$DEB"
