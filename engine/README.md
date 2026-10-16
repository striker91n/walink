# Walink Engine

The on-device Node.js engine that runs Baileys on the iPhone and exposes a tiny loopback REST API for the native iOS app.

## Launch

The native iOS app boots the engine by calling `node_start` from `NodeMobile.framework` with:

```c
char *argv[] = { "node", "<app-bundle>/engine/main.js", NULL };
node_start(2, argv);
```

Before launching, the native side should `setenv` the desired configuration and `chdir()` into the app container.

## Configuration

| Environment variable | Default                         | Description                         |
|----------------------|---------------------------------|-------------------------------------|
| `WALINK_PORT`        | `8787`                          | TCP port for the loopback HTTP API  |
| `WALINK_DATA_DIR`    | `$HOME/.walink`                 | Directory for auth state and data   |

Auth state is stored under `<WALINK_DATA_DIR>/auth` via `useMultiFileAuthState`.

## HTTP API

The server binds **only** `127.0.0.1`.

| Method | Path | Request | Response |
|--------|------|---------|----------|
| `GET`  | `/api/health` | — | `{"ok":true}` |
| `GET`  | `/api/state`  | — | `{"connected":bool,"user":object|null,"qr":string|null}` |
| `GET`  | `/api/events?since=<int>` | `since` = last seen event id | Long-poll (up to 25 s), JSON array of events with `id > since` |
| `POST` | `/api/send`   | `{"jid":"...","text":"..."}` | `{"ok":true}` or `{"error":"..."}` (4xx/5xx) |
| `POST` | `/api/logout` | — | `{"ok":true}` |

## Events

Every event has `{ id: int, t: ms-epoch, type: string, ... }`.

| Type | Shape |
|------|-------|
| `qr` | `{"type":"qr","qr":"<raw-qr-string>"}` |
| `connection` | `{"type":"connection","state":"connecting|open|close","user":object|null,"code":number|null,"loggedOut":bool}` |
| `message` | `{"type":"message","message":{"id","jid","fromMe","pushName","timestamp","text","type"}}` |

The engine keeps the last 500 events in memory for replay by long-polling clients.
