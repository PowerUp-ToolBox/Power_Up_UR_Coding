# Shared fixtures

Language-neutral test data that every implementation of PowerUp's rules is
checked against (PLAN-any-device-any-os.md, ADR 0012): the Swift app's XCTest
suites play every file, and the Rust core's `cargo test` plays the areas whose
rules it owns so far (`mapping/` and `device/`, since slice 2.2, and
`harness/`, since slice 2.3) and checks the format of the rest, picking up
more as later slices port them. Each implementation loads these files from
its own source location. Swift resolves
them relative to `#filePath`, because SwiftPM accepts no resources outside a
target. Do not copy them into a target.

CI fails if this directory holds no JSON fixtures, from both sides: a CI
step for the Swift suites, and `the_shared_fixtures_directory_is_not_empty`
in `rust/powerup-core/tests/fixtures.rs` for the Rust core. The Rust loader
(`rust/powerup-core/tests/support/mod.rs`) checks every header field this
README requires and rejects unknown keys, so a new key or a new area has to be
taught to both loaders; it is slightly stricter than the Swift readers (it
requires a non-blank `source`, `description` and `reason` in scenarios).
Record a Rust implementation only when a core slice actually plays a file:
add `"rust"` to a scenario's `verifiedBy` list, or name the Rust test in a
case table's `verifiedBy` sentence.

## Conventions

- One subdirectory per area: `session/` (scenarios), `text-safety/`,
  `status/`, `mapping/`, `device/` and `harness/` (case tables).
- Plain JSON only, with no comments and no implementation-specific shapes.
- Every file starts with a header and gives a `reason` for each thing it
  pins. There are two formats:
  - Session scenarios (`session/`) use `formatVersion`, `name`,
    `description`, `reason` (why the rule exists), `source` (where the rule
    is written down) and `verifiedBy` (the implementations that run it, for
    example `["swift"]`). See [`session/`](#session-session-scenarios-format-1).
  - Case tables (`text-safety/`, `status/`, `mapping/`, `device/`, `harness/`) use `description`,
    `function`, `verifiedBy`, `capturedAgainst` and a `cases` list in which
    every case has a `reason`. See [case tables](#text-safety-and-status-case-tables).
- Add `capturedAgainst` when the data was recorded from a real tool (for
  example a `claude` CLI version) or characterizes a specific build.
- Use the terms in `CONTEXT.md`.

## `text-safety/` and `status/`: case tables

Each file pins one pure function as a table of input → expected rows: what
remote mode does to text before it is typed or shown (`text-safety/`, epic
#93) and how the status pill and light bar are derived (`status/`, epic
#94). The Swift loader is `TextSafetyFixtures` in
`Tests/PowerUpTests/TextSafetyFixtureTests.swift`; `TextSafetyFixtureTests`,
`CmuxReportingFixtureTests` and `StatusDerivationTests` run the files.

```json
{
  "description": "What the rule does, precisely enough to reimplement it.",
  "function": "RemoteControlService.condense(_:maxChars:) — input {text, maxChars} in, string out",
  "verifiedBy": "Where the rule is written down and which tests run this file.",
  "capturedAgainst": "The build or tool version the expected values were taken from.",
  "cases": [
    { "name": "tab becomes a space", "input": { "text": "a\tb", "maxChars": 80 },
      "expected": "a b", "reason": "The failure this case guards against." }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `description` | the rule in prose, including any edge it depends on (for example, Characters are extended grapheme clusters, never bytes) |
| `function` | the function under test, with the shape of `input` and `expected` |
| `verifiedBy` | a string: the contract text the rule comes from, and the test files that run the table |
| `capturedAgainst` | a string: the build or tool the expected values were recorded from |
| `cases` | a non-empty list. Each case has a unique `name`, an `input` (a string, or an object when the function takes more than one value; in `mapping/action-decode.json` any JSON value, in `mapping/config-load.json` a whole config.json object), an `expected` value (a string, a bool, a list, an object or `null`, per file) and a non-empty `reason` |

The loader rejects a file with an empty `description`, `function` or
`verifiedBy`, no cases, a blank or duplicate case name, or an empty
`reason`. A failure names the file and the case.

## `mapping/` and `device/`: case tables with value descriptors

The device layer's rules (spec #97, slice 2.2). `mapping/` holds what an
action looks like in `config.json`, how a stored action is read back, the
intent a press or release produces, which actions hold, the default
mappings, how a (profile, control) pair resolves to an action, and how a
config.json's mapping subtree loads (including whether the file is copied
before the next save). `device/` holds the control-kind rule, how a device
profile is read and written back, the built-in DualSense profile, which
connected controller fills the Controller slot, and the hold rule. The
files are ordinary case tables. Values that are Swift enums in the app and
Rust enums in the core are written as plain JSON descriptors, so neither
language's spelling leaks into the file:

| Descriptor | Shape |
| --- | --- |
| action | `{"case": <case name>}`, plus `"prompt"` for `sendPrompt`. The case names are the 19 Swift case names, which are also the keys the config writer stores, for example `toggleTTS` and `pushToTalkDraft` |
| intent | `{"intent": <Swift case name>}`, plus `"mode": "send"` or `"draft"` for `beginVoiceCapture` and `"prompt"` for `sendPrompt` |
| mappings | `{<profile id>: {<control id>: <action descriptor>}}`, or the string `"defaults"` for the shipped default mappings (`mapping/default-mapping.json` spells those out) |
| effect | `{"effect": <Swift case name>}`, one of `beginCapture`, `endCapture`, `cancelCapture`, `deliver` and `ignore`, plus `"mode": "send"` or `"draft"` for `beginCapture` and `"intent": <intent descriptor>` for `deliver` |
| controller | `{"id", "profileID", "displayName"}`, every field a string, as `ConnectedController` holds them |
| hold step | `{"action": <action descriptor>, "control": <control id>, "phase": "began"` or `"ended", "toggleCaptureActive": <bool>}`, every field required, or `{"releaseAll": true}` for the forced release |

Device profiles are not descriptors: `device/profile-decode.json` and
`device/dualsense-profile.json` hold profile objects exactly as a profile
file stores them (`{id, displayName, controls: [{id, kind, displayName,
symbolName}]}`), and the expected value is compared as JSON, not as text.

`null` as an expected value means "no value": a binding that is dropped,
a phase that produces no intent, or a kind or profile that fails to read.
`action-shape.json` expects the exact compact text Swift's `JSONEncoder`
(`.sortedKeys`) writes, so it is a byte comparison, not a JSON comparison.
`action-decode.json` takes any JSON value as input, because it pins what
happens to whatever a file holds for one control. `config-load.json`
expects `{deviceMappings, backupBeforeSave}`. `device/slot-selection.json`
takes `{mostRecentlyConnectedFirst: [<controller>], pinnedID}` (`null` for
Automatic) and expects the controller in the slot, or `null` when it is
empty. `device/hold-rule.json` takes `{steps: [<hold step>]}`, played in
order through one tracker that starts idle, and expects `{effects, owner}`:
one effect per step and the owning control id left at the end (`null` for
none). Its cases use all five effects between them.

The Swift runners are `Tests/PowerUpTests/MappingFixtureTests.swift` and
`DeviceFixtureTests.swift` (their descriptor helpers are in
`FixtureValues.swift`), and the Rust runners are
`rust/powerup-core/tests/mapping.rs` and `tests/device.rs` (their helpers
are in `tests/support`).

## `harness/`: case tables for the Claude adapter

The built-in Claude harness's wire rules (spec #98, slice 2.3):
`claude-lines.json` holds how the `claude` CLI's stdout bytes become lines,
`claude-stream.json` what one line of its stream-json output parses into,
`claude-stdin.json` what each call writes on its stdin, and
`claude-launch.json` the argv a launch passes. All are ordinary case
tables, with these descriptors:

| Descriptor | Shape |
| --- | --- |
| line input | a string (the line as UTF-8, without its newline), or `{"hex": "<bytes>"}` for bytes that are not text, such as invalid UTF-8 |
| claude event | `{"event": <ClaudeEvent case name>}` plus Swift's field names: `ready {sessionID, model}`, `textDelta {text}`, `assistantMessage {text}`, `toolUse {name, detail}`, `turnCompleted {resultText, costUSD, isError, subtype}` (`resultText` and `costUSD` may be `null`), `controlResult {action, ok, detail, value}` (`value` may be `null`), `processError {message}`, `terminated {exitCode}` |

`claude-stream.json` takes a line input and expects a list of claude
events, in order; an empty list means the line is ignored. Numbers are
compared as numbers, so a cost of `1` matches `1.0`. The parser reports a
control response's raw `request_id` as `action` and a `null` value; the
adapter swaps in the subtype and value it recorded. Deep lines are kept in
the file as plain strings of brackets.

`claude-stdin.json` takes `{call, text?, model?, mode?, requestID?}`, where
`call` is `send`, `interrupt`, `setModel` or `setPermissionMode`, and
expects the JSON object of the line written, compared as JSON (key order and
escaping are the writer's), or `null` when the call writes nothing. Every
line written ends with one newline and holds no other.

`claude-lines.json` takes `{chunks, flush}`, a list of line inputs read
from the pipe in order and whether the stream then ends, and expects
`{lines, remainder}`: one list of strings per chunk (the lines that chunk
finishes, newline removed) and what the end-of-stream flush gives (`null`
when there is no flush or nothing was buffered). Both runners also check
that a second flush gives nothing. The 16 MiB runaway-line guard is too
large for a case and is a unit test on each side.

`claude-launch.json` takes `{model, permissionMode, effort,
resumeSessionID}` (`resumeSessionID` may be `null`) and expects the
argument list, in order.

The Swift runner is `Tests/PowerUpTests/HarnessFixtureTests.swift` (its
descriptor helpers are in `FixtureValues.swift`), and the Rust runner is
`rust/powerup-core/tests/harness.rs` (its helpers are in `tests/support`).

## `session/`: session scenarios (format 1)

Each file is one rule of the session state machine (epic #92), played
through AppState's test seam with two scripted harnesses (one standing in
for the built-in Claude adapter, one for the ACP adapter), a recording
injector standing in for the remote session, and a scripted clock. The file is named
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
| `harnessKind`, `model`, `effort`, `permissionMode` | the `AppConfig` fields of the same name. The harness kind picks which scripted adapter is the harness. Each reports the capabilities of the adapter it stands in for: `"claude"` supports effort (restart + resume), `"acp"` does not |
| `acpAgent`, `acpCustomCommand` | the ACP agent. Whenever the ACP harness is selected (here or by a `settings` step), the agent must be `"custom"`: the other agents' commands are looked up on the machine running the tests. A load error says so |
| `controlMode` | `"builtin"` or `"remote"`. In remote mode nothing is typed into a real terminal: every text and key goes to a recording injector (see `injectorCalls`) |
| `project` | `true`: a fresh project folder named `project` (written `"$project"` in expectations); default `false` (no folder chosen) |
| `lastSessionID` | the stored resumable id (it also seeds the folder's own entry, as on a real launch) |
| `controllerConnected` | `true`: a simulated pad is connected before AppState is built |

### `script`: an ordered list of steps

Each step has exactly one of these:

- `"call"`: a public AppState call. The options are `startSessionIfNeeded`
  (what app launch does), `newSession`, `sendUserText` (needs `"text"`),
  `interruptClaude`, `answerPendingPermission` (needs `"allow"`) and
  `switchProject` (the Settings recents list's Switch button; needs
  `"project"`, a folder name such as `"other"`). Project folders live in the
  sandbox, are created when first named and are written `"$<name>"` in
  expectations; `"project"` is the folder `config.project` makes.
- `"intent"`: an intent by its protocol wire name (docs/protocol.md), for
  example `approve`, `reject`, `interrupt`, `cycleEffort`, or `sendPrompt`
  with `"text"`. `showWindow` and the voice-capture intents are not
  supported here.
- `"settings"`: a Settings window edit to the harness picker, an object
  with any of `harnessKind`, `acpAgent` and `acpCustomCommand`. AppState
  picks it up in its derived-update pass, as it does in the app.
- `"harnessEvent"`: one normalized `HarnessEvent`, tagged by `type`, with
  fields named as in Swift. It comes from the adapter the config currently
  selects, unless the step names one with `"adapter": "claude"` or
  `"adapter": "acp"` (for example, a late event from an adapter a harness
  switch retired). The events:
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
  `sessionID` is tracked as one shared unknown session. A `cwd` written
  `$<name>` is that sandbox folder (`$project` is the configured one), and
  `$<name>/sub/dir` a folder below it.
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

The scripted harnesses follow the real adapters' own state: `start` makes
one starting, with the id it resumes as its session id and no model yet;
`sessionReady` makes it ready and sets its session id and model; `send`
makes it working; `turnCompleted` makes it ready again; an acknowledged
`set_model` `controlResult` sets its model; `stop` stops it; and `ended`
stops it and clears its session id (a dead process owns no session id).
After `stop` the Claude stand-in keeps its session id until `ended`
arrives, because the real process takes a moment to exit; the ACP stand-in
drops it at once, as the ACP adapter does.

### `expect`: facts checked after the script (each key optional, at least one)

| Key | Checks |
| --- | --- |
| `harnessCalls` | every call AppState made on either scripted harness, in one ordered log with an exact count. `adapter` (`claude` or `acp`) is the one that received it, and `type` is one of `start {projectDir, model, permissionMode, effort, resumeSessionID, binaryPathOverride, agentCommand}`, `send {text}`, `interrupt`, `setModel {model}`, `setPermissionMode {mode}`, `respondToPermission {id, allow}` or `stop`. Only the keys you write are compared, so `"resumeSessionID": null` asserts a fresh start. |
| `transcript` | the transcript entries that appeared during the script, in order of first appearance and with an exact count: `{kind, text?}`, where kind is one of `user`, `assistant`, `tool`, `system` or `error`. A project switch swaps in the new folder's stored history: entries already seen are not counted again, but the "Earlier conversation restored" marker on top of it is new |
| `errorShown` | whether any `error` entry was appended |
| `lastSessionID` | the stored resumable id (a string, or `null` for none) |
| `liveSessionID` | the session id the running harness owns, sent to protocol clients as `sessionID` (a string, or `null` when no process owns one) |
| `permissionMode` | the configured permission mode |
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
