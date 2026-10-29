# Shared fixtures

Language-neutral test data that every implementation of PowerUp's rules is
checked against (PLAN-any-device-any-os.md, ADR 0012): the Swift app's XCTest
suites play every file, and the Rust core's `cargo test` plays the areas whose
rules it owns so far (`mapping/` and `device/`, since slice 2.2,
`harness/`, `status/` and `session/`, since slice 2.3, the ACP tables
of `harness/`, since slice 2.4, and `config/`, `transcript/`,
`hooks/`, `text-safety/` and `speech/`, since slice 2.5) and checks the
format of the rest, picking up
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
  `status/`, `mapping/`, `device/`, `harness/`, `config/`, `transcript/`,
  `hooks/` and `speech/` (case tables).
- Plain JSON only, with no comments and no implementation-specific shapes.
  The one exception is `harness/acp-mock-agent.py`, the scripted ACP agent
  both suites run as a process (see [the ACP adapter](#harness-the-acp-adapter)):
  the JSON loaders list only `.json` files, so it is invisible to them.
- Every file starts with a header and gives a `reason` for each thing it
  pins. There are two formats:
  - Session scenarios (`session/`) use `formatVersion`, `name`,
    `description`, `reason` (why the rule exists), `source` (where the rule
    is written down) and `verifiedBy` (the implementations that run it, for
    example `["swift"]`). See [`session/`](#session-session-scenarios-format-1).
  - Case tables (`text-safety/`, `status/`, `mapping/`, `device/`, `harness/`, `config/`, `transcript/`, `hooks/`, `speech/`) use `description`,
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
`CmuxReportingFixtureTests` and `StatusDerivationTests` run the files;
since slice 2.5 the first two play `text-safety/` through the bridge
(`CoreBridgeTextSafety.swift`) into the core, which owns the rules. The Rust
core plays `status/` in `rust/powerup-core/tests/status.rs` (slice 2.3)
and `text-safety/` in `rust/powerup-core/tests/text_safety.rs` (slice
2.5), one test per table; it also checks on every case that the segments
join to the flattened text and are never empty, and that a condensed line
keeps a limit of 2 or more.

```json
{
  "description": "What the rule does, precisely enough to reimplement it.",
  "function": "text_safety::condense (Swift: CoreBridge.condense(_:maxChars:)) — input {text, maxChars} in, string out",
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
`claude-stdin.json` what each call writes on its stdin,
`claude-launch.json` the argv a launch passes, and `claude-adapter.json`
the adapter's process rules: what each call, stdout event and exit does,
as the effects the platform carries out. `destructive-actions.json` holds
whether a harness permission request is destructive, so a second Approve
must confirm it. All are ordinary case tables, with these descriptors:

| Descriptor | Shape |
| --- | --- |
| line input | a string (the line as UTF-8, without its newline), or `{"hex": "<bytes>"}` for bytes that are not text, such as invalid UTF-8 |
| claude event | `{"event": <ClaudeEvent case name>}` plus Swift's field names: `ready {sessionID, model}`, `textDelta {text}`, `assistantMessage {text}`, `toolUse {name, detail}`, `turnCompleted {resultText, costUSD, isError, subtype}` (`resultText` and `costUSD` may be `null`), `controlResult {action, ok, detail, value}` (`value` may be `null`), `processError {message}`, `terminated {exitCode}` |
| harness event | the `harnessEvent` shape of [`session/`](#script-an-ordered-list-of-steps) scenarios, tagged by `type` (`sessionReady {sessionID, model}` … `ended {exitCode}`), with every optional field written (`null` when absent) |
| adapter effect | `{"effect": "publish", "state", "sessionID", "modelName", "totalCostUSD"}` (state is `stopped`, `starting`, `ready` or `working`), `{"effect": "resolveBinary", "generation", "binaryPathOverride"}`, `{"effect": "spawn", "generation", "executable", "arguments", "projectDir"}`, `{"effect": "writeStdin", "line": <the JSON object of the line>}`, `{"effect": "closeStdin"}`, `{"effect": "terminateAfterGrace", "seconds"}`, `{"effect": "emit", "event": <harness event>}` |

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

`claude-adapter.json` takes `{steps}` and plays them in order on a fresh
adapter whose request ids are `R-1`, `R-2`, …; it expects `{effects,
snapshot}`: one list of adapter effects per step, and the published state
after the last step (`{state, sessionID, modelName, totalCostUSD}`). Each
step is an object with exactly one of these shapes, every field required:

- `{"start": {projectDir, model, permissionMode, effort, resumeSessionID, binaryPathOverride}}`
  (the last two may be `null`)
- `{"binaryResolved": <path or null>}`, `{"spawned": true}`,
  `{"spawnFailed": {executable, description}}`, all for the current launch
- `{"send": <text>, "processRunning": <bool>}`,
  `{"interrupt": true, "processRunning": <bool>}`,
  `{"setModel": <model>, "processRunning": <bool>}`,
  `{"setPermissionMode": <mode>, "processRunning": <bool>}`, where
  `processRunning` is the platform's answer for the current process
- `{"stop": true}`
- `{"line": <line input>}`: parsed as in `claude-stream.json`, then fed
  event by event to the current launch; the step's effects are the
  concatenation. `{"retiredLine": <line input>}` comes from the launch
  before it
- `{"terminated": {exitCode, clean, stderrTail}}` for the current launch and
  `{"retiredTerminated": {…}}` for the one before it
- `{"writeFailed": <description>}`

`destructive-actions.json` takes `{kind, title, detail}` (all strings)
and expects a bool. It has one case per pattern, each named `pattern`
followed by the pattern in quotes, and the Swift runner checks that count
against the pattern list.

The expectations of `claude-adapter.json` were written from
`ClaudeService.swift` rather than captured, since the Swift adapter needed a
real process. Since slice 2.3 (#152) `ClaudeService` carries out the core's
adapter effects, and the Swift runner plays the table through the bridge's
`CoreBridge.ClaudeAdapter`. `Tests/PowerUpTests/ClaudeFakeCLITests.swift`
drives the same adapter end to end, through a real pipe to a fake `claude`
script the test writes.

The Swift runner is `Tests/PowerUpTests/HarnessFixtureTests.swift` (its
descriptor helpers are in `FixtureValues.swift`; `destructive-actions.json`
is played by `DestructiveActionClassifierTests`), and the Rust runner is
`rust/powerup-core/tests/harness.rs` (its helpers are in `tests/support`).

## `harness/`: the ACP adapter

`acp-mock-agent.py` is the scripted ACP agent (JSON-RPC 2.0, one JSON
object per line over stdio): it answers `initialize`, `session/new`,
`session/prompt` (a thought, a reply chunk, a tool call and a permission
request, then the rest of the reply and the usage) and
`session/set_model`, with no real harness and no network. Run it in place
with Python 3; never copy it. Swift's `ACPAdapterIntegrationTests` drives
the app's `ACPAdapter` against it, and `rust/powerup-core/tests/acp_mock_agent.rs`
drives the core's `AcpAdapter` against it, carrying out the effects as
`ACPAdapter` does. With `--record PATH` it appends one JSON
object per line to `PATH`: `{"received": <a line it read, without the line
break>}` and `{"sent": <a line it wrote, without the newline>}`.

The ACP adapter's rules (spec #99, slice 2.4) are two case tables:
`acp-adapter.json` holds what each call, each raw stdout line of the agent,
each exit and each timer does, as the effects the platform carries out, and
`acp-agent-lines.json` what one agent line does in a ready session. They
use the line input and harness event descriptors above, and these:

| Descriptor | Shape |
| --- | --- |
| acp effect | `{"effect": "publish", "state", "sessionID", "modelName", "totalTokens"}`, `{"effect": "spawn", "generation", "executable", "arguments", "projectDir"}`, `{"effect": "writeStdin", "line": <the JSON object of the line>}`, `{"effect": "closeStdin"}`, `{"effect": "terminateAfterGrace", "seconds"}`, `{"effect": "armStartWatchdog", "generation", "seconds"}`, `{"effect": "emit", "event": <harness event>}` |
| acp step | an object with exactly one of these keys, every field required: `{"start": {projectDir, agentCommand}}` (`agentCommand` a list of strings or `null`), `{"spawned": true}`, `{"spawnFailed": {executable, description}}`, `{"send": <text>}`, `{"interrupt": true}`, `{"setModel": <model>}`, `{"setPermissionMode": <mode>}`, `{"respondToPermission": {id, allow}}` (the event id the session answers by, and whether the user approved), `{"stop": true}`, `{"line": <line input>}`, `{"retiredLine": <line input>}`, `{"terminated": {exitCode, stderrTail}}`, `{"retiredTerminated": {…}}`, `{"watchdog": true}` and `{"retiredWatchdog": true}`. The `retired` steps come from the launch before the current one; the others are for the current launch |

`acp-adapter.json` takes `{steps}` and plays them in order on a fresh
adapter (JSON-RPC ids count from 1 and are never reset); it expects
`{effects, snapshot}`: one list of acp effects per step, and the published
state after the last step (`{state, sessionID, modelName, totalTokens}`).
A `start` takes only the two fields ACP reads; a runner fills the rest of
the harness configuration with `"default"` and `null`. Written lines are
compared as JSON, since key order and escaping are the writer's; every line
ends with its only newline. A `publish` is pushed before any other effect
whenever the state changed since the last one, and at the end of a call,
so a case pins what an observer saw when each event arrived.

`acp-agent-lines.json` takes a line input and expects a list of acp
effects. Every case starts from the same handshake, which the runners
check reaches `sessionReady(s1, m1)` first: start `{projectDir
"/work/app", agentCommand ["agent"]}`, spawned,
`{"jsonrpc":"2.0","id":1,"result":{}}` and
`{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","models":{"currentModelId":"m1"}}}`.

Cases named `mock agent: …` are the exchange with `acp-mock-agent.py`:
their `line` steps are the mock's lines byte for byte, and their start
uses the command the integration tests run (`python3 acp-mock-agent.py` in
`/tmp`). `ACPAdapterIntegrationTests` and `tests/acp_mock_agent.rs` run the
mock with `--record` and check that what it sent equals those `line` steps
and what it read equals the case's `writeStdin` lines, so the table's mock
lines are the real mock's, answering the real adapter from either language.
The Rust test also checks the emitted events against the case's, and runs
the mock in a temporary project folder, which it maps onto the case's
`/tmp` in `session/new`'s `cwd`. It finds Python as `POWERUP_PYTHON`, then
`python3`, then `python`; without one it skips, except on CI. Python on
Windows ends its lines with `\r\n`: the line buffer keeps the `\r`, which the
JSON reader reads as whitespace.

The expectations were checked once, while the slice was written, against
`ACPAdapter.swift` at `dddf9c6` (the last Swift-only version) with a
throwaway differential harness that stubbed the process and the timers and
compared every written line, every event, the state each event saw and the
state after each step. That harness is not kept in the tree, so it is
provenance only, never evidence: what it checked is now carried by these
tables and their two runners. The old adapter cancelled pending permission
requests in dictionary order, so the harness compared a step's
cancellations as a set; the tables pin arrival order. The Rust runner is `rust/powerup-core/tests/acp.rs` (its helpers are
in `tests/support`); since #155 the Swift runner,
`ACPFixtureTests.testAcpAdapterTable` and `testAcpAgentLinesTable`, plays
both tables through `CoreBridge.ACPStateMachine`, the machine `ACPAdapter`
drives.

Three small tables hold the rules around the adapter, each captured by
running the Swift suite on the Swift statics before anything else read it:

- `acp-permission-choice.json` takes `{options: [{optionId, kind}], allow}`
  and expects the chosen `optionId`, or `null` when the request is answered
  cancelled.
- `acp-environment.json` takes a variable name and expects `true` when it
  is removed from the agent's environment. PATH is rebuilt by the platform
  and is never a case.
- `acp-agent-launch.json` takes `{agent, customCommand}` and expects
  `{program, arguments}` or `null`, where `program` is `"opencode"`,
  `"npx"` or `{"command": <executable as typed>}`. The platform looks up
  opencode and npx on its own install paths; the Swift runner stubs that
  lookup so every path is executable and expects the first one.

Their Swift runner is `Tests/PowerUpTests/ACPFixtureTests.swift`, and the
Rust runner is `rust/powerup-core/tests/acp.rs`.

## `config/`: config.json as the app reads and writes it

The configuration schema (spec #100, slice 2.5): `round-trip.json` loads
the bytes of a config.json and saves them again, so it pins every key's
tolerance, the corrupt-file rule, the pre-profiles backup decision and the
exact bytes of the save at once. It is an ordinary case table with one
more descriptor:

| Descriptor | Shape |
| --- | --- |
| file input | a string (the file's text as UTF-8), or `{"hex": "<bytes>"}` for a byte order mark, UTF-16 or UTF-32 text, or invalid UTF-8 |
| file lines | the expected bytes of a text file as a list of lines, joined with `"\n"`; a final `""` element would mean the file ends with a newline (config.json never does) |

`round-trip.json` takes a file input and expects `{saved, backupBeforeSave}`:
`saved` is the file lines of what the next save writes, or `null` when the
file is corrupt (the app moves it to `config.json.bak` and runs on the
defaults); `backupBeforeSave` is whether the file is first copied to
`config.pre-profiles.json` (always `false` for a corrupt file). The
comparison is byte for byte: the first case is a config.json the macOS app
wrote, which must save back unchanged. `mapping/config-load.json` keeps the
mapping subtree's own cases.

The Swift runner is `Tests/PowerUpTests/ConfigFixtureTests.swift`, and the
Rust runner is `rust/powerup-core/tests/config.rs`, which also plays
`mapping/config-load.json` through the whole config decoder.

## `transcript/`: the transcript's JSON Lines file

The per-project transcript history (spec #100, slice 2.5): how one stored
line reads (`lines.json`), how an entry is written as a line
(`encode.json`), how a whole file loads (`load.json`) and what the
project's file is called (`file-name.json`). The platform keeps the file
itself: the transcripts folder, the append, the atomic rewrite and the
standardized project path. These are ordinary case tables with two more
descriptors (and the file input of [`config/`](#config-configjson-as-the-app-reads-and-writes-it)):

| Descriptor | Shape |
| --- | --- |
| line input | one line without its LF: a string (the line as UTF-8), or `{"hex": "<bytes>"}` for a byte order mark, UTF-16 or invalid UTF-8 |
| transcript entry | `{"id", "kind", "text", "date"}`: `id` a UUID in uppercase, `kind` one of `user`, `assistant`, `tool`, `system` and `error`, `date` the seconds since 1970 as a JSON number |

`lines.json` takes a line input and expects the transcript entry it reads
as, or `null` when the line is skipped; the Swift runner compares the date
as the `Date` built from the expected seconds, since the app holds a `Date`.
`encode.json` takes a transcript entry and expects the line's exact text
(without its LF); its dates are all ones a `Date` holds exactly.
`load.json` takes `{file, maxEntries}` (`file` a file input) and expects
`{texts, rewrite}`: the texts of the entries returned, oldest first, and
whether the load rewrote the file. `file-name.json` takes a project path
that is already standardized, byte for byte (on macOS the standardized
path spells accents, voiced kana and Hangul decomposed), and expects the
file name.

The Swift runner is `Tests/PowerUpTests/TranscriptFixtureTests.swift`,
which plays every table through `TranscriptStore` in a temporary support
directory, and the Rust runner is `rust/powerup-core/tests/transcript.rs`.

## `hooks/`: the Claude Code hooks in settings.json

The hooks PowerUp registers in `~/.claude/settings.json` (spec #100, slice
2.5): the command registered for the hook script (`command.json`), the
script itself (`script.json`), installing (`install.json`) and removing
(`uninstall.json`) the hooks, and whether they are installed as the app
runs now (`install-state.json`). The platform keeps the files: the
settings path and its test seam, reading it, the numbered backup, the
atomic write and the script's own file and mode. Every input names the
hook script's path; the tables use
`/tmp/PowerUp Hook Fixture/support/powerup-hook.sh` (a space, as the real
Application Support path has) and a path with a single quote. These are
ordinary case tables with the file input and file lines of
[`config/`](#config-configjson-as-the-app-reads-and-writes-it) (a file
input may also be `null`: no file) and two more descriptors:

| Descriptor | Shape |
| --- | --- |
| settings edit | `{"outcome": "write", "file": <file lines>}` (what the app writes: JSONSerialization with `.prettyPrinted`, `.sortedKeys` and `.withoutEscapingSlashes`, plus a newline), `{"outcome": "unchanged"}` (nothing is written and no backup is taken), or `{"outcome": "refused", "refusal": "invalidJSON"}`, `{"outcome": "refused", "refusal": "hooksNotAnObject"}`, `{"outcome": "refused", "refusal": "eventNotAnArray", "event": <name>}` (the file is left as it is) |
| script on disk | a file input, `{"scriptFor": {"port", "token"}}` (the body `script.json` pins for them), `{"scriptForWithoutTrailingNewline": {"port", "token"}}` (that body without its last byte), or `null` (no script) |

`command.json` takes a script path and expects the command string.
`script.json` takes `{port, token}` and expects the script's file lines.
`install.json` and `uninstall.json` take `{settings, scriptPath}`
(`settings` a file input) and expect a settings edit. `install-state.json`
takes `{settings, scriptPath, scriptOnDisk, port, token}` and expects
`{installState, isInstalled}`, `installState` one of `notInstalled`,
`installed` and `outOfDate`.

The Swift runner is `Tests/PowerUpTests/HookFixtureTests.swift`, which
compares every written file byte for byte. The Rust runner is
`rust/powerup-core/tests/hooks.rs`; the core hands back compact JSON for
the platform's writer, so it compares that with the file as JSON: numbers
by value, members in any order, and each string read back as Foundation
reads it (one leading U+FEFF dropped).

## `speech/`: the spoken text, its language and spoken summaries

What PowerUp reads aloud and in which language (spec #100, slice 2.5,
ticket #160): the spoken text of a markdown reply (`speech-text.json`),
that text with the language its phrases and voice are chosen for
(`spoken-reply.json`), the language decision's gates (`language.json`),
the language a voice is routed for when a caller pins one
(`voice-language.json`), and the pure rules of spoken summaries: when a
reply is summarized (`summary-threshold.json`), whether the summarizer's
answer is spoken (`summary-acceptance.json`) and the prompt it is given
(`summary-prompt.json`). The platform keeps the speech engine, the voices
(which installed voice serves a language, and the simplified or
traditional Chinese region), audio routing and the summarizer process.
Every expected value was captured from the Swift app, including its
NLLanguageRecognizer answers, so the tables say what the app does, not
what a rule should do. These are ordinary case tables with one more
descriptor:

| Descriptor | Shape |
| --- | --- |
| text | a string, or a list of strings and `{"repeat": <string>, "times": <n>}` parts joined in order (so a 2000-word reply stays one line); used for every reply, summary and spoken text |

`speech-text.json` and `spoken-reply.json` take `{text, maxChars}` and
expect the spoken text, or `{text, language}`. `language.json` takes a
string and expects a language code or `null` (undecided, which callers
read as English). `voice-language.json` takes `{text, language}`
(`language` a string or `null`) and expects the language.
`summary-threshold.json` takes `{reply, speakSummaries}` and expects a
bool, `summary-acceptance.json` takes `{summary, reply}` (`summary` may be
`null`: no answer) and expects the summary that is spoken or `null`, and
`summary-prompt.json` takes the reply and expects the whole prompt.
Strings are compared scalar for scalar.

`language-agreement.json` is a corpus of natural sentences, each named
after its kind (`en: …`, `cs: …`, `zh-Hant: …`, `mixed: …`, `short: …`,
`code: …`, `fullwidth: …` for full-width forms around few CJK letters,
`script: …` for text mixing CJK scripts, `han: …`, `gate: …`, and
`unlisted: …` for a language the core cannot name; a sentence in a
language the core can name is named after that language). The language
decision is the one rule two libraries can legitimately disagree on (ADR
0011): the Swift app asks NLLanguageRecognizer, the Rust core its own
detector, both under the letter gate of `language.json`. Its input is a
string and its expected value is `{"swift": <code or null>}`, the
decision the Swift app made, and each reason gives the recognizer's
answer, confidence and letter count. A core decision that differs is
either resolved toward the Swift one or recorded as an accepted
difference: the expected value gains `"core": <code or null>`, the reason
says why the difference is accepted, and the ledger names it. No other
key is allowed in an agreement expectation.

The core's detector is whatlang, restricted to the languages
NLLanguageRecognizer can answer. Its confidence is no probability and is
often high for a wrong answer on short prose, so the core admits a Latin-
or Cyrillic-script answer only when the text's letters fit the answer's
alphabet and its function words point to the answer alone (HK-425), and
an answer in another script with a confidence above 0.59 on whatlang's
scale (HK-421, where Swift's gate is 0.7 on the recognizer's); whatlang's
zh, ja or ko is a count of scripts, not a statistical answer, so the core
decides CJK by the script rule of `language.json` alone: see
`rust/powerup-core/src/speech/language.rs` and `evidence.rs`.
`language.json` holds only texts on which the two decide alike, so it
pins the gates themselves; a text on which they cannot agree belongs in
`language-agreement.json` with its difference recorded. An accepted
difference is of one of three kinds: the core undecided, so the reply
reads in English (HK-425 where the evidence backs no answer, HK-421
where an answer in another script is under the confidence gate, HK-422 for a language whatlang or the recognizer cannot name, HK-423 for
text with no CJK script but full-width forms); CJK text the core decides
by its script where the recognizer named another CJK language (Han-only
Japanese reading as Chinese, HK-420; a quoted kana word deciding
Japanese, hangul deciding Korean, HK-423), which the Rust runner checks
is the script rule's answer; or the language a sentence is written in,
the one its case is named after, where the recognizer named another or
was undecided (Russian the recognizer read as Kazakh, HK-425). Both
runners reject any other kind in the table, so on these sentences the
core names no language outside CJK the app did not unless it is the
sentence's own; that holds for the corpus and the differentials of
DESIGN v2.14 D, not for every text, and a sentence on which it fails
belongs here with its fix. The corpus holds 364 sentences, at least four
of every Latin- and Cyrillic-script language the core can name and of
eleven languages whose script the confidence gate decides (ar, ur, hi,
mr, he, el, th, ka, hy, bn, ta), terse English code-review prose,
English quoting accented loanwords and terse English status lines whose
acronyms, joined tokens, digits and labels are no words among the
English ones, replies in other languages naming a person, a street or a
loanword with a letter their alphabet does not write, and 85 accepted
differences, counted by the ledger rows their "Accepted difference"
clause cites: 4 of HK-420; 10 of HK-423; 4 of HK-421; 11 of HK-422, 3 of
them alone, 2 with HK-425 and 6 with HK-421; and 56 of HK-425, one of
those with HK-424.

The Swift runner is `Tests/PowerUpTests/SpeechFixtureTests.swift`, which
plays every table through the bridge (`CoreBridgeSpeech.swift`), compares
an agreement case with `expected.core` where it records one and
`expected.swift` everywhere else, and also checks that the truncation
cases cover every sentence ender, a hard cut and a multi-scalar Character
at the cut, that the agreement corpus holds at least 340 sentences with
every kind, every Latin- and Cyrillic-script language the core can name
and the eleven languages of the confidence gate's scripts represented,
and that each recorded difference is real and of an accepted kind. The Rust runner
is `rust/powerup-core/tests/speech.rs`, one test per table; it compares
`expected.core` where an agreement case records one and `expected.swift`
everywhere else, and checks that a recorded difference still differs and is of an
accepted kind.

## `session/`: session scenarios (format 1)

Each file is one rule of the session state machine (epic #92), played
through AppState's test seam with two scripted harnesses (one standing in
for the built-in Claude adapter, one for the ACP adapter), a recording
injector standing in for the remote session, and a scripted clock. The file is named
`<name>.json`. To pin a new session rule, add a scenario here rather than
writing a bespoke test. The Swift runner is
`Tests/PowerUpTests/SessionScenario.swift`, and the table test is
`SessionScenarioTests`. The Rust core plays every scenario on its session
machine (slice 2.3): the runner is `rust/powerup-core/tests/support/scenario.rs`
and the table test `rust/powerup-core/tests/session.rs`, which also checks
that every scenario lists `"rust"` in `verifiedBy`. A new scenario must pass
in both, so write it against the Swift app first (its behaviour is the
reference) and then run `cargo test`.

```json
{
  "formatVersion": 1,
  "name": "resume-failure-retried-once-without-resume",
  "description": "What happens, in one or two sentences.",
  "reason": "Why the rule exists (the failure it prevents).",
  "source": "DESIGN.md section / code location",
  "verifiedBy": ["swift", "rust"],
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
| `lastAssistantReply` | the reply Replay Last Reply speaks (a string, or `null` when there is none yet): a successful built-in turn's result text, or a focused remote session's Stop reply without its folder label |
| `injectorCalls` | everything remote mode delivered into the remote session, in order and with an exact count: `text {text, submit}` (text after line breaks are flattened; `submit` presses Enter after it) or `key {key}`, where key is `enter`, `escape` or `shiftTab` |

A failure names the scenario and its first mismatched expectation. For
example: `[resume-failure-retried-once-without-resume] (….json)
expect.harnessCalls[1].resumeSessionID: expected "stale-session-id", got null`.
