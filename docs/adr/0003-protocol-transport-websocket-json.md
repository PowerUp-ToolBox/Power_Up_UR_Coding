# 3. PowerUp protocol transport: WebSocket + JSON on the local listener

Date: 2026-08-27

## Status

Accepted

## Context

DEVELOPMENT.md §3.1 calls for a language-agnostic local protocol so device
plugins, alternative UIs, and hobbyist hardware can integrate without touching
PowerUp's internals (the obs-websocket lesson). The transport must work from
every plugin language (TypeScript, Python, Rust, an ESP32 relay on the LAN via
a local bridge), carry server-pushed events (status, transcript, session
changes) *and* client-sent intents, and inherit the existing security posture:
127.0.0.1 only, token-authenticated.

Options considered:

- **WebSocket + JSON** — bidirectional push, a client library exists in every
  language, debuggable with `websocat`, and co-hostable on the port the hook
  listener already owns.
- **Raw TCP + JSONL** — simplest server, but every client hand-rolls framing
  and reconnect; no browser story at all.
- **gRPC** — codegen and heavy runtimes; hostile to the hobbyist plugin author
  this protocol exists for.
- **stdio-spawned plugins** (ACP-style) — good for plugins PowerUp launches,
  but can't serve an already-running external client or a future remote UI;
  can be added later *on top of* the same JSON message vocabulary.

## Decision

The PowerUp protocol (spec: `docs/protocol.md`) runs as **JSON text messages
over WebSocket**, served by the existing loopback listener alongside the hook
endpoint (`POST /event`) on the same port. Specifics:

- Endpoint `GET /ws` upgrades to WebSocket; the port stays bound to 127.0.0.1.
- Auth is **in-band**: the first client message must be a `hello` carrying the
  listener token. No token in the URL (URLs leak into logs) and no
  header-based auth (keeps future browser-based clients possible).
- Upgrade requests that carry an **Origin header are rejected** — browsers
  always send one, so this shuts the cross-site-WebSocket-hijacking door until
  an explicit allowlist is designed.
- Messages are single JSON objects with a `type` field; unknown fields are
  ignored; unknown types get an `error` reply, never a disconnect.
- The protocol carries a version number, starting at **0** (pre-1.0, may
  break); `hello` declares what the client speaks.

## Consequences

- One port, one token, one server to threat-model (docs/protocol.md §security).
- Any language with a WebSocket client can implement a device plugin or UI.
- The Swift app must implement server-side WebSocket framing (RFC 6455) on
  Network.framework by hand — bounded, and pinned by unit tests; v0 declares
  conservative limits (text frames only, no fragmentation, 1 MB max payload).
- Voice capture stays out of the wire protocol on purpose: the microphone is
  local to the app; remote clients send text intents instead.
