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
through AppState's test seam with a scripted harness. The file is named
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
| `harnessKind`, `model`, `effort`, `permissionMode` | the `AppConfig` fields of the same name |
| `controlMode` | `"builtin"` only for now; `"remote"` is refused until the runner has a fake remote target |
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

A step may also carry a `"reason"`. A step may also be tagged
`"expectNoChange": true`. That tag asserts the step leaves every observable
fact below unchanged, which is how a fixture shows that an input is ignored.

### `expect`: facts checked after the script (each key optional, at least one)

| Key | Checks |
| --- | --- |
| `harnessCalls` | every call AppState made on the harness, in order and with an exact count. `type` is one of `start {projectDir, model, permissionMode, effort, resumeSessionID, binaryPathOverride, agentCommand}`, `send {text}`, `interrupt`, `setModel {model}`, `setPermissionMode {mode}`, `respondToPermission {id, allow}` or `stop`. Only the keys you write are compared, so `"resumeSessionID": null` asserts a fresh start. |
| `transcript` | the transcript entries the script appended, in order and with an exact count: `{kind, text?}`, where kind is one of `user`, `assistant`, `tool`, `system` or `error` |
| `errorShown` | whether any `error` entry was appended |
| `lastSessionID` | the stored resumable id (a string, or `null` for none) |
| `pendingPermission` | whether a permission request is waiting for an answer |
| `status` | `noController`, `idle`, `listening`, `thinking` or `speaking` |

A failure names the scenario and its first mismatched expectation. For
example: `[resume-failure-retried-once-without-resume] (….json)
expect.harnessCalls[1].resumeSessionID: expected "stale-session-id", got null`.
