# Shared fixtures

Language-neutral test data that every implementation of PowerUp's rules is
checked against: the Swift app's XCTest suites today and the Rust core's
`cargo test` later (PLAN-any-device-any-os.md, ADR 0012). Each implementation
loads these files from its own source location. Swift resolves them relative
to `#filePath`, because SwiftPM accepts no resources outside a target. Do not
copy them into a target.

CI fails if this directory holds no JSON fixtures.

## Conventions

- One subdirectory per area: `session/`, and later others such as
  `text-safety/`.
- Plain JSON only, with no comments and no implementation-specific shapes.
- Every file starts with a header: `formatVersion`, `name`, `description`,
  `reason` (why the rule exists), `source` (where the rule is written down)
  and `verifiedBy` (the implementations that run it, for example
  `["swift"]`). Add `capturedAgainst` when the data was recorded from a real
  tool, for example a `claude` CLI version.
- Use the terms in `CONTEXT.md`.

## `session/`: session scenarios (format 1)

Each file is one rule of the session state machine (epic #92), played
through AppState's test seam with a scripted harness, a recording injector
standing in for the remote session, and a scripted clock. The file is named
`<name>.json`. To pin a new session rule, add a scenario here rather than
writing a bespoke test. The Swift runner is
`Tests/PowerUpTests/SessionScenario.swift`, and the table test is
`SessionScenarioTests`.

```json
{
  "formatVersion": 1,
  "name": "resume-failure-retried-once-without-resume",
  "description": "What happens, in one or two sentences.",
  "reason": "Why the rule exists (the failure it prevents).",
  "source": "DESIGN.md section / code location",
  "verifiedBy": ["swift"],
  "config": { "harnessKind": "claude", "project": true, "lastSessionID": "stale-session-id" },
  "script": [
    { "call": "startSessionIfNeeded", "reason": "App launch." },
    { "harnessEvent": { "type": "ended", "exitCode": 1 }, "reason": "…" }
  ],
  "expect": {
    "harnessCalls": [ { "type": "start", "resumeSessionID": "stale-session-id" } ],
    "status": "noController"
  }
}
```

The parser is strict: an unknown key, a missing required key or a value of
the wrong type is a load error that names the file and the JSON path.

### `config` (all keys optional)

Anything not set here comes from the default config, with TTS off.

| Key | Meaning |
| --- | --- |
| `harnessKind`, `model`, `effort`, `permissionMode` | the `AppConfig` fields of the same name. The scripted harness reports the capabilities of the adapter it stands in for: `"claude"` supports effort (restart + resume), `"acp"` does not |
| `controlMode` | `"builtin"` or `"remote"`. In remote mode nothing is typed into a real terminal: every text and key goes to a recording injector (see `injectorCalls`) |
| `project` | `true`: a fresh project folder, written `"$project"` in expectations; default `false` (no folder chosen) |
| `lastSessionID` | the stored resumable id (it also seeds the folder's own entry, as on a real launch) |
| `controllerConnected` | `true`: a simulated pad is connected before AppState is built |

### `script`: an ordered list of steps

Each step has exactly one of these:

- `"call"`: a public AppState call. The options are `startSessionIfNeeded`
  (what app launch does), `newSession`, `sendUserText` (needs `"text"`),
  `interruptClaude` and `answerPendingPermission` (needs `"allow"`).
- `"intent"`: an intent by its protocol wire name (docs/protocol.md), for
  example `approve`, `reject`, `interrupt`, `cycleEffort`, or `sendPrompt`
  with `"text"`. `showWindow` and the voice-capture intents are not
  supported here.
- `"harnessEvent"`: one normalized `HarnessEvent`, tagged by `type`, with
  fields named as in Swift:
  - `sessionReady {sessionID, model}`
  - `replyDelta {text}`
  - `reply {text}`
  - `toolUse {name, detail}`
  - `turnCompleted {resultText?, costUSD?, isError, detail}`
  - `controlResult {action, ok, detail, value?}`
  - `permissionRequest {id, name, kind, detail}`
  - `notification {message}`
  - `runtimeError {message}`
  - `ended {exitCode}`
- `"hookEvent"`: one Claude Code hook as PowerUp's listener delivers it in
  remote mode (`RemoteHookEvent`), tagged by `type`: `userPromptSubmit`,
  `postToolUse` (the heartbeat), `notification`, `stop` or `sessionEnd`.
  The optional fields are `sessionID`, `cwd` and `text` (the prompt, the
  reply, the message, the tool name or the end reason, by type). A missing
  `sessionID` is tracked as one shared unknown session.
- `"advanceClock"`: a number of seconds (zero or more). The scripted clock
  moves forward, and every remote-turn expiry check that falls due on the
  way runs at its due time. Time never passes otherwise, and nothing
  sleeps. The remote-turn expiry is 15 minutes (900 seconds) without a sign
  of life; scenarios check just under it (`899`) and just past it (`901`)
  rather than the exact instant.

A step may also carry:

- `"reason"`: why the step is there.
- `"expectNoChange": true`: asserts the step leaves every observable fact
  below unchanged, which is how a fixture shows that an input is ignored.
- `"expect": {…}`: a checkpoint. The same keys as the final `expect`
  block, checked right after this step, so a fixture can show *when*
  something happened (for example, that no restart was recorded until the
  turn completed). A failure names the step: `step 4 expect.harnessCalls…`.
- `"settle": false`: the next step runs straight after this one, before
  AppState gets to run work it deferred (a hop off the event delivery, such
  as the effort restart after `turnCompleted`). This models input that was
  already on its way when the step happened. By default every step settles
  first. The last step cannot set it.

The scripted harness follows the real adapters' own state: `start` makes
it starting, `sessionReady` makes it ready and sets its session id and
model, `send` makes it working, `turnCompleted` makes it ready again, an
acknowledged `set_model` `controlResult` sets its model, and `ended` or
`stop` stops it.

### `expect`: facts checked after the script (each key optional, at least one)

| Key | Checks |
| --- | --- |
| `harnessCalls` | every call AppState made on the harness, in order and with an exact count. `type` is one of `start {projectDir, model, permissionMode, effort, resumeSessionID, binaryPathOverride, agentCommand}`, `send {text}`, `interrupt`, `setModel {model}`, `setPermissionMode {mode}`, `respondToPermission {id, allow}` or `stop`. Only the keys you write are compared, so `"resumeSessionID": null` asserts a fresh start. |
| `transcript` | the transcript entries the script appended, in order and with an exact count: `{kind, text?}`, where kind is one of `user`, `assistant`, `tool`, `system` or `error` |
| `errorShown` | whether any `error` entry was appended |
| `lastSessionID` | the stored resumable id (a string, or `null` for none) |
| `pendingPermission` | whether a permission request is waiting for an answer |
| `pendingPermissionArmed` | whether the waiting request is a destructive one that a first `approve` has armed (the banner reads "Confirm"); `false` when nothing is waiting |
| `status` | `noController`, `idle`, `listening`, `thinking` or `speaking` |
| `liveModel` | the model the harness last reported (its init echo, or an acknowledged switch), sent to protocol clients as `liveModel`; `null` when nothing has been reported |
| `modelChip` | the model chip's label: the configured model when it is an explicit alias, otherwise `liveModel`, otherwise `"default"` |
| `remoteTurnActive` | remote mode: a remote turn is in flight (the focused session's, when a focus is set). This is what lights the working status in remote mode |
| `remoteFocus` | remote mode: the focused session id, or `null` when every session is heard |
| `injectorCalls` | everything remote mode delivered into the remote session, in order and with an exact count: `text {text, submit}` (text after line breaks are flattened; `submit` presses Enter after it) or `key {key}`, where key is `enter`, `escape` or `shiftTab` |

A failure names the scenario and its first mismatched expectation. For
example: `[resume-failure-retried-once-without-resume] (….json)
expect.harnessCalls[1].resumeSessionID: expected "stale-session-id", got null`.
