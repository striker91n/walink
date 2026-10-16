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
#     WARNING: every v18.x prebuilt imports ___chkstk_darwin (an iOS 13+ symbol), which
#     makes it unloadable on iOS 12. The script refuses to install such a runtime; the
#     only prebuilt without the import is the 16.17.x line, e.g.
#         NODEJS_MOBILE_TAG=nodejs-mobile-v16.17.1 ./scripts/fetch-runtime.sh
#     For a Node 18 runtime that actually loads on iOS 12, use SOURCE=ci.
#
#   SOURCE=ci — the JIT build.
#     Downloads the framework produced by .github/workflows/build-node-ios.yml
#     (default artifact NodeMobile-ios-arm64-jit).

set -euo pipefail

# Change to the repository root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SOURCE="${SOURCE:-prebuilt}"
# Release tag. v18.x tags are bare ("v18.20.4"); the 16.x releases use a prefixed tag
# ("nodejs-mobile-v16.17.1") and are the only prebuilts that are not min-iOS-13.
NODEJS_MOBILE_TAG="${NODEJS_MOBILE_TAG:-${NODEJS_MOBILE_VERSION:-v18.20.4}}"
# Asset file name inside the release. Defaults to the tag with an "-ios.zip" suffix; the
# prefixed 16.x tags do NOT repeat the "nodejs-mobile-" prefix.
if [[ "$NODEJS_MOBILE_TAG" == nodejs-mobile-* ]]; then
    NODEJS_MOBILE_ASSET="${NODEJS_MOBILE_ASSET:-${NODEJS_MOBILE_TAG}-ios.zip}"
else
    NODEJS_MOBILE_ASSET="${NODEJS_MOBILE_ASSET:-nodejs-mobile-${NODEJS_MOBILE_TAG}-ios.zip}"
fi
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
    echo "==> Source: prebuilt nodejs-mobile $NODEJS_MOBILE_TAG (patched to iOS $TARGET_IOS)"
    TMPDIR_DL="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_DL"' EXIT

    ZIP="$TMPDIR_DL/ios.zip"
    URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/${NODEJS_MOBILE_TAG}/${NODEJS_MOBILE_ASSET}"
    echo "==> Downloading $URL"
    curl -fL --retry 3 -o "$ZIP" "$URL"

    echo "==> Extracting..."
    unzip -q -o "$ZIP" -d "$TMPDIR_DL"

    # The archive layout changed between releases (xcframework dir naming, plus a legacy
    # Release-iphoneos/). Locate the arm64 DEVICE slice rather than assuming a path.
    SRC="$(find "$TMPDIR_DL" -type d -path '*ios-arm64/NodeMobile.framework' -print -quit)"
    if [[ -z "$SRC" ]]; then
        # Pre-xcframework layout: a plain NodeMobile.framework, but never a simulator slice.
        SRC="$(find "$TMPDIR_DL" -type d -name 'NodeMobile.framework' \
                -not -path '*simulator*' -print -quit)"
    fi
    [[ -n "$SRC" && -d "$SRC" ]] || {
        echo "ERROR: no arm64 device NodeMobile.framework found in $ZIP." >&2
        find "$TMPDIR_DL" -name 'NodeMobile.framework' >&2 || true
        exit 1
    }
    echo "==> Using $SRC"

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

# -------------------------------------------------------------------------
# Guard: an iOS 12 runtime must not import ___chkstk_darwin.
#
# That helper was introduced with the iOS 13 SDK and does not exist in iOS 12's
# libSystem, so a framework that imports it dies at launch with
#     dyld: Symbol not found: ___chkstk_darwin
# (Referenced from: .../Walink.app/Frameworks/NodeMobile.framework/NodeMobile)
# It shows up as a NON-lazy __got binding, and lowering the declared minimum iOS
# version with patch-framework.py does NOT remove it. Apple's clang emits it for
# stack-probing (dynamic alloca) when the deployment target includes it, so a build
# with IPHONEOS_DEPLOYMENT_TARGET=12.0 (SOURCE=ci) or the v16.17.1 prebuilt avoids it.
# -------------------------------------------------------------------------
if command -v llvm-nm >/dev/null 2>&1; then
    if llvm-nm -u "$DEST/NodeMobile" 2>/dev/null | grep -q '___chkstk_darwin'; then
        echo "" >&2
        echo "ERROR: $DEST/NodeMobile imports ___chkstk_darwin, so it CANNOT load on iOS 12." >&2
        echo "       Re-fetch with SOURCE=ci (built with min iOS $TARGET_IOS) or use the" >&2
        echo "       v16 line, which is the only prebuilt without the reference:" >&2
        echo "           NODEJS_MOBILE_TAG=nodejs-mobile-v16.17.1 ./scripts/fetch-runtime.sh" >&2
        exit 1
    fi
    echo "==> OK: no ___chkstk_darwin import (iOS 12 compatible)"
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
