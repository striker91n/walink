import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { createHmac } from 'node:crypto';
import { appendFileSync, readFileSync, renameSync, statSync } from 'node:fs';
import { mkdir, rm } from 'node:fs/promises';

// @whiskeysockets/baileys ships CommonJS only: lib/index.js sets `__esModule` and
// `exports.default = makeWASocket`. Under ESM, `import makeWASocket from '<cjs>'` binds the
// whole `module.exports` object rather than the function (which is why calling it throws
// "makeWASocket is not a function"), and leaning on cjs-module-lexer to surface the
// re-exported names (`useMultiFileAuthState`, `getContentType`, ...) is brittle across Node
// versions. `createRequire` hands back the real CJS exports object — exactly how Baileys is
// meant to be consumed.
const require = createRequire(import.meta.url);
const Baileys = require('@whiskeysockets/baileys');

const makeWASocket = Baileys.makeWASocket ?? Baileys.default;
const {
  DisconnectReason,
  fetchLatestBaileysVersion,
  getContentType,
  useMultiFileAuthState,
} = Baileys;

// --- Node < 18 WebCrypto compatibility shim ---------------------------------------------
// Baileys derives its Noise handshake keys with WebCrypto HKDF, and one call deliberately
// passes an EMPTY input key material: noise-handler.js does `localHKDF(new Uint8Array(0))`.
// Node >= 18 allows a zero-length key; Node 16's WebCrypto rejects it with
//   DataError: Zero-length key is not supported   (node:internal/crypto/webcrypto)
// which killed every connection attempt on this device.
//
// So replace Baileys' hkdf with a node:crypto HMAC implementation of RFC 5869 (SHA-256).
// HMAC zero-pads its key to the block size, so an empty salt and a zero-filled hash-length
// salt are identical here — matching WebCrypto exactly. Verified bit-identical against
// webcrypto.subtle for empty/partial/full IKM, salt and info combinations.
//
// Baileys' internal callers do `crypto_1.hkdf(...)` (a property read at call time), so
// patching the module object's export reaches all of them: noise-handler, chat-utils,
// lt-hash, messages-media, messages-recv and socket. Only installed on old Node, so the
// behaviour on Node >= 18 stays exactly Baileys' own.
const HASH_LEN = 32; // SHA-256

function hkdfExpandCompat(prk, infoBuf, length) {
  const blocks = Math.ceil(length / HASH_LEN);
  let previous = Buffer.alloc(0);
  const okm = Buffer.alloc(blocks * HASH_LEN);
  for (let i = 1; i <= blocks; i++) {
    previous = createHmac('sha256', prk)
      .update(previous)
      .update(infoBuf)
      .update(Buffer.from([i]))
      .digest();
    previous.copy(okm, (i - 1) * HASH_LEN);
  }
  return okm.subarray(0, length);
}

// same signature/shape as baileys' hkdf(buffer, expandedLength, { salt, info })
function hkdfCompat(inputKeyMaterial, expandedLength, info = {}) {
  const prk = createHmac('sha256', Buffer.from(info.salt ?? []))
    .update(Buffer.from(inputKeyMaterial ?? []))
    .digest();
  const infoBuf =
    typeof info.info === 'string'
      ? Buffer.from(info.info, 'utf8')
      : Buffer.from(info.info ?? []);
  return hkdfExpandCompat(prk, infoBuf, expandedLength);
}

// (installation happens below, once the file logger exists — see "install the shim")

const PORT = parseInt(process.env.WALINK_PORT, 10) || 8787;
const DATA_DIR = process.env.WALINK_DATA_DIR || path.join(os.homedir(), '.walink');
const AUTH_DIR = path.join(DATA_DIR, 'auth');
const LONG_POLL_MS = 25_000;
const EVENT_BUFFER_SIZE = 500;

await mkdir(DATA_DIR, { recursive: true });

const state = {
  connected: false,
  connecting: false,
  user: null,
  qr: null,
  events: [],
  nextId: 1,
  pending: [],
  authState: null,
  saveCreds: null,
  sock: null,
  reconnectTimer: null,
  reconnectAttempts: 0,
  baileysVersion: null,
};

const LOG_FILE = path.join(DATA_DIR, 'engine.log');
const LOG_MAX_BYTES = 512 * 1024;
let logBytes = 0;
try {
  logBytes = statSync(LOG_FILE).size;
} catch {
  logBytes = 0;
}

function fmtArg(value) {
  if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`;
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

// Mirror every engine log into DATA_DIR/engine.log. On iOS the Node process' stdout/stderr
// go nowhere, so this file is the only record of what the engine did — read it over SSH
// (or add a tail view in the app). Rotates once at LOG_MAX_BYTES and never throws.
function persistLog(level, args) {
  try {
    const line = `${new Date().toISOString()} ${level} ${args.map(fmtArg).join(' ')}\n`;
    if (logBytes + line.length > LOG_MAX_BYTES) {
      renameSync(LOG_FILE, `${LOG_FILE}.1`);
      logBytes = 0;
    }
    appendFileSync(LOG_FILE, line);
    logBytes += line.length;
  } catch {
    // Logging must never take the engine down.
  }
}

function log(...args) {
  console.log('[walink]', ...args);
  persistLog('INFO', args);
}

function logErr(...args) {
  console.error('[walink]', ...args);
  persistLog('ERROR', args);
}

// Last `limit` lines of engine.log, for GET /api/log.
function readLogTail(limit) {
  try {
    const lines = readFileSync(LOG_FILE, 'utf8').split('\n');
    if (lines.length > 0 && lines[lines.length - 1] === '') {
      lines.pop();
    }
    return lines.slice(-limit);
  } catch {
    return [];
  }
}

// Install the shim defined above. Placed here (rather than at the top of the module) so the
// outcome lands in engine.log; the patch only has to exist before connect() runs, which is
// much later.
const nodeMajor = Number.parseInt(process.versions.node.split('.')[0], 10);
if (Number.isFinite(nodeMajor) && nodeMajor < 18) {
  try {
    const baileysCrypto = require('@whiskeysockets/baileys/lib/Utils/crypto.js');
    baileysCrypto.hkdf = hkdfCompat;
    log(`installed Node<18 WebCrypto HKDF shim (node ${process.versions.node})`);
  } catch (err) {
    logErr('failed to install the HKDF shim:', err);
  }
}

function addEvent(payload) {
  const event = {
    id: state.nextId++,
    t: Date.now(),
    ...payload,
  };
  state.events.push(event);
  if (state.events.length > EVENT_BUFFER_SIZE) {
    state.events.shift();
  }
  flushPending();
  return event;
}

function flushPending() {
  const stillPending = [];
  for (const p of state.pending) {
    const available = state.events.filter((e) => e.id > p.since);
    if (available.length > 0) {
      clearTimeout(p.timer);
      respondJson(p.res, 200, available);
    } else {
      stillPending.push(p);
    }
  }
  state.pending = stillPending;
}

function pushPending(res, since) {
  const entry = { res, since, timer: null };
  entry.timer = setTimeout(() => {
    removePending(entry);
    respondJson(res, 200, []);
  }, LONG_POLL_MS);
  state.pending.push(entry);
  res.on('close', () => removePending(entry));
}

function removePending(entry) {
  clearTimeout(entry.timer);
  state.pending = state.pending.filter((p) => p !== entry);
}

function respondJson(res, status, obj) {
  if (res.writableEnded) return;
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

async function readBody(req) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > 1024 * 1024) {
      req.destroy();
      throw Object.assign(new Error('body too large'), { status: 413 });
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function parseJsonBody(req) {
  const raw = await readBody(req);
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw Object.assign(new Error('invalid JSON'), { status: 400 });
  }
}

function extractText(message, type) {
  if (type === 'conversation') {
    return message.conversation || null;
  }
  if (type === 'extendedTextMessage') {
    return message.extendedTextMessage?.text || null;
  }
  if (type === 'imageMessage' || type === 'videoMessage' || type === 'documentMessage') {
    return message[type]?.caption || null;
  }
  return null;
}

function makeMessageSummary(msg) {
  const type = getContentType(msg.message);
  return {
    id: msg.key?.id ?? null,
    jid: msg.key?.remoteJid ?? null,
    fromMe: msg.key?.fromMe ?? false,
    pushName: msg.pushName ?? null,
    timestamp: msg.messageTimestamp ? Number(msg.messageTimestamp) : null,
    text: extractText(msg.message, type),
  };
}

function onMessagesUpsert({ messages, type }) {
  try {
    if (type !== 'notify') return;
    for (const msg of messages) {
      if (!msg.message) continue;
      addEvent({ type: 'message', message: makeMessageSummary(msg) });
    }
  } catch (err) {
    logErr('messages.upsert handler failed:', err);
  }
}

async function onConnectionUpdate(update) {
  try {
    const { qr, connection, lastDisconnect } = update;

    if (qr) {
      state.qr = qr;
      // The string itself is long and rotates every ~20 s, so log only that one arrived.
      log('received a new linking QR from WhatsApp');
      addEvent({ type: 'qr', qr });
    }

    if (connection === 'connecting') {
      state.connecting = true;
      log('connection: connecting');
      addEvent({ type: 'connection', state: 'connecting', user: null, code: null, loggedOut: false });
    } else if (connection === 'open') {
      state.connecting = false;
      state.connected = true;
      state.qr = null;
      state.reconnectAttempts = 0; // a healthy connection clears the backoff
      state.user = state.sock?.user ?? null;
      log(`connection: open (user=${state.user?.id ?? 'unknown'})`);
      addEvent({ type: 'connection', state: 'open', user: state.user, code: null, loggedOut: false });
    } else if (connection === 'close') {
      state.connecting = false;
      state.connected = false;
      state.qr = null;
      const code = lastDisconnect?.error?.output?.statusCode ?? null;
      const loggedOut = code === DisconnectReason.loggedOut;

      // 401 logged-out and 500 bad-session leave credentials that can only fail the same way
      // again, so wipe them: the next connect() then starts a fresh pairing and emits a new QR.
      if (loggedOut || code === DisconnectReason.badSession) {
        logErr(`connection: closed (code=${code}) — clearing credentials so a new QR can be issued`);
        await clearAuthState();
      } else if (code === DisconnectReason.forbidden) {
        // 403: WhatsApp refused this number. Nothing to clear; it will not fix itself.
        logErr('connection: closed (403 forbidden) — this number appears blocked from linking');
      } else if (code === DisconnectReason.connectionReplaced) {
        // 440: another companion (or a second engine) took the session over.
        logErr('connection: closed (440) — another companion replaced this session');
      } else {
        logErr(`connection: closed (code=${code}; reconnecting)`);
      }

      addEvent({ type: 'connection', state: 'close', user: null, code, loggedOut });

      // This app has no other recovery path than retrying, so always retry — but with backoff, so
      // a persistent failure (403/440/500) cannot hammer WhatsApp every 2 s indefinitely.
      scheduleReconnect();
    }
  } catch (err) {
    logErr('connection.update handler failed:', err);
  }
}

function scheduleReconnect() {
  if (state.reconnectTimer) return;
  const attempt = ++state.reconnectAttempts;
  // 2 s, 4 s, 8 s … capped at 30 s. Normal 428/515 reconnects land on the first, fast step.
  const delay = Math.min(2000 * 2 ** (attempt - 1), 30_000);
  if (attempt > 1) {
    log(`reconnect attempt ${attempt} in ${delay} ms`);
  }
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    connect();
  }, delay);
}

function cancelReconnect() {
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
}

const VERSION_FETCH_TIMEOUT_MS = 8_000;

// Resolve the Baileys protocol version without ever letting a network fetch stall connect().
// fetchLatestBaileysVersion() uses axios with no timeout, so on a phone whose route or DNS is
// black-holed it never settles: connect() then stays suspended with no 'connecting' event and no
// reconnect timer, while the UI sits on "Starting engine…" forever.
//
// Only a genuinely fresh answer is cached. On timeout we return undefined, which lets makeWASocket
// use the version bundled with Baileys for this attempt, and the next connect() retries the fetch —
// caching a fallback for the process lifetime would pin a stale protocol version (WhatsApp answers
// 405 to outdated clients).
async function resolveBaileysVersion() {
  if (state.baileysVersion) return state.baileysVersion;

  try {
    const fetched = await Promise.race([
      fetchLatestBaileysVersion(),
      new Promise((resolve) => setTimeout(() => resolve(null), VERSION_FETCH_TIMEOUT_MS).unref()),
    ]);

    if (fetched && fetched.isLatest && Array.isArray(fetched.version)) {
      state.baileysVersion = fetched.version;
      log(`using fetched Baileys version ${fetched.version.join('.')}`);
      return state.baileysVersion;
    }
    log('version endpoint did not answer in time; using the version bundled with Baileys');
  } catch (err) {
    logErr('version fetch failed:', err);
  }
  return undefined;
}

async function connect() {
  if (state.sock) {
    try {
      state.sock.ev.removeAllListeners('connection.update');
      state.sock.ev.removeAllListeners('messages.upsert');
      state.sock.ev.removeAllListeners('creds.update');
      state.sock = null;
    } catch (err) {
      logErr('failed to clean up previous socket:', err);
    }
  }

  try {
    if (!state.authState) {
      const { state: authState, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
      state.authState = authState;
      state.saveCreds = saveCreds;
    }

    const version = await resolveBaileysVersion();
    const sock = makeWASocket({
      // Only spread `version` when we actually resolved one: passing an explicit `undefined`
      // would override the default that Baileys itself falls back to.
      ...(version ? { version } : {}),
      auth: state.authState,
      printQRInTerminal: false,
      browser: ['Walink', 'Chrome', '1.0.0'],
      markOnlineOnConnect: false,
    });

    state.sock = sock;
    sock.ev.on('creds.update', state.saveCreds);
    sock.ev.on('connection.update', onConnectionUpdate);
    sock.ev.on('messages.upsert', onMessagesUpsert);
  } catch (err) {
    logErr('failed to start Baileys socket:', err);
    state.connecting = false;
    scheduleReconnect();
  }
}

// Detach listeners, drop the in-memory credentials and delete them from disk, so the next
// connect() performs a brand-new pairing and therefore emits a fresh QR. Used by logout() and
// when WhatsApp tells us the session is unusable (401 logged-out / 500 bad-session).
async function clearAuthState() {
  try {
    if (state.sock?.ev) {
      state.sock.ev.removeAllListeners('connection.update');
      state.sock.ev.removeAllListeners('messages.upsert');
      state.sock.ev.removeAllListeners('creds.update');
    }
  } catch (err) {
    logErr('socket listener cleanup failed:', err);
  }
  state.sock = null;
  state.authState = null;
  state.saveCreds = null;
  state.connected = false;
  state.connecting = false;
  state.user = null;
  state.qr = null;
  try {
    await rm(AUTH_DIR, { recursive: true, force: true });
    await mkdir(AUTH_DIR, { recursive: true });
  } catch (err) {
    logErr('failed to clear auth directory:', err);
  }
}

async function logout() {
  cancelReconnect();
  if (state.sock?.logout) {
    try {
      await state.sock.logout();
    } catch (err) {
      logErr('logout failed:', err);
    }
  }
  await clearAuthState();
  addEvent({ type: 'connection', state: 'close', user: null, code: DisconnectReason.loggedOut, loggedOut: true });
}

async function handleSend(req, res) {
  const body = await parseJsonBody(req);
  const jid = body.jid;
  const text = body.text;
  if (typeof jid !== 'string' || !jid) {
    respondJson(res, 400, { error: 'jid is required' });
    return;
  }
  if (typeof text !== 'string') {
    respondJson(res, 400, { error: 'text is required' });
    return;
  }
  if (!state.connected || !state.sock) {
    respondJson(res, 503, { error: 'not connected' });
    return;
  }
  try {
    await state.sock.sendMessage(jid, { text });
    respondJson(res, 200, { ok: true });
  } catch (err) {
    logErr('sendMessage failed:', err);
    respondJson(res, 500, { error: err?.message || 'send failed' });
  }
}

async function handleEvents(req, res, url) {
  const sinceParam = url.searchParams.get('since');
  if (sinceParam === null || sinceParam === '') {
    respondJson(res, 400, { error: 'since is required' });
    return;
  }
  const since = parseInt(sinceParam, 10);
  if (!Number.isFinite(since)) {
    respondJson(res, 400, { error: 'since must be an integer' });
    return;
  }
  const available = state.events.filter((e) => e.id > since);
  if (available.length > 0) {
    respondJson(res, 200, available);
  } else {
    pushPending(res, since);
  }
}

async function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);

  try {
    if (req.method === 'GET' && url.pathname === '/api/health') {
      respondJson(res, 200, { ok: true });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/state') {
      respondJson(res, 200, { connected: state.connected, user: state.user, qr: state.qr });
      return;
    }

    // Debugging aid: on iOS the Node process' stdout/stderr are discarded, so expose the
    // mirrored log file. Usage: GET /api/log?tail=200
    if (req.method === 'GET' && url.pathname === '/api/log') {
      const requested = parseInt(url.searchParams.get('tail') || '200', 10);
      const tail = Number.isFinite(requested) ? Math.min(Math.max(requested, 1), 2000) : 200;
      respondJson(res, 200, { file: LOG_FILE, lines: readLogTail(tail) });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/events') {
      await handleEvents(req, res, url);
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/send') {
      await handleSend(req, res);
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/logout') {
      await logout();
      respondJson(res, 200, { ok: true });
      return;
    }

    respondJson(res, 404, { error: 'not found' });
  } catch (err) {
    logErr('request handler failed:', err);
    const status = err.status || 500;
    respondJson(res, status, { error: err.message || 'internal error' });
  }
}

// Diagnostic: time a tight arithmetic loop so engine.log records whether V8 is running its
// optimizing tiers or the interpreter only. Interpreter-only ("--jitless") V8 is typically many
// times slower here, which is how we tell whether a runtime really has JIT enabled — for example
// after changing the app's `node_v8_options`.
function logStartupBenchmark() {
  const iterations = 2_000_000;
  let acc = 0;
  const started = Date.now();
  for (let i = 1; i <= iterations; i++) {
    acc = (acc + i * 2654435761) % 2147483647;
  }
  const ms = Math.max(1, Date.now() - started);
  log(`v8 benchmark: ${iterations} iterations in ${ms} ms (~${Math.round(iterations / (ms / 1000))} ops/s)`);
}

logStartupBenchmark();

const server = http.createServer(handleRequest);

server.on('error', (err) => {
  logErr('HTTP server error:', err);
  // If the port is taken (e.g. a stale engine from a missed `killall`), bail out so the
  // app's waitForReady() fails fast and the engine can be restarted cleanly.
  if (err && err.code === 'EADDRINUSE') {
    logErr(`port ${PORT} already in use; exiting`);
    process.exit(1);
  }
});

server.listen(PORT, '127.0.0.1', () => {
  log(`engine listening on 127.0.0.1:${PORT}`);
  connect();
});

process.on('SIGTERM', () => {
  log('SIGTERM received, shutting down');
  cancelReconnect();
  // server.close() never fires its callback while long-poll sockets are open (each can
  // sit for up to 25 s), so arm a hard exit. unref() keeps the timer from holding the
  // process open on its own.
  setTimeout(() => process.exit(0), 1000).unref();
  server.close(() => process.exit(0));
});

process.on('uncaughtException', (err) => {
  logErr('uncaught exception:', err);
});

process.on('unhandledRejection', (err) => {
  logErr('unhandled rejection:', err);
});
