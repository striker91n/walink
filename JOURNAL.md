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

### Day 1 (cont.) — Build speed: patch the prebuilt instead of compiling
- **Biggest win.** The official prebuilt `nodejs-mobile-v18.20.4-ios.zip` device slice declares
  `MinimumOSVersion 13.0` and `LC_BUILD_VERSION minos 13.0`, but it links only
  `libc++`/`CoreFoundation`/`libSystem` — the 13.0 is a *declaration*, not an API requirement.
  Added **`scripts/patch-framework.py`** (pure Python; rewrites the Mach-O `LC_BUILD_VERSION.minos`
  and `Info.plist` `MinimumOSVersion`). `scripts/fetch-runtime.sh` now defaults to
  download → patch → `ldid -S` re-sign: **~3 s instead of a ~30-min V8 compile**. The CI/JIT path
  is still there via `SOURCE=ci`.
- CI-side speedups: nodejs-mobile pinned to `v18.20.4` (cache stays valid), `make clean` removed,
  `nodejs-mobile/out` + `tools/ios-framework/bin` cached, `brew install cmake` skipped when present.
- **Toolchain ready:** Theos at `/home/axies/theos` with `iPhoneOS12.4.sdk`; clang/lld 23.1.1;
  `ldid` 2.1.5-procursus7. Note: `ldid` is **not in the Arch repos** (AUR only) — fixed
  `bootstrap-theos.sh` to keep it out of the pacman list and try `paru`/`yay` instead.
- **Engine deps:** `npm install` only succeeds with **`allow-git=all`** (npm 12 blocks git deps by
  default); added `engine/.npmrc`. 231 packages / 117 MB.
- **Security note (needs a decision):** npm flags `@whiskeysockets/baileys@6.17.16` as affected by a
  message-spoofing advisory (GHSA-qvv5-jq5g-4cgg) whose fixes are **6.7.22+ / 7.0.0-rc12+**. But
  every fixed version declares `engines.node >= 20.0.0`, and nodejs-mobile's newest *release* is
  Node 18.20.4. nodejs-mobile does have an unreleased **`update22-9-0`** branch (Node 22.9.0) that we
  could build in CI. Options: (a) keep Node 18 + vulnerable Baileys (fast, burner number),
  (b) build Node 22 from that branch + fixed Baileys (slow/experimental).

### Day 1 (cont.) — First build attempt: Theos had no iOS toolchain
- `scripts/build.sh` got all the way to `make package` and failed with
  `/home/axies/theos/toolchain/linux/iphone/bin/clang: No such file or directory`.
  Cause: the manual bootstrap cloned `theos` + the iOS SDK but never installed the cross-toolchain.
- Fix: Theos's own installer downloads a prebuilt Linux toolchain —
  `https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-$ARCH.tar.xz`
  (ARCH=x86_64 here) — extracted into `$THEOS/toolchain/`. Installing that, then rebuilding.
  (`install-theos` also offers a Swift-capable variant from `kabiroberai/swift-toolchain-linux`; we
  only need ObjC, so the smaller non-Swift toolchain is right.)

### Day 1 (cont.) — Subagent models: online research + empirical test
Free models on OpenCode Zen (authoritative list: https://opencode.ai/docs/zen/):
GLM-5.3-Flash Free, DeepSeek V4.1 Flash Free, MiMo-V2.6-Flash Free, MiMo-V2.5 Free,
LongCat 2.5 Preview Free, Nemotron 3 Ultra / 3.5 Lightning / 3.5 Super VL Free,
Space Bunny Free (stealth), Beam Free, LL Alpha Free (stealth), Big Pickle (stealth), Exo Free,
Muse Spark 1.3 Contributor Free, Jev 1.13 Free.
- **Data policy differs** (matters for a public repo / real device work):
  GLM-5.3-Flash, DeepSeek V4.1 Flash, LongCat 2.5, Space Bunny, Beam = zero-retention, no training.
  MiMo, Big Pickle, LL Alpha, Exo, Muse Spark *may* train on your data.
  Nemotron free endpoints are "trial use only — do not submit personal or confidential data".
- **Big Pickle is broken** — upstream issue `anomalyco/opencode#50202` (looping / stalls / language
  drift). My own test also returned a wrong answer (`1.0.0` vs the file's actual `0.1.0`). Avoid.
- Empirically tested real tool-calling (grep one line out of `engine/package.json`) — all returned the
  correct line: **GLM-5.3-Flash Free**, **DeepSeek V4.1 Flash Free**, **LongCat 2.5 Preview Free**,
  **MiMo-V2.6-Flash Free**.
- **Chosen default model for subagents: `opencode/glm-5.3-flash-free`** (strong coding family,
  zero-retention, free). Fallbacks: `opencode/deepseek-v4.1-flash-free`,
  `opencode/longcat-2.5-preview-free`.

### Day 1 (cont.) — First successful build, and the path bugs it exposed
- `./scripts/build.sh` now **succeeds**, producing
  `ios/packages/com.striker91n.walink_0.1.0-1+debug_iphoneos-arm.deb` (38 MB). Verified contents:
  `Applications/Walink.app/Walink` (arm64 binary), `Frameworks/NodeMobile.framework/NodeMobile`
  (55 MB uncompressed), the whole `engine/` including `node_modules` (7620 files), and both launch
  images. Compilation of all four `Sources/*.m` passed on the first toolchain-backed run.
- Bugs found and fixed while getting there:
  * **`ios/Makefile`** pointed the linker at `ios/vendor`, but the framework is at repo-root
    `vendor/` (the target dir for `fetch-runtime.sh`) → `-I`/`-F` and the `before-package` copy now
    use `$(THEOS_PROJECT_DIR)/../vendor`. (Symptom was `ld: framework not found NodeMobile`.)
  * **`scripts/deploy.sh`** searched `packages/` for the `.deb`, but `build.sh` writes
    `ios/packages/` → now searches both, and the `find` is `|| true` (it previously returned
    non-zero for the missing dir, and `set -e` + `pipefail` aborted the whole script silently).
  * **`scp` was passed `-p <port>`**; `scp` wants capital `-P` (`-p` means "preserve timestamps"),
    so it tried to copy a file literally named `22` → split `SCP_OPTS` from `SSH_OPTS`.
- `scripts/bootstrap-theos.sh` gained step **3b** (download the prebuilt iOS cross-toolchain into
  `$THEOS/toolchain/`), so a fresh machine no longer half-bootstraps and then fails at link time.
- Device reachable at **192.168.1.71:22** over Wi-Fi (iPhone7,1 / iOS 12.5.8); deploying with
  `DEVICE_SSH_HOST=192.168.1.71 DEVICE_SSH_PORT=22 ./scripts/deploy.sh`.

### Day 1 (cont.) — App crash on launch: `___chkstk_darwin`, and the runtime decision
- First device launch of the packaged app aborted in dyld:
  `Symbol not found: ___chkstk_darwin | Referenced from: .../Walink.app/Frameworks/NodeMobile.framework/NodeMobile | Expected in: /usr/lib/libSystem.B.dylib`
  (`EXC_CORPSE_NOTIFY` / SIGABRT). Patching only the **declared** minimum iOS (13.0 → 12.0) in
  `scripts/patch-framework.py` is therefore NOT sufficient: the code itself carries a reference the
  iOS 12 runtime cannot satisfy.
- `___chkstk_darwin` is Apple's stack-probe helper (appeared with the iOS 13 SDK). It is bound
  **non-lazily**: `__DATA_CONST __got 0x021F4BB8 pointer 0 libSystem ___chkstk_darwin`.
- Tried to reproduce locally: clang 23.1.1 (host) and clang 11.1.0 (Theos toolchain), targeting
  `arm64-apple-ios12.0/13.0/16.0`, with `-fstack-clash-protection` and 40 KB–200 KB frames, at
  -O0/-O1/-O2, emit **no** `___chkstk_darwin` — the trigger in the real build is something else
  (V8/nodejs-mobile build flags), so "rebuild with min 12.0" is not proven either.
- Prebuilt audit (`/tmp/opencode/prebuilt-report.txt`): **every v18.x** iOS framework references
  `___chkstk_darwin` and declares min iOS 13. **v16.17.1** (release tag `nodejs-mobile-v16.17.1`)
  declares min iOS **11.0** and has **zero** chkstk references. v16.17.0 / v16.11.0 / v18.6.0 /
  v18.9.1 / v18.10.0 are not published as iOS assets.
- v16 fallback risk: several *runtime* deps declare `engines >= 18/20` (`@cacheable/node-cache` ≥18,
  `hashery` ≥20, `qified` ≥20, `keyv/bigmap` ≥18). Being measured before we switch.
- In parallel: a background REA task is extracting the exact `___chkstk_darwin` ABI (size register,
  whether helper or caller adjusts SP) from the v18 binary, so we can alternatively keep Node 18 and
  satisfy the symbol by repointing its non-lazy bind at the main executable.

### Day 1 (cont.) — Bug-audit fixes (engine + UI)
A read-only audit subagent (`glm-5.3-flash-free`) reviewed `engine/` and `ios/Sources/`. Three real defects:
- **Crash:** `WLHomeViewController.m` assigned `event[@"user"]` straight to `self.currentUser`; the
  engine sends JSON `null` while `connecting`/`close`, so `NSJSONSerialization` produces `NSNull` and
  `updateStatusLabel` died on `NSNull[@"name"]` seconds after launch. Now `state` is coerced to
  `NSString` and `user` to `NSDictionary`, else `nil`.
- **Hang:** `WLEngine -waitForReady` looped up to 120× (~4 min) on the *serial* `requestQueue`,
  blocking every queued request, and only `NSLog`ged failure. Now bounded to 15 attempts (~30 s) and
  calls `startupFailureHandler` (new public block property) so the UI shows
  "Engine failed to start — check the log" instead of sitting at "Starting engine…".
- **Shutdown:** `engine/main.js` `SIGTERM` relied on `server.close(cb)`, whose callback never runs
  while 25 s long-poll sockets are open → now also arms
  `setTimeout(() => process.exit(0), 1000).unref()`.
- Cleared by the audit (no action): no iOS 13+ APIs, no retain cycles, no ATS problem for loopback
  HTTP on iOS 12, timeout chain consistent (25 s poll < 30 s client < 300 s resource).

### Day 1 (cont.) — Root cause of `___chkstk_darwin` pinned down
- Upstream **LLVM 11** (our Theos toolchain) has no Darwin stack probe at all: its
  `AArch64FrameLowering.cpp` only probes for **Windows** (`__chkstk`, `windowsRequiresStackProbe`).
  That is why clang 11 cannot reproduce the symbol.
- Current LLVM `main` lowers a **dynamic `alloca`** through
  `AArch64TargetLowering::LowerDYNAMIC_STACKALLOC` → `hasInlineStackProbe(MF)` → an *inline* probe
  loop (`LowerInlineDYNAMIC_STACKALLOC` / `PROBED_STACKALLOC`); the libcall path
  (`RTLIB::STACK_PROBE` → `getLibcallImplName`) still exists and resolves to **`___chkstk_darwin`**
  on Darwin. So the import comes from V8 functions with a runtime-sized stack allocation.
- **clang 23 rejects the flag outright on Darwin**: `-fstack-clash-protection` →
  `warning: argument unused during compilation`. So on Darwin the probe choice is Apple's clang
  behaviour, gated on the deployment target: include iOS 13 → call `___chkstk_darwin`; target
  iOS 12 → inline probe. That is exactly why a prebuilt declared as min 13.0 imports it and why
  lowering only the *declared* minimum (patch-framework.py) cannot fix it — the import is baked
  into the code. It also means a **true min-12.0 rebuild should be clean**, which is what the CI's
  patched build does (its `jitless` step finished successfully on run 38931568114).
- `scripts/fetch-runtime.sh` now **refuses to install a runtime that imports `___chkstk_darwin`**
  (loud, actionable error) instead of silently shipping a framework that aborts in dyld. It also
  takes `NODEJS_MOBILE_TAG`/`NODEJS_MOBILE_ASSET` (the 16.x tags are prefixed:
  `nodejs-mobile-v16.17.1`) and locates the arm64 device slice by `find` instead of a fixed path.

### Day 1 (cont.) — Runtime switched to Node 16.17.1; the app now launches on the device
Decision (user): stop waiting on CI, use the only prebuilt that loads on iOS 12.
- `NODEJS_MOBILE_TAG=nodejs-mobile-v16.17.1 ./scripts/fetch-runtime.sh` → `vendor/NodeMobile.framework`
  (51 MB, MinimumOSVersion 12.0, **zero** `___chkstk_darwin` imports, `_node_start`/napi symbols present).
- Rebuilt (`0.1.0-3`) and deployed over USB: `dpkg` installs cleanly and `uiopen` **starts the app
  with no dyld abort** — the crash that started this investigation is fixed. `ps` shows it alive and
  the loopback API answers: `GET /api/health` → `{"ok":true}`,
  `GET /api/state` → `{"connected":false,"user":null,"qr":null}`.
- Caveat: the 16.17.1 framework bakes `--jitless` into its V8 options, so this runtime is
  interpreter-only. The CI JIT artifact built at min iOS 12.0 stays the upgrade path (drop-in via
  `SOURCE=ci`) if it proves chkstk-free.
- Node 16 compat audit of `engine/node_modules` (background subagent) found one blocker and one
  latent landmine:
  * **Blocker:** Baileys 6.17.16 calls bare WebCrypto (`crypto.subtle`) in `lib/Utils/crypto.js`
    (`hkdf`, `derivePairingCodeKey`), reached from 9 sites including `noise-handler.js` (hit on
    every connect). Node 16 has no `crypto` global (only from Node 19, or behind a flag).
    Fix taken: `node_start` argv now passes `--experimental-global-webcrypto` (exists since Node
    16.15). Fallback if that regresses: patch `lib/Utils/crypto.js` to use `node:crypto`'s
    `webcrypto`.
  * **Landmine (not reachable):** `@cacheable/memory` uses `structuredClone`, but Baileys builds all
    its NodeCaches with `useClones:false`. `hashery`'s async WebCrypto `hash()` and `qified@0.10.1`
    (engines >=20) use nothing Node-20-only.
- Observability gap fixed: on iOS the Node process' stdout/stderr are discarded, so the engine's
  `console.log` output was invisible. `engine/main.js` now mirrors every `log()`/`logErr()` (plus a
  new `uncaughtException` hook) into `<Documents>/.walink/engine.log`, rotating once at 512 KB, and
  serves it as `GET /api/log?tail=N`. New helper `scripts/engine-log.sh [lines]` reads it over the
  USB tunnel.
