# The PowerUp protocol — spec v0

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

The PowerUp protocol lets any local program — a device plugin, an alternative
UI, a script — talk to a running PowerUp: receive live **status**,
**transcript**, and **session** events, and send **intents** (approve,
interrupt, send a prompt, …). It exists so new devices and surfaces can be
built in any language without touching PowerUp's Swift internals
([DEVELOPMENT.md §3.1](../DEVELOPMENT.md), [ADR 0003](adr/0003-protocol-transport-websocket-json.md)).

**Version: 0 (pre-1.0).** The protocol may change incompatibly between app
versions until v1; the `hello`/`welcome` exchange carries the version so
mismatches fail loudly, not weirdly.

## Transport

- **WebSocket**, endpoint `ws://127.0.0.1:<port>/ws`. The port is the one in
  **Settings → Remote** (default `48738`) — the same listener that receives
  Claude Code hook posts on `POST /event`.
- The server binds **127.0.0.1 only**. Nothing off-machine can connect.
- Messages are **single JSON objects as WebSocket text frames**, at most
  **1 MB**, **no fragmentation** (a non-final data frame closes the
  connection). Encoded messages never contain raw newlines.
- WebSocket-level pings are answered with pongs; a JSON `{"type":"ping"}` is
  answered with `{"type":"pong"}`.
- Upgrade requests carrying an **`Origin` header are refused (403)** — see
  Security below. Native clients don't send one.

Try it from a terminal (token is in **Settings → Remote → Read-back**):

```sh
websocat ws://127.0.0.1:48738/ws
{"type":"hello","token":"YOUR-TOKEN","protocol":0}
{"type":"intent","intent":"sendPrompt","text":"run the tests"}
```

## Handshake

The **first message** a client sends must be `hello`:

```json
{"type": "hello", "token": "<listener token>", "protocol": 0}
```

- `token` — required; the listener token from Settings (also stored in
  `config.json`). Wrong token → `error` (`auth_failed`) and the connection
  closes (WebSocket code 4001).
- `protocol` — optional, defaults to the server's version. A version the
  server doesn't speak → `error` (`unsupported_protocol`) and close.
- A client that hasn't authenticated within **15 seconds** is disconnected.
- Anything other than `hello` before authentication → `error`
  (`not_authenticated`) and close (4003).

On success the server replies with `welcome`, then a snapshot (current
`status` and `session` messages), then live events as they happen:

```json
{"type": "welcome", "protocol": 0, "app": "PowerUp", "version": "1.0"}
{"type": "status", "status": "idle"}
{"type": "session", "model": "default", "liveModel": "claude-sonnet-5", "effort": "high",
 "permissionMode": "acceptEdits", "controlMode": "builtin", "sessionID": "…", "costUSD": 0.42}
```

## Server → client messages

| `type` | Fields | When |
|---|---|---|
| `welcome` | `protocol`, `app`, `version` | After a successful `hello` |
| `status` | `status`: `noController` \| `idle` \| `listening` \| `thinking` \| `speaking` | On every status change (mirrors the light bar) |
| `transcript` | `entry`: `{id, kind, text, date}` — `kind`: `user` \| `assistant` \| `tool` \| `system` \| `error`; `date`: epoch seconds | On every new transcript entry |
| `session` | `model`, `liveModel`?, `effort`, `permissionMode`, `controlMode` (`builtin` \| `remote`), `sessionID`?, `costUSD`, `tokens`? (present when the harness reports usage) | On any session-fact change. `model` is the configured alias (`"default"` = adapter default); `liveModel` is what the running session reports |
| `pong` | — | Answer to a JSON `ping` |
| `error` | `code`, `message` | See error codes below |

Clients MUST ignore unknown message types and unknown fields — new ones will
appear within v0.

## Client → server messages

| `type` | Fields | Meaning |
|---|---|---|
| `hello` | `token`, `protocol`? | Authenticate (first message only) |
| `intent` | `intent`, `text`? | Perform one intent (below) |
| `ping` | — | Liveness check |

### Intents

`{"type":"intent","intent":"<name>"}` — exactly the actions a mapped
controller button could perform:

`approve`, `reject`, `interrupt`, `stopSpeaking`, `replayLastReply`,
`toggleTTS`, `newSession`, `showWindow`, `cycleModel`, `cycleEffort`,
`cyclePermissionMode`, `cycleProject`, `cycleFocus`, `toggleControlMode`,
`sendDraft`, and `sendPrompt` (requires non-empty `text`).

Deliberately **not** in the vocabulary:

- **Voice capture** (`beginVoiceCapture`/`endVoiceCapture`) — the microphone
  is local to the app; remote clients send text via `sendPrompt`.
- **Any direct setter** for model/effort/permission mode — only the cycle
  intents exist, and the permission cycle's fixed order excludes
  `bypassPermissions` (see Safety invariants).

An unknown or disallowed intent gets `error` (`unknown_intent`) and the
connection stays open. Nothing is ever performed for an unrecognized name.

### Error codes

| `code` | Then |
|---|---|
| `auth_failed` | Connection closes (4001) |
| `not_authenticated` | Connection closes (4003) |
| `unsupported_protocol` | Connection closes |
| `bad_hello`, `malformed` | Connection closes (1002) |
| `unknown_type`, `unknown_intent` | Connection stays open |
| `server_busy` | Connection closes (1013) — client cap reached (16) |

## Security & threat model

The server can inject text into a coding session and approve agent actions,
so it is treated as an attack surface even though it never leaves the machine:

- **Network position.** Bound to 127.0.0.1 only; never `0.0.0.0`, never a LAN
  interface. Remote attackers have no path to it.
- **Local processes.** Any local process can *connect*, but every action
  requires the token, which lives in the user's own
  `~/Library/Application Support/PowerUp/config.json` (user-only file access).
  A process that can read that file can already do anything the protocol can
  do more directly — the token gates accidental and cross-user access, not a
  same-user attacker, which no localhost design can.
- **Browsers (CSWSH).** A malicious web page can open
  `ws://127.0.0.1:…` — that's why upgrades bearing an `Origin` header are
  refused before any message is read, and why the token is required on top.
  A future browser-based UI needs an explicit Origin allowlist, designed then.
- **Resource limits.** ≤ 32 concurrent connections (hook bursts can never
  evict a protocol client), ≤ 16 authenticated clients, 1 MB frames, 2 MB
  per-connection buffer, 15 s handshake deadline. Violations close the
  connection; nothing is ever executed from a malformed message.
- **The hook endpoint** (`POST /event`) is unchanged: token-checked,
  answers 204, parses defensively, acts on nothing but the three known hook
  shapes.

### Safety invariants

These hold for every input source — buttons, protocol clients, and future
devices — and are enforced by construction plus tests
(`IntentMapperTests`, `AppConfigTests`):

1. **No input can silently escalate permissions.** The only permission
   intent is `cyclePermissionMode`; its fixed cycle
   (`acceptEdits → plan → default`) excludes `bypassPermissions`. Reaching
   bypass requires the Settings UI, explicitly.
2. **Unknown input is inert.** Unknown message types, intents, fields, and
   hook events are answered or ignored — never partially executed.
3. **The protocol can't grow the attack surface quietly.** Adding a wire
   intent requires touching `IntentMapper.intent(forProtocolName:)`, whose
   test asserts the vocabulary — a new dangerous name is a reviewed decision,
   not an accident.

## Versioning rules

- v0 may break between app releases; `welcome.protocol` tells you what you got.
- Additions (new message types, new fields, new intents) happen within v0 —
  ignore what you don't know.
- The version bumps to 1 when the shape stabilizes; from then on, breaking
  changes bump the version and servers refuse `hello`s they can't honor.

## Reference implementation notes

Server: `Sources/PowerUp/RemoteListener.swift` (connections),
`WebSocketFraming.swift` (RFC 6455 framing), `PowerUpProtocol.swift`
(messages — this spec and that file must change together),
`Intent.swift` (the intent vocabulary). Tests:
`ProtocolServerTests.swift` runs a live client against a real listener.
