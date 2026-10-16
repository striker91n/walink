# Walink

An **unofficial WhatsApp client for jailbroken iOS 12**, built for the iPhone 6 Plus.
It is fully standalone: a real Node.js runtime (embedded via [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile))
runs [Baileys](https://github.com/WhiskeySockets/Baileys) **on the device**, and a native
UIKit app drives it over a loopback socket.

```
┌──────────────────────────── iPhone 6 Plus (iOS 12.5.8, Amethyst) ─────────────────────────────┐
│                                                                                               │
│   ┌───────────────────────┐        loopback HTTP        ┌──────────────────────────────────┐  │
│   │  Native UIKit app     │  http://127.0.0.1:8787  ──▶  │  Embedded Node 16 (NodeMobile)   │  │
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
| nodejs-mobile prebuilts | every **v18.x** imports `___chkstk_darwin` (an iOS 13+ symbol) | **Cannot load on iOS 12**; lowering the declared minimum does *not* help → we ship the **v16.17.1** prebuilt (min iOS 11.0, no such import) |
| V8 in nodejs-mobile | v16.17.1 bakes in `--jitless` | Interpreter-only for now; the framework's `node_v8_options` may let us drop it (investigating) |
| GitHub macOS CI | its iOS-12 patch edits the Xcode project, but gyp/ninja compiles the objects | cannot produce an iOS-12 framework as written, and the JIT step dies on the free runner |
| iOS 12 networking | no `NSURLSessionWebSocketTask` (iOS 13+) | app↔engine uses **REST + long-poll**, not WebSocket |

## Repo layout

```
.github/workflows/build-node-ios.yml   macOS CI: from-source NodeMobile.framework (not viable yet — see below)
engine/                                the on-device Node app (Baileys + loopback API)
ios/                                   the Theos app (native UIKit)
scripts/                               bootstrap / fetch-runtime / build / deploy / launch / show-qr / engine-log
docs/                                  architecture + legal notes
vendor/                                NodeMobile.framework lands here (git-ignored; filled by fetch-runtime.sh)
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
NODEJS_MOBILE_TAG=nodejs-mobile-v16.17.1 ./scripts/fetch-runtime.sh
```

This pulls the **`nodejs-mobile-v16.17.1` prebuilt** — the only published iOS runtime that loads on
iOS 12. It is also the default in `scripts/fetch-runtime.sh`.

**Why not a Node 18 prebuilt with a patched minimum version?** Because that does not work, and we
proved it on the device. Every published **v18.x** framework imports `___chkstk_darwin`, a stack-probe
helper that first exists in **iOS 13**'s libSystem, bound non-lazily into `__got`. Lowering the
declared minimum (`LC_BUILD_VERSION` / `MinimumOSVersion`) with `scripts/patch-framework.py` — which
`fetch-runtime.sh` still does — leaves the import itself untouched, so dyld aborts at launch with
`Symbol not found: ___chkstk_darwin`. `fetch-runtime.sh` therefore now **refuses to install any
runtime that imports `___chkstk_darwin`**, instead of quietly shipping one that dies in dyld.

**JIT:** the v16.17.1 framework bakes `--jitless` into its V8 options, so JS runs interpreter-only for
now (noticeable on an A8). We are checking whether the framework's own `node_v8_options` can be
overridden to enable JIT without compiling anything.

**From-source CI is not a working path yet.** `.github/workflows/build-node-ios.yml` has been
dispatched repeatedly; the `Build framework (JIT)` step dies after ~50 min — the free macOS runner has
~7 GB and this is an LTO V8 build — and uploads no artifact. Worse, its "patch to iOS 12.0" step edits
`IPHONEOS_DEPLOYMENT_TARGET` in the **Xcode project**, but the objects are compiled by **gyp/ninja**,
which reads its own config: every compile line still says `-miphoneos-version-min=13.0`. So even a
successful run could not produce an iOS-12 framework. Fixing it means patching `common.gypi` (or
equivalent), dropping LTO, and gating the artifact on `llvm-nm -u | grep chkstk`.

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

The post-install hook kills the running app so the new binary is picked up, so launch it explicitly:

```sh
./scripts/launch.sh               # uiopen --bundleid, then verifies it came up
./scripts/show-qr.sh              # terminal QR, re-rendered as WhatsApp rotates it
./scripts/engine-log.sh 50        # the engine's own log
```

Scan the QR with WhatsApp on the phone that holds your number (Linked devices → Link a device).
The iPhone then talks to WhatsApp itself, locally.

## On-device gotchas (learned the hard way)

- **`uiopen` needs a bundle id.** `uiopen --path /Applications/Walink.app` fails with
  `No application at path`, and a bare path silently does nothing — only
  `uiopen --bundleid com.striker91n.walink` works, which is what `scripts/launch.sh` uses.
- **A locked/asleep device makes every launch fail silently**, including system apps. Wake the phone
  before deploying.
- **The engine's stdout/stderr go nowhere on iOS.** `engine/main.js` mirrors every log line to
  `<container>/Documents/.walink/engine.log` (rotating at 512 KB) and serves it as
  `GET /api/log?tail=N`, which is what `scripts/engine-log.sh` reads over the USB tunnel.
- The loopback API (reachable from the host via `iproxy 8787 8787`): `GET /api/health`,
  `GET /api/state` (includes the live `qr`), `GET /api/events?since=N` (25 s long-poll),
  `POST /api/send {jid,text}`, `POST /api/logout`, `GET /api/log?tail=N`.
- The device has **no `ldid`, `curl`, `python3` or `nc`**; `uiopen`, `uicache`, `plutil`, `killall`
  and `dpkg` do exist, so deploy's device-side `ldid -S` fails harmlessly.

## Roadmap

- [x] iOS 12 Node runtime working on the device — the `nodejs-mobile-v16.17.1` prebuilt (no compile needed)
- [x] Theos app boots embedded Node and reaches it over the loopback HTTP API
- [x] Engine reaches WhatsApp and emits a live companion-linking QR on the device
- [ ] Complete the QR link and verify send/receive text end to end
- [ ] Chat list, message history, bubbles (native store)
- [ ] Media (image/video/voice/document) send + download + viewer
- [ ] Background socket + local notifications
- [ ] Groups, reactions, replies, polls, presence, privacy toggles
- [ ] On-device DB (SQLite) instead of `useMultiFileAuthState`
- [ ] JIT for the A8 (via the framework's `node_v8_options`, or a from-source build once CI is fixed)
- [~] GitHub macOS CI for a from-source arm64 framework — the workflow exists, but the build dies on
      the free runner and its iOS-12 patch misses gyp/ninja (see "Get the iOS 12 Node runtime" above)

## Legal

Unofficial, unaffiliated with WhatsApp/Meta. For personal/technical use on hardware you own.
See `docs/legal.md`. No license is granted for use against WhatsApp's terms.
