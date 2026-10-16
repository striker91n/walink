# Architecture

## Layers

1. **Runtime layer** — `NodeMobile.framework` (nodejs-mobile). We ship the **`nodejs-mobile-v16.17.1`**
   prebuilt: it is the only published iOS runtime that loads on iOS 12 (every v18.x build imports
   `___chkstk_darwin`, an iOS 13+ symbol — see the README). It is a dynamic framework exposing one C
   entry point:

   ```c
   int node_start(int argc, char *argv[]);
   ```

   We link it, `setenv()` our config, `chdir()` into the app container, and call `node_start` from a
   dedicated thread. It never returns while the app lives. The framework's V8 options are `--jitless`,
   so JS runs interpreter-only for now.

2. **Engine layer** — `engine/main.js`. A Baileys session (WhatsApp multi-device protocol over
   WebSocket) plus a tiny `node:http` server bound to `127.0.0.1`:

   | Method | Path | Purpose |
   |---|---|---|
   | GET  | `/api/health` | readiness probe |
   | GET  | `/api/state`  | `{ connected, user, qr }` (the QR rotates every ~20 s) |
   | GET  | `/api/events?since=N` | long-poll (≤25 s) returning events since id `N` |
   | POST | `/api/send`   | `{ jid, text }` |
   | POST | `/api/logout` | unlink (wipes the auth directory) |
   | GET  | `/api/log?tail=N` | tail of `engine.log` — Node's stdout/stderr are discarded on iOS |

   On iOS 12 there is no `NSURLSessionWebSocketTask` (iOS 13+), so events are delivered by long-poll
   rather than a socket. This is deliberate and dependency-free on the ObjC side.

   Because the Node process' stdout/stderr go nowhere on iOS, every `log()`/`logErr()` is also
   appended to `<container>/Documents/.walink/engine.log` (rotating at 512 KB).

3. **UI layer** — `ios/` (Theos, Objective-C, UIKit). Renders the QR from the raw string with
   CoreImage's `CIQRCodeGenerator`, shows connection state, and sends/receives messages.

## Why embedded Node instead of a browser/JS shim

The "community APIs" (Baileys, whatsmeow) need a real runtime. Two ways to get one on-device:

- **Embedded Node (chosen).** Real `node:crypto`, real `ws`, real `fs` — Baileys runs unmodified.
  Obtaining a runtime is a solved problem *without* compiling: nodejs-mobile publishes iOS framework
  builds and we ship the v16.17.1 one.
- **JavaScriptCore / WKWebView shim.** No external runtime, but requires re-implementing
  `node:crypto`, `node:zlib`, `node:stream`, `ws`, and `fs` on top of WebCrypto/IndexedDB, and iOS
  12's WebCrypto lacks some primitives the Signal stack wants. Fallback only.

### Node 16 compatibility notes

Baileys 6.17.16 targets Node ≥ 18 and needs two adjustments on Node 16 (both handled in
`engine/main.js`):

- **Global WebCrypto** — Baileys uses bare `crypto.subtle`. Node 16 exposes it only behind a flag, so
  `node_start` is passed `--experimental-global-webcrypto`.
- **Zero-length HKDF input** — the Noise handshake calls `hkdf(new Uint8Array(0), …)`. Node 16's
  WebCrypto rejects a zero-length key with `DataError: Zero-length key is not supported`; Node ≥ 18
  accepts it. We install an RFC 5869 `node:crypto` implementation of `hkdf` (verified bit-identical to
  `webcrypto.subtle`) whenever the Node major is < 18.

Baileys itself is CommonJS and is loaded with `createRequire`: its `exports.default = makeWASocket`
shape makes an ESM default import bind `module.exports` instead of the function.

## Device facts that drive the design

- iPhone 6 Plus: Apple A8, 1 GB RAM, **iOS 12.5.8 max**. JIT is normally forbidden on iOS and the
  shipped nodejs-mobile framework is built `--jitless`, so JS is interpreter-only today. The app
  already carries the `dynamic-codesigning` entitlement, so a JIT-enabled runtime would work on this
  jailbroken device if we can obtain one (the README explains why a from-source build is not yet a
  working path).
- Jailbreak: **Amethyst** (semi-untethered, Procursus bootstrap). It does not survive a reboot —
  re-open the Amethyst app to re-jailbreak.
- SSH over USB: `iproxy 2222 22`, then `ssh root@127.0.0.1 -p 2222`. The engine's loopback API is
  reached the same way with `iproxy 8787 8787`.

## Data on device

- Auth/Signal keys: `useMultiFileAuthState` under the app's Documents (move to SQLite later).
- Engine log: `<container>/Documents/.walink/engine.log`.
- Media cache: app container (not yet implemented).
- Nothing leaves the device except the WhatsApp protocol traffic itself.
