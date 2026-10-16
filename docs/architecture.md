# Architecture

## Layers

1. **Runtime layer** — `NodeMobile.framework` (nodejs-mobile, Node.js 18.20.4, V8 10.2,
   OpenSSL 3.0.13, ICU disabled). A dynamic framework exposing one C entry point:

   ```c
   int node_start(int argc, char *argv[]);
   ```

   We link it, `setenv()` our config, `chdir()` into the app container, and call `node_start`
   from a dedicated thread. It never returns while the app lives.

2. **Engine layer** — `engine/main.js`. A Baileys session (WhatsApp multi-device protocol over
   WebSocket) plus a tiny `node:http` server bound to `127.0.0.1`:

   | Method | Path | Purpose |
   |---|---|---|
   | GET  | `/api/health` | readiness probe |
   | GET  | `/api/state`  | `{ connected, user, qr }` |
   | GET  | `/api/events?since=N` | long-poll (≤25 s) returning events since id `N` |
   | POST | `/api/send`   | `{ jid, text }` |
   | POST | `/api/logout` | unlink |

   On iOS 12 there is no `NSURLSessionWebSocketTask` (iOS 13+), so events are delivered by
   long-poll rather than a socket. This is deliberate and dependency-free on the ObjC side.

3. **UI layer** — `ios/` (Theos, Objective-C, UIKit). Renders the QR from the raw string with
   CoreImage's `CIQRCodeGenerator`, shows connection state, and sends/receives messages.

## Why embedded Node instead of a browser/JS shim

The "community APIs" (Baileys, whatsmeow) need a real runtime. Two ways to get one on-device:

- **Embedded Node (chosen).** Real `node:crypto`, real `ws`, real `fs` — Baileys runs unmodified.
  Cost: we must build a Node framework for iOS. Solved by CI (`build-node-ios.yml`).
- **JavaScriptCore / WKWebView shim.** No external runtime, but requires re-implementing
  `node:crypto`, `node:zlib`, `node:stream`, `ws`, and `fs` on top of WebCrypto/IndexedDB, and
  iOS 12's WebCrypto lacks some primitives the Signal stack wants. Fallback only.

## Device facts that drive the design

- iPhone 6 Plus: Apple A8, 1 GB RAM, **iOS 12.5.8 max**. JIT is normally forbidden on iOS; the
  stock framework is `--jitless`. On a jailbroken device a JIT build + `dynamic-codesigning`
  entitlement is possible (see workflow `jit` input) for a large speedup on the A8.
- checkra1n is **semi-tethered**: the jailbreak does not survive reboot; re-run it over DFU.
- Ribbon cable / `iproxy 2222 44` reaches the device's SSH (checkra1n runs it on port 44).

## Data on device

- Auth/Signal keys: `useMultiFileAuthState` under the app's Documents (move to SQLite later).
- Media cache: app container (not yet implemented).
- Nothing leaves the device except the WhatsApp protocol traffic itself.
