# The PowerUp protocol — spec v0

*[← Back to README](../README.md) · [All docs](../README.md#documentation)*

The PowerUp protocol lets any local program — a device plugin, an alternative
UI, a script — talk to a running PowerUp: receive live **status**,
**transcript**, and **session** events, and send **intents** (approve,
interrupt, send a prompt, …). It exists so new devices and surfaces can be
built in any language without touching PowerUp's internals
([DEVELOPMENT.md §3.1](../DEVELOPMENT.md), [ADR 0003](adr/0003-protocol-transport-websocket-json.md)).

**Scope note (2026-09-17).** This is the **local plugin API**: it binds to
127.0.0.1 only, and that is deliberate. Remote clients such as a phone app
need the transport-trust work in ADR 0010, which is deferred; nothing here
should be read as a phone feature. See ADR 0012 for where the protocol sits
in the architecture (beside the core, not between an app and its own logic).

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
- WebSocket-level pings are answered with pongs carrying the same payload; a
  JSON `{"type":"ping"}` is answered with `{"type":"pong"}`. Both are
  answered before `hello` too. A close frame is answered with close 1000.
- Text only: a binary frame closes the connection (1003). Text that is not
  valid UTF-8 is a `malformed` message (close 1002, never 1007).
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
  A missing or empty token → `error` (`bad_hello`) and close (1002).
- `protocol` — optional, defaults to the server's version. A version the
  server doesn't speak → `error` (`unsupported_protocol`) and close (1002).
- A client that hasn't authenticated **15 seconds** after it connected is
  disconnected, without a reply or a close frame.
- An `intent` before authentication → `error` (`not_authenticated`) and
  close (4003). A `ping` is answered, and a message that can't be read gets
  its error as it would after `hello` (unknown types and intents leave the
  connection open, until the 15 seconds are up).
- A second `hello` on an authenticated connection is ignored.

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
| `unsupported_protocol` | Connection closes (1002) |
| `bad_hello`, `malformed` | Connection closes (1002) |
| `unknown_type`, `unknown_intent` | Connection stays open |
| `server_busy` | Connection closes (1013) — client cap reached (16) |

The `code` strings and their messages are contract: clients may branch on
them.

### Close codes

| Code | Sent when |
|---|---|
| 1000 | The client sent a close frame |
| 1002 | A frame breaks the rules (unmasked, fragmented, reserved bits, an unknown opcode, a payload over 1 MB), or `malformed`, `bad_hello`, `unsupported_protocol` |
| 1003 | The client sent a binary frame |
| 1009 | More than 2 MB is waiting to be decoded |
| 1013 | `server_busy` |
| 4001 | `auth_failed` |
| 4003 | `not_authenticated` |

A close carries its code and no reason text. Each error message is sent
before its close frame.

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
- **Resource limits.** The spec constants below. Violations close the
  connection; nothing is ever executed from a malformed message.
- **The hook endpoint** (`POST /event`, with the token in
  `X-PowerUp-Token`; a wrong or missing token is 403, and any request but
  this one and `/ws` is 404) answers `204 No Content` *before* it hands the hook to the
  app, so Claude Code's hook script (curl with a 1-second limit) is never
  held up. It parses defensively, accepts bare-LF line endings (a real hook
  script sent them), answers `Expect: 100-continue`, and acts on nothing
  but the five hooks PowerUp installs (`Stop`, `UserPromptSubmit`,
  `Notification`, `SessionEnd`, `PostToolUse`); anything else is answered
  and dropped.

### Spec constants

These are part of the spec. The reference implementation keeps them as
constants of `rust/powerup-core/src/protocol/listener.rs`.

| Limit | Value | Past it |
|---|---|---|
| Connections at once | 32 | Accepting one more drops the oldest connection that is not an authenticated protocol client, unanswered. An authenticated client is never dropped this way, so a burst of hook posts can never sever a device plugin |
| Authenticated protocol clients | 16 | `server_busy`, close 1013 |
| Idle deadline | 15 s after the connection opened | Dropped unless it is an authenticated protocol client by then (hook posts included) |
| Request header block | 16 KB | 431 |
| Hook post body | 4 MB | 413 (also a negative `Content-Length`, or more than 16 KB + 4 MB received) |
| Frame payload | 1 MB | close 1002, as soon as the frame's header shows the length |
| Bytes waiting to be decoded | 2 MB | close 1009 |
| Port | 1024–65535 | The listener doesn't start; Settings shows why |
| Bind retries | 3, after 2, 4 and 6 s | A port that stays taken leaves the listener stopped, with the reason in Settings, until the next successful bind or a new start |

### Safety invariants

These hold for every input source — buttons, protocol clients, and future
devices — and are enforced by construction plus tests
(`Tests/Fixtures/protocol/intent-names.json`, `IntentMapperTests`,
`AppConfigTests`):

1. **No input can silently escalate permissions.** The only permission
   intent is `cyclePermissionMode`; its fixed cycle
   (`acceptEdits → plan → default`) excludes `bypassPermissions`. Reaching
   bypass requires the Settings UI, explicitly.
2. **Unknown input is inert.** Unknown message types, intents, fields, and
   hook events are answered or ignored — never partially executed.
3. **The protocol can't grow the attack surface quietly.** Adding a wire
   intent requires touching the core's name table
   (`intent_for_protocol_name` in `rust/powerup-core/src/protocol/message.rs`),
   whose fixture `Tests/Fixtures/protocol/intent-names.json` asserts the
   vocabulary — a new dangerous name is a reviewed decision, not an
   accident.

## Versioning rules

- v0 may break between app releases; `welcome.protocol` tells you what you got.
- Additions (new message types, new fields, new intents) happen within v0 —
  ignore what you don't know.
- The version bumps to 1 when the shape stabilizes; from then on, breaking
  changes bump the version and servers refuse `hello`s they can't honor.

## Reference implementation notes

The reference implementation is the Rust core's `protocol` module
(`rust/powerup-core/src/protocol/`; DESIGN.md v2.15). This spec and that
module must change together:

- `message.rs` — every client and server message, the error codes and
  their text, the version rule, and the intent vocabulary;
- `handshake.rs` — the request head (bare LF included), the upgrade
  decision and `Sec-WebSocket-Accept`;
- `framing.rs` — RFC 6455 frames and the close codes;
- `listener.rs` — the connection policy: the hook endpoint, the hello
  gate, the caps, the idle deadline and the bind retry, as a state machine
  that turns what happened on a socket into effects.

Each platform keeps only its sockets: on macOS,
`Sources/PowerUp/RemoteListener.swift` (Network.framework) feeds the core
what happened and carries out its effects in order.

Tests: the shared fixtures `Tests/Fixtures/protocol/` (messages, handshake,
frames) and `Tests/Fixtures/listener/` (the policy, one scenario per rule)
run in both the Rust core and the Swift app, and `ProtocolServerTests.swift`
runs a live client against a real listener on a loopback port.
