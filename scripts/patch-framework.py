#!/usr/bin/env python3
"""Lower a Mach-O framework's declared minimum iOS version.

nodejs-mobile publishes a prebuilt NodeMobile.xcframework whose device slice
declares `MinimumOSVersion = 13.0` (and `LC_BUILD_VERSION minos 13.0`), so dyld
refuses to load it on iOS 12 even though the framework only links
libc++ / CoreFoundation / libSystem. Rather than recompiling V8 for ~30 minutes
in CI, we lower the *declared* minimum on the prebuilt binary:

  * Info.plist      -> MinimumOSVersion
  * Mach-O load cmd -> LC_BUILD_VERSION.minos (or LC_VERSION_MIN_IPHONEOS.version)

The code signature (if any) is invalidated by this edit, so re-sign the framework
afterwards (e.g. `ldid -S`).

Usage: patch-framework.py <path/to/NodeMobile.framework> <major>.<minor>
"""

import plistlib
import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25


def pack_ver(major: int, minor: int) -> int:
    # X.Y.Z is packed as (major << 16) | (minor << 8) | patch.
    return (major << 16) | (minor << 8)


def patch_macho(path: Path, major: int, minor: int) -> None:
    data = bytearray(path.read_bytes())
    (magic,) = struct.unpack_from("<I", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"{path}: not a 64-bit little-endian Mach-O (magic {magic:#x})")

    (ncmds,) = struct.unpack_from("<I", data, 16)
    off = 32  # sizeof(mach_header_64)
    patched = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            # build_version_command: cmd, cmdsize, platform, minos, sdk, ntools
            struct.pack_into("<I", data, off + 12, pack_ver(major, minor))
            patched += 1
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            # version_min_command: cmd, cmdsize, version, sdk
            struct.pack_into("<I", data, off + 8, pack_ver(major, minor))
            patched += 1
        off += cmdsize

    if not patched:
        raise SystemExit(f"{path}: no LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS found")
    path.write_bytes(data)


def patch_plist(path: Path, major: int, minor: int) -> None:
    with path.open("rb") as fh:
        info = plistlib.load(fh)
    info["MinimumOSVersion"] = f"{major}.{minor}"
    info.pop("DTPlatformVersion", None)
    info.pop("DTSDKName", None)
    with path.open("wb") as fh:
        plistlib.dump(info, fh)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    framework = Path(sys.argv[1])
    if not framework.is_dir():
        raise SystemExit(f"{framework} is not a directory")
    try:
        major_s, minor_s = sys.argv[2].split(".", 1)
        major, minor = int(major_s), int(minor_s)
    except ValueError:
        raise SystemExit("version must look like 12.0")

    binary = framework / framework.stem  # NodeMobile.framework/NodeMobile
    if not binary.exists():
        raise SystemExit(f"{binary} not found (expected <Framework>/<Framework>)")

    patch_macho(binary, major, minor)
    patch_plist(framework / "Info.plist", major, minor)
    print(f"patched {framework} -> MinimumOSVersion {major}.{minor}")


if __name__ == "__main__":
    main()
