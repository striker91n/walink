#!/usr/bin/env bash
# fetch-runtime.sh
# Put NodeMobile.framework into vendor/.
#
# Two sources:
#
#   SOURCE=prebuilt (default) — FAST, no compilation.
#     Downloads the official prebuilt iOS runtime from the nodejs-mobile release and
#     lowers its declared minimum iOS version to 12.0 with scripts/patch-framework.py.
#     (The published framework declares MinimumOSVersion 13.0 only as a build setting;
#     the code itself links nothing newer than libc++/CoreFoundation/libSystem.)
#     NOTE: this binary is the official --jitless build.
#
#   SOURCE=ci — the JIT build.
#     Downloads the framework produced by .github/workflows/build-node-ios.yml
#     (default artifact NodeMobile-ios-arm64-jit).

set -euo pipefail

# Change to the repository root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SOURCE="${SOURCE:-prebuilt}"
NODEJS_MOBILE_VERSION="${NODEJS_MOBILE_VERSION:-v18.20.4}"
TARGET_IOS="${TARGET_IOS:-12.0}"
ART="${1:-NodeMobile-ios-arm64-jit}"
DEST="vendor/NodeMobile.framework"

mkdir -p vendor

if [[ "$SOURCE" == "ci" ]]; then
    # ---------------------------------------------------------------------
    # Source 1: the CI-built (optionally JIT) framework artifact.
    # ---------------------------------------------------------------------
    echo "==> Source: CI artifact '$ART' (JIT build)"
    RUN_ID="$(gh run list \
        --workflow build-node-ios.yml \
        --status success \
        -L 1 \
        --json databaseId \
        -q '.[0].databaseId' 2>/dev/null || true)"

    if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
        echo "ERROR: No successful run of 'build-node-ios.yml' found." >&2
        echo "       Run it first with:" >&2
        echo "           gh workflow run build-node-ios.yml -f jit=true" >&2
        echo "       Then wait for completion and re-run this script." >&2
        exit 1
    fi

    echo "==> Found successful run: $RUN_ID"
    TMPDIR_DL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DL"' EXIT

    echo "==> Downloading artifact '$ART' from run $RUN_ID..."
    gh run download "$RUN_ID" -n "$ART" -D "$TMPDIR_DL"
    SRC="$TMPDIR_DL/NodeMobile.framework"
    [[ -d "$SRC" ]] || { echo "ERROR: $SRC not found in the artifact." >&2; exit 1; }

    rm -rf "$DEST"
    cp -R "$SRC" "$DEST"
else
    # ---------------------------------------------------------------------
    # Source 0: the official prebuilt release (patched to iOS $TARGET_IOS).
    # ---------------------------------------------------------------------
    echo "==> Source: prebuilt nodejs-mobile $NODEJS_MOBILE_VERSION (patched to iOS $TARGET_IOS)"
    TMPDIR_DL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DL"' EXIT

    ZIP="$TMPDIR_DL/ios.zip"
    URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/${NODEJS_MOBILE_VERSION}/nodejs-mobile-${NODEJS_MOBILE_VERSION}-ios.zip"
    echo "==> Downloading $URL"
    curl -fL --retry 3 -o "$ZIP" "$URL"

    echo "==> Extracting..."
    unzip -q -o "$ZIP" -d "$TMPDIR_DL"

    SRC="$TMPDIR_DL/NodeMobile.xcframework/ios-arm64/NodeMobile.framework"
    [[ -d "$SRC" ]] || { echo "ERROR: $SRC not found in the release archive." >&2; exit 1; }

    rm -rf "$DEST"
    cp -R "$SRC" "$DEST"

    echo "==> Lowering the deployment target to iOS $TARGET_IOS..."
    python3 scripts/patch-framework.py "$DEST" "$TARGET_IOS"

    if command -v ldid >/dev/null 2>&1; then
        echo "==> Ad-hoc re-signing the patched dylib (signature was invalidated)..."
        ldid -S "$DEST/NodeMobile" || true
    else
        echo "WARNING: ldid not found; the code signature is stale. The device-side" >&2
        echo "         deploy re-signs the framework, so this is usually fine." >&2
    fi
fi

# -------------------------------------------------------------------------
# Verify.
# -------------------------------------------------------------------------
if [[ ! -f "$DEST/NodeMobile" ]]; then
    echo "ERROR: $DEST/NodeMobile is missing." >&2
    exit 1
fi

echo ""
echo "=== Runtime ready: $DEST ==="
ls -lh "$DEST/NodeMobile"
if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump --macho --private-headers "$DEST/NodeMobile" | grep -A4 LC_BUILD_VERSION || true
fi
python3 - "$DEST/Info.plist" <<'PY' || true
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
print("MinimumOSVersion:", d.get("MinimumOSVersion"))
PY
