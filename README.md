# Walink

An **unofficial WhatsApp client for jailbroken iOS 12**, built for the iPhone 6 Plus.
It is fully standalone: a real Node.js runtime (embedded via [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile))
runs [Baileys](https://github.com/WhiskeySockets/Baileys) **on the device**, and a native
UIKit app drives it over a loopback socket.

```
┌──────────────────────────── iPhone 6 Plus (iOS 12.5.8, Amethyst) ─────────────────────────────┐
│                                                                                               │
│   ┌───────────────────────┐        loopback HTTP        ┌──────────────────────────────────┐  │
│   │  Native UIKit app     │  http://127.0.0.1:8787  ──▶  │  Embedded Node 18 (NodeMobile)   │  │
│   │  Walink.app (Theos)   │  REST + long-poll       ◀──  │  engine/main.js  (Baileys)        │  │
│   │  chat list, bubbles,  │                              │  holds Signal keys, media, state  │  │
│   │  QR, notifications    │                              └──────────────────────────────────┘  │
│   └───────────────────────┘                                             │                       │
│                          Walink.app/Frameworks/NodeMobile.framework     │ Noise / Signal        │
└─────────────────────────────────────────────────────────────────────────┼───────────────────────┘
                                                                          ▼
                                                                  WhatsApp servers
```

> **No separate host, no cloud, no Mac at build time.** The one macOS-only step (compiling
> Node for iOS) runs on GitHub Actions' free macOS runners and is published as a build artifact.

---

## ⚠️ Read this first

- **This violates the WhatsApp Terms of Service.** Linking an unofficial client can get the
  account **banned**, sometimes quickly. **Do not use your main number.** Use a burner.
- This project deliberately does **not** support bulk messaging, spam, scraping, or stalkerware.
- **Calls are not supported** by any community library — and in this project that was accepted
  because WhatsApp calling does not work in the target country anyway.
- Everything else is supported: text, images, video, voice notes, documents, groups, reactions,
  replies, polls, stories/status, read receipts, typing/online presence, privacy, block, edit, delete.

## Why a custom client at all?

Apple capped the iPhone 6 / 6 Plus at **iOS 12.5.8** (A8 chip, dropped at iOS 13). Modern WhatsApp
requires iOS 15.1+. So the official app can never run here again — an unofficial client is the only
route, not a novelty.

## Hard constraints (verified)

| Constraint | Value | Consequence |
|---|---|---|
| Device OS | iOS 12.5.8 (max) | Everything must target iOS 12; no SwiftUI, no `NSURLSessionWebSocketTask` |
| Jailbreak | **Amethyst** (iOS 12.0–13.7, all devices) | Semi-untethered + Procursus bootstrap (Sileo/Zebra); re-run the Amethyst app after reboot |
| nodejs-mobile prebuilt | `MinimumOSVersion = 13.0` | **Unusable as shipped** → we rebuild with target 12.0 in CI |
| V8 in nodejs-mobile | built with `--v8-options=--jitless` | Slower JS; optional JIT build + `dynamic-codesigning` for speed |
| iOS 12 networking | no `NSURLSessionWebSocketTask` (iOS 13+) | app↔engine uses **REST + long-poll**, not WebSocket |

## Repo layout

```
.github/workflows/build-node-ios.yml   macOS CI: build NodeMobile.framework for iOS 12
engine/                                the on-device Node app (Baileys + loopback API)
ios/                                   the Theos app (native UIKit)
scripts/                               bootstrap / fetch-runtime / build / deploy
docs/                                  architecture + legal notes
vendor/                                NodeMobile.framework lands here (git-ignored, from CI)
```

## Build & run

### 0. Prerequisites

- This repo built on **Linux** (CachyOS/Arch-family; Debian/Ubuntu works too).
- `clang`, `ldid`, `make`, `git`, `node`/`npm`
- `libimobiledevice` + `usbmuxd` (`iproxy`, `ideviceinfo`) to talk to the phone over USB
- A jailbroken iPhone 6 Plus (**Amethyst**, Procursus bootstrap). Install **OpenSSH** from Sileo/Zebra;
  SSH listens on port **22** (default root password `alpine` — change it).
  See **[docs/device-setup.md](docs/device-setup.md)** for the full device checklist.

### 1. Get the iOS 12 Node runtime into `vendor/` (seconds, no compile)

```sh
./scripts/fetch-runtime.sh
```

Downloads the official prebuilt `NodeMobile.xcframework` and lowers its declared minimum iOS
version to **12.0** with `scripts/patch-framework.py` (both `Info.plist` and the Mach-O
`LC_BUILD_VERSION`). The published framework declares `13.0` as a *build setting* only — the dylib
links nothing newer than `libc++`/`CoreFoundation`/`libSystem` — so patching it beats recompiling
V8. **~3 s instead of ~30 min.**

The prebuilt is the official `--jitless` build. For **JIT** (faster JS on the A8) you must compile
once, but the workflow caches the build so repeat runs are incremental:

```sh
gh workflow run build-node-ios.yml -f jit=true   # free macOS minutes on a public repo
SOURCE=ci ./scripts/fetch-runtime.sh             # downloads artifact NodeMobile-ios-arm64-jit
```

Speed notes: nodejs-mobile is pinned to `v18.20.4`, `make clean` is removed, and
`nodejs-mobile/out` + `tools/ios-framework/bin` are cached — so the second JIT build reuses
everything.

### 2. Install Theos (Linux)

```sh
./scripts/bootstrap-theos.sh
```

### 3. Build the .deb

```sh
./scripts/build.sh                # -> ios/packages/com.striker91n.walink_*.deb
```

### 4. Install on the device over USB

```sh
./scripts/deploy.sh               # iproxy 2222:22, scp, dpkg -i, ldid, uicache
```

Open **Walink**, scan the QR with WhatsApp on your existing phone (Linked devices → Link a
device). The bridge is now a companion device; the iPhone talks to it locally.

## Roadmap

- [x] CI builds an **iOS 12** Node.js 18 arm64 framework (the whole reason for this repo)
- [x] Prebuilt runtime **patched to iOS 12** locally (no compile needed; ~3 s)
- [x] Theos app boots embedded Node and reaches it over loopback
- [x] QR link flow + send text
- [ ] Chat list, message history, bubbles (native store)
- [ ] Media (image/video/voice/document) send + download + viewer
- [ ] Background socket + local notifications
- [ ] Groups, reactions, replies, polls, presence, privacy toggles
- [ ] On-device DB (SQLite) instead of `useMultiFileAuthState`
- [ ] Optional JIT build for the A8

## Legal

Unofficial, unaffiliated with WhatsApp/Meta. For personal/technical use on hardware you own.
See `docs/legal.md`. No license is granted for use against WhatsApp's terms.
