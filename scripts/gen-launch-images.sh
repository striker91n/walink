#!/usr/bin/env bash
# gen-launch-images.sh
# Generate solid-black PNG launch images for the iPhone 6 Plus using a minimal
# pure-Python PNG encoder (zlib + struct only; no PIL/Pillow required).

set -euo pipefail

# Change to the repository root (parent of this script's directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="ios/Resources"
mkdir -p "$OUT_DIR"

# Arguments: width height out_path
generate_png() {
    local width="$1"
    local height="$2"
    local out_path="$3"

    python3 - "$width" "$height" "$out_path" <<'PY'
import sys, zlib, struct

width = int(sys.argv[1])
height = int(sys.argv[2])
out_path = sys.argv[3]

# PNG signature
sig = b'\x89PNG\r\n\x1a\n'

def chunk(chunk_type, data):
    return (
        struct.pack('>I', len(data)) +
        chunk_type +
        data +
        struct.pack('>I', zlib.crc32(chunk_type + data) & 0xffffffff)
    )

# IHDR: 8-bit RGB (color type 2), no interlace
ihdr_data = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
ihdr = chunk(b'IHDR', ihdr_data)

# Raw image: each scanline is filter byte 0 (none) followed by RGB triples.
# Solid black -> all bytes are zero, so the scanlines compress trivially.
row = b'\x00' + (b'\x00\x00\x00' * width)
raw = row * height
idat_data = zlib.compress(raw)
idat = chunk(b'IDAT', idat_data)

iend = chunk(b'IEND', b'')

with open(out_path, 'wb') as f:
    f.write(sig + ihdr + idat + iend)
PY
}

echo "==> Generating launch images in $OUT_DIR..."

generate_png 1242 2208 "$OUT_DIR/Launch-1242x2208.png"
generate_png 2208 1242 "$OUT_DIR/Launch-2208x1242.png"

echo "==> Done. Generated files:"
ls -lh "$OUT_DIR"/Launch-*.png
