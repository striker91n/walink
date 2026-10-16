# Walink — Project Journal

Running log of decisions, verified facts, and open items. Newest entries at the bottom.
Owner identity for all git activity: **striker91n**.

---

## 2026-10-16 — Day 1

### Goal
Build a custom, fully-functional-enough WhatsApp client for a **jailbroken iPhone 6 Plus**,
standalone (engine runs on the device, no separate host), native Theos UI, linking the user's
existing number as a **companion device**. Accepted constraint: **calls are out** (and WhatsApp
calling does not work in the user's country anyway).

### Verified facts (checked, not assumed)
- **Device cap:** iPhone 6 Plus = Apple **A8**, 1 GB RAM, max **iOS 12.5.8** (dropped at iOS 13).
  So the official WhatsApp (needs iOS 15.1+) can never run here → custom client is the only route.
- **Jailbreak:** first assumed checkra1n (checkm8); **corrected to Amethyst** — see the dedicated
  entry below. **Semi-untethered**, Procursus bootstrap, SSH on port **22**.
- **On-device runtime:** [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) publishes
  prebuilt iOS binaries; latest is **v18.20.4** (Node 18.20.4, V8 10.2, OpenSSL 3.0.13, ICU off).
- **Blocker found & solved:** the prebuilt `NodeMobile.framework` declares
  `MinimumOSVersion = 13.0`. Root cause = a single line in `tools/ios-framework/NodeMobile.xcodeproj/project.pbxproj`
  (`IPHONEOS_DEPLOYMENT_TARGET = 13.0`). The older `mobile-master` branch used `9.0`.
  → Fix: CI patches that line to **12.0** and rebuilds. (Verified: only that value drives it.)
- **Framework shape:** `NodeMobile.xcframework/ios-arm64/NodeMobile.framework` is a **dynamic**
  Mach-O dylib, install name `@rpath/NodeMobile.framework/NodeMobile`; deps only
  `libc++`, `CoreFoundation`, `libSystem`. → embed at `Walink.app/Frameworks/` + rpath
  `@executable_path/Frameworks`.
- **API surface:** the framework exposes exactly `int node_start(int argc, char *argv[]);`.
- **V8 is built `--jitless`** (App Store constraint). On a jailbroken device a JIT build +
  `dynamic-codesigning` entitlement is possible → optional speedup knob (CI input `jit`).

### Architecture decisions
- **Embedded Node (chosen)** over a JSC/WKWebView shim: real `node:crypto`/`ws`/`fs`, Baileys runs
  unmodified. Cost = build Node for iOS in CI (free on public repo macOS runners).
- **iOS 12 has no `NSURLSessionWebSocketTask`** (iOS 13+) → app↔engine uses **REST + long-poll**,
  not a socket.
- Native **ObjC/UIKit Theos app**, `.deb` install via `dpkg` (jailbroken, no signing).
- Engine (Node 18 + Baileys) exposes loopback HTTP on `127.0.0.1:8787`.
- Link as **companion device** (like WhatsApp Web): scan QR once. **Use a burner, not a main number.**
- **JIT enabled (user decision, 2026-10-16):** build the runtime WITHOUT `--v8-options=--jitless`, and
  sign the app with the `dynamic-codesigning` entitlement. Faster JS on the A8. The workflow's `jit`
  input now defaults to **true**; the jitless build stays available as a fallback (`-f jit=false`).

### Repo / tooling
- Dev box = Linux (CachyOS). Has `clang`, `ldid`, `make`, `node`/`npm`, `gh` (2.102.0),
  `iproxy`, `ideviceinfo`, `ssh`. Theos not yet installed.
- Public repo created: **https://github.com/striker91n/walink** (public so macOS CI minutes are free).
- **Git identity gotcha:** local SSH key authenticates as **`nlpolb332`**, but the gh token and the
  repo are **`striker91n`**. → Push over **HTTPS with the gh credential helper**, NOT SSH.
  (Global config rewrites fetch→gh-proxy and push→ssh; override with an explicit pushurl.)

### Workstreams
- [x] **Lead:** README, `.gitignore`, CI workflow `build-node-ios.yml`, `docs/architecture.md`,
      `docs/legal.md`, this journal, repo creation.
- [~] **Worker A:** `engine/` — Node + Baileys engine, loopback HTTP API (in progress).
- [~] **Worker B:** `ios/` — Theos UIKit app (in progress).
- [~] **Worker C:** `scripts/` — bootstrap/fetch-runtime/build/deploy (in progress).

### Open items / risks
- [ ] CI: first run of `build-node-ios.yml` may need an **Xcode pin** (Node 18.20.4 built with an
      older Xcode); fallback runner `macos-13`.
- [ ] Verify **Baileys version vs Node 18** (`engines.node`) — worker A is pinning the newest OK one.
- [x] **JIT chosen** (2026-10-16) — build without `--jitless`, sign `dynamic-codesigning`. To confirm
      on device that checkra1n + amfi patch actually permits RWX/JIT for the app. `jitless` = fallback.
- [x] fetch-runtime.sh artifact name default fixed to `NodeMobile-ios-arm64-jit` (JIT build).
- [ ] Everything is unvalidated until it runs on the device.
- [ ] Ban risk: **documented**, burner number required.
- [ ] Not yet installed: **Theos** (`scripts/bootstrap-theos.sh`).

### Next steps
1. Land engine/ios/scripts, review for consistency with the API contract.
2. Commit + push as striker91n.
3. Manually trigger `build-node-ios.yml`; fetch artifact; bootstrap Theos; build; deploy; test QR link.

### Day 1 (cont.) — CI debugging & JIT
- CI run `38930819780` (jitless) failed in 36s: `ModuleNotFoundError: No module named 'distutils'`.
  Cause: macOS runner Python **3.12** removed `distutils`; Node 18 `configure.py` imports `StrictVersion`.
  Runner Xcode = 15.4. **Fix:** added `actions/setup-python@v5` → **3.11**, and replaced
  `getconf _NPROCESSORS_ONLN` with `sysctl -n hw.ncpu` in the prepare script.
- User decision: **ship the JIT build.** Workflow `jit` input now defaults to `true`. Re-triggered as
  run `38930981133` (cancelled/replaced after the Python fix).

### Day 1 (cont.) — Jailbreak clarified: **Amethyst** (not checkra1n)
- Device is jailbroken with **Amethyst** — github.com/staturnzz/amethyst. Facts verified:
  semi-untethered, **iOS 12.0–13.7, all devices**, MIT license. Initial release 2026-06-25;
  stable **1.1** (2026-10-12). Uses the **Procursus bootstrap**; ships **Sileo + Zebra**. Explicitly
  supports **fakesigned / AppSync** apps (1.0.2 fixed entitlements + library-validation on legacy-signed
  binaries). Credits include Trigon, puaf_physpuppet, Operation Triangulation techniques.
- Consequences for this project:
  - **Rootful** (iOS 12/13) → packages install under `/`, `/Applications`; `dpkg`/`apt` present. Our
    assumptions hold.
  - **SSH = port 22** (NOT checkra1n's 44). OpenSSH may need installing from Sileo/Zebra; root pw `alpine`.
  - After reboot: re-open the **Amethyst app** (semi-untethered), not a DFU flow. Free-signing expires ~weekly.
  - Fakesigning support → our ldid-signed app and `dynamic-codesigning` (JIT) should load. Good sign for JIT.
- Applied: `scripts/deploy.sh` default device SSH port **44 → 22**; README + reminders updated.

### Day 1 (cont.) — CI root cause #2 + caching
- nodejs-mobile's `./configure` is a shell wrapper that does
  `command -v python3.12 && exec python3.12 "$0" "$@"` **before** trying 3.11 — so `setup-python`
  never won. Fix: a PATH shim dir with `python3.12 -> python3.11`, appended to `$GITHUB_PATH`.
- Perf/caching: pin nodejs-mobile to tag **v18.20.4**; **remove `make clean`** from the prepare
  script (it was discarding everything); restore/save-cache `nodejs-mobile/out` +
  `tools/ios-framework/bin` (key per-jit, unique per run + `restore-keys` prefix) → incremental
  rebuilds. Also skip `brew install cmake` when cmake is already present.
- Pushed `e81f6c6`: cache restore/save steps are `continue-on-error` so a cache hiccup can't fail an
  otherwise-good framework build.

### Day 1 (cont.) — Build is compiling; static verifications done
- CI run **38931568114** (JIT) got past the ~45 s fast-fail and is now **compiling** → the Python fix
  worked. Commits in play: `7d525f9` (workflow reset), `e81f6c6` (cache hardening).
- Verified against Theos `makefiles/package.mk`: the target order is
  `package: internal-package-check stage before-package internal-package after-package` →
  our `before-package::` hook runs **after** staging, so the embedded
  `Walink.app/Frameworks/NodeMobile.framework` copy is correctly ordered (not clobbered).
- Verified the CI seds match nodejs-mobile **v18.20.4** `tools/ios_framework_prepare.sh` exactly:
  `make clean` on lines 61/84/108; `--v8-options=--jitless` on 71/94/118; `getconf _NPROCESSORS_ONLN`
  on 74/98/121. So the JIT rebuild really drops `--jitless`.
- Reviewed the app sources (read-only): iOS-12-safe APIs only; `WLEngine` runs `node_start` on a
  detached thread, sets `WALINK_PORT`/`WALINK_DATA_DIR`, `chdir`s to Documents, resolves
  `engine/main.js` from the bundle, and drives the loopback API with `NSURLSession` + a serial queue.
  Entitlements = `platform-application` + `dynamic-codesigning` (JIT). `Walink.entitlements`,
  `Walink-Info.plist` (MinimumOSVersion 12.0), and `ios/control` all look correct.
- Still unproven until the artifact exists: on-device JIT/RWX under Amethyst; Baileys link as a
  companion device.
- Open risks: (a) dev-box `theos` bootstrap needs `ldid` from a source that Docker/apt may not
  provide; (b) building `theos` natively needs an iOS 12 SDK (script picks 12.x from theos/sdks);
  (c) build cache may approach GitHub's per-repo cache size limit — narrow if needed.

### Day 1 (cont.) — Code review + fixes; device reachable over USB and Wi-Fi
- Read-only scout review of engine/ios/scripts against the API contract. Must-fix items applied:
  - **[crash, app-breaking]** `WLHomeViewController` treated the `connection` event's `code` as an
    `NSString` and called `-length`, but the engine emits an `NSNumber` (Baileys `DisconnectReason`)
    → `unrecognized selector` the first time a disconnect arrives. Now coerced via `isKindOfClass:`.
  - **[bug]** `scripts/build.sh` searched `packages/` at the repo root, but Theos writes packages to
    `ios/packages/` → the script always reported "no .deb" after a good build. Fixed.
  - `WLEngine`'s `/api/events` now reports transport/HTTP errors via an `NSError` (was a silent `@[]`),
    and the poll loop **backs off 3 s** on error instead of hammering a dead engine.
  - `engine/main.js`: `EADDRINUSE` → `process.exit(1)` (was a silent zombie with no HTTP server, so
    the UI waited 3 min then gave up); oversized bodies now return **413** (were 500) and destroy the
    socket; `fetchLatestBaileysVersion()` is cached (it did a network request on every reconnect).
  - CI: dropped the `push: tags` trigger — it built **jitless** and uploaded as `NodeMobile-ios-arm64`
    while `fetch-runtime.sh` expects `…-jit`; the "run it first" hint now passes `-f jit=true`.
- **Device connectivity:** `idevice_id` had failed **not** because of the cable but because
  **`usbmuxd.service` is masked and was not running** (the iPhone showed on the USB bus the whole
  time). Started it ad hoc with `sudo usbmuxd -f &`. Device = **iPhone7,1 / iOS 12.5.8**.
- **Wi-Fi IP found by scanning:** mapped the phone's USB-reported Wi-Fi MAC against the LAN neighbor
  table (`ip neigh`) after a ping sweep, then confirmed with a direct `ssh` on port 22 (OpenSSH
  listens on the network interface, not just USB). Host-specific details (UDID, serial, IP,
  password) are kept **only** in the gitignored `scripts/device.env` — never in this public repo.
- CI run `38931568114` still compiling at ~8 min.
