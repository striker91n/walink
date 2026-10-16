import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { mkdir, rm } from 'node:fs/promises';
import makeWASocket, {
  DisconnectReason,
  fetchLatestBaileysVersion,
  getContentType,
  useMultiFileAuthState,
} from '@whiskeysockets/baileys';

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
  baileysVersion: null,
};

function log(...args) {
  console.log('[walink]', ...args);
}

function logErr(...args) {
  console.error('[walink]', ...args);
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

function onConnectionUpdate(update) {
  try {
    const { qr, connection, lastDisconnect } = update;

    if (qr) {
      state.qr = qr;
      addEvent({ type: 'qr', qr });
    }

    if (connection === 'connecting') {
      state.connecting = true;
      addEvent({ type: 'connection', state: 'connecting', user: null, code: null, loggedOut: false });
    } else if (connection === 'open') {
      state.connecting = false;
      state.connected = true;
      state.qr = null;
      state.user = state.sock?.user ?? null;
      addEvent({ type: 'connection', state: 'open', user: state.user, code: null, loggedOut: false });
    } else if (connection === 'close') {
      state.connecting = false;
      state.connected = false;
      state.qr = null;
      const code = lastDisconnect?.error?.output?.statusCode ?? null;
      const loggedOut = code === DisconnectReason.loggedOut;
      addEvent({ type: 'connection', state: 'close', user: null, code, loggedOut });
      if (!loggedOut) {
        scheduleReconnect();
      }
    }
  } catch (err) {
    logErr('connection.update handler failed:', err);
  }
}

function scheduleReconnect() {
  if (state.reconnectTimer) return;
  state.reconnectTimer = setTimeout(() => {
    state.reconnectTimer = null;
    connect();
  }, 2000);
}

function cancelReconnect() {
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
    state.reconnectTimer = null;
  }
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

    // Cache the Baileys version: fetching it hits the network, which is slow/absent on
    // a phone right after boot. If the fetch fails, the outer catch reconnects.
    if (!state.baileysVersion) {
      const fetched = await fetchLatestBaileysVersion();
      state.baileysVersion = fetched.version;
    }
    const version = state.baileysVersion;
    const sock = makeWASocket({
      version,
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

async function logout() {
  cancelReconnect();
  if (state.sock?.logout) {
    try {
      await state.sock.logout();
    } catch (err) {
      logErr('logout failed:', err);
    }
  }
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

process.on('unhandledRejection', (err) => {
  logErr('unhandled rejection:', err);
});
