#!/usr/bin/env bash
# bootstrap-theos.sh
# Install Theos on a Linux dev machine for iOS arm64 (Theos) builds.
# Supports Arch-family (pacman) and Debian/Ubuntu (apt-get).

set -euo pipefail

# Allow THEOS location to be overridden via environment.
THEOS="${THEOS:-$HOME/theos}"

echo "==> Bootstrapping Theos into: $THEOS"

# ---------------------------------------------------------------------------
# 1. Detect package manager and install prerequisites.
# ---------------------------------------------------------------------------
PKGS=(git make clang lld ldid dpkg xz perl fakeroot)

if command -v pacman >/dev/null 2>&1; then
    echo "==> Detected pacman (Arch-family). Will install: ${PKGS[*]}"
    if [[ "$EUID" -ne 0 ]]; then
        sudo pacman -S --needed --noconfirm "${PKGS[@]}"
    else
        pacman -S --needed --noconfirm "${PKGS[@]}"
    fi
elif command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu: xz is split into xz-utils.
    DEB_PKGS=(git make clang lld ldid dpkg xz-utils perl fakeroot)
    echo "==> Detected apt-get (Debian/Ubuntu). Will install: ${DEB_PKGS[*]}"
    if [[ "$EUID" -ne 0 ]]; then
        sudo apt-get update
        sudo apt-get install -y "${DEB_PKGS[@]}"
    else
        apt-get update
        apt-get install -y "${DEB_PKGS[@]}"
    fi
else
    echo "WARNING: No supported package manager found (looked for pacman, apt-get)."
    echo "         Please install these packages manually: ${PKGS[*]}"
    echo "         Continuing anyway..."
fi

# ---------------------------------------------------------------------------
# 2. Clone Theos if it isn't already present.
# ---------------------------------------------------------------------------
if [[ -d "$THEOS" ]]; then
    echo "==> $THEOS already exists; skipping Theos clone."
else
    echo "==> Cloning Theos (this may take a while)..."
    git clone --recursive https://github.com/theos/theos.git "$THEOS"
fi

# ---------------------------------------------------------------------------
# 3. Install an iOS SDK from theos/sdks.
# ---------------------------------------------------------------------------
SDKS_DIR="$THEOS/sdks"
mkdir -p "$SDKS_DIR"

TMPDIR_SDK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SDK"' EXIT

echo "==> Fetching theos/sdks into temporary directory..."
git clone --depth 1 https://github.com/theos/sdks.git "$TMPDIR_SDK/sdks"

# Find every iPhoneOS*.sdk directory.
mapfile -t SDK_PATHS < <(find "$TMPDIR_SDK/sdks" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | sort)

if [[ "${#SDK_PATHS[@]}" -eq 0 ]]; then
    echo "ERROR: No iPhoneOS*.sdk found in theos/sdks." >&2
    exit 1
fi

# Helper to extract the X.Y version from a path like .../iPhoneOS12.4.sdk
sdk_version() {
    basename "$1" | sed -n 's/^iPhoneOS\([0-9][0-9.]*\)\.sdk$/\1/p'
}

SELECTED_SDK=""
PREFERRED_MAJOR=12

# First, prefer the newest 12.x SDK.
for sdk in "${SDK_PATHS[@]}"; do
    ver="$(sdk_version "$sdk")"
    if [[ "$ver" == 12.* || "$ver" == 12 ]]; then
        if [[ -z "$SELECTED_SDK" ]] || [[ "$(printf '%s\n%s\n' "$(sdk_version "$SELECTED_SDK")" "$ver" | sort -V | tail -n1)" == "$ver" ]]; then
            SELECTED_SDK="$sdk"
        fi
    fi
done

# Otherwise, pick the lowest SDK >= 12.0.
if [[ -z "$SELECTED_SDK" ]]; then
    for sdk in "${SDK_PATHS[@]}"; do
        ver="$(sdk_version "$sdk")"
        if [[ -n "$ver" ]] && printf '%s\n' "$ver" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
            if [[ "$(printf '%s\n%s\n' "$ver" "$PREFERRED_MAJOR" | sort -V | tail -n1)" == "$ver" ]]; then
                if [[ -z "$SELECTED_SDK" ]] || [[ "$(printf '%s\n%s\n' "$(sdk_version "$SELECTED_SDK")" "$ver" | sort -V | head -n1)" == "$ver" ]]; then
                    SELECTED_SDK="$sdk"
                fi
            fi
        fi
    done
fi

# Final fallback: newest SDK available.
if [[ -z "$SELECTED_SDK" ]]; then
    for sdk in "${SDK_PATHS[@]}"; do
        ver="$(sdk_version "$sdk")"
        if [[ -z "$SELECTED_SDK" ]] || [[ "$(printf '%s\n%s\n' "$(sdk_version "$SELECTED_SDK")" "$ver" | sort -V | tail -n1)" == "$ver" ]]; then
            SELECTED_SDK="$sdk"
        fi
    done
fi

SDK_NAME="$(basename "$SELECTED_SDK")"
SDK_VER="$(sdk_version "$SELECTED_SDK")"
echo "==> Selected SDK: $SDK_NAME (version $SDK_VER)"

DEST_SDK="$SDKS_DIR/$SDK_NAME"
if [[ -d "$DEST_SDK" ]]; then
    echo "==> Removing existing $DEST_SDK"
    rm -rf "$DEST_SDK"
fi

cp -R "$SELECTED_SDK" "$DEST_SDK"
echo "==> Installed SDK into: $DEST_SDK"

# ---------------------------------------------------------------------------
# 4. Final instructions / verification.
# ---------------------------------------------------------------------------
echo ""
echo "=== Theos bootstrap complete ==="
echo "Add the following line to your shell profile (.bashrc/.zshrc):"
echo "    export THEOS=$THEOS"
echo ""

if [[ -f "$THEOS/bin/nic.pl" ]]; then
    echo "Verified: $THEOS/bin/nic.pl exists."
else
    echo "WARNING: $THEOS/bin/nic.pl not found. Theos may not have cloned correctly." >&2
fi
