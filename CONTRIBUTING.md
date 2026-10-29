# Contributing to PowerUp

Thanks for your interest! PowerUp is early — today it's a macOS DualSense
remote for Claude Code, on its way to becoming a cross-platform, any-device,
any-harness hands-free coding tool. That journey is mapped in
[DEVELOPMENT.md](DEVELOPMENT.md); this file covers the practical part: how to
build, test, and land changes.

## Orientation: the three documents

| Document | What it's for |
|---|---|
| [README.md](README.md) | Short front page — what the app is, quick start, doc index |
| [docs/](docs) | User guides: getting started, controls, voice, remote control, configuration, troubleshooting |
| [docs/protocol.md](docs/protocol.md) | The PowerUp protocol — the local WebSocket API for device plugins and alternative UIs |
| [DESIGN.md](DESIGN.md) | **The binding implementation contract** for the current macOS app — exact APIs, the verified Claude CLI wire protocol, behavior specs |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Where the project is going — architecture, workstreams, milestones, open decisions |

If your change alters user-facing behavior, update the matching guide in
`docs/` in the same PR — the README stays short by design.

The most important rule in this codebase: **DESIGN.md is a contract.** The
cross-module APIs and wire-protocol handling are specified exactly, and much of
it was verified against a live `claude` CLI. Don't invent, rename, or widen
cross-module APIs in a PR; if a module needs something the contract doesn't
provide, solve it privately inside that module's file, or propose a contract
amendment in the PR description.

## Building and testing

Requirements: macOS 14+, a full Xcode install (the build runs `xcodebuild`;
the Command Line Tools alone are not enough) and Rust via
[rustup](https://rustup.rs). Every build links the Rust core (below), so
build it once before the first `swift build`, and again after any change
under `rust/`. A DualSense controller and the `claude` CLI are needed to *use* the app, but
**not** to build it or run the tests.

```sh
./scripts/build-core.sh debug   # the Rust core's bridge → rust/build/
swift build              # debug build
swift test               # unit tests — fast, no hardware, no network
./scripts/build.sh       # release build → build/PowerUp.app (assembled + signed)
open build/PowerUp.app   # ALWAYS launch as a bundle — macOS permissions (TCC)
                         # track bundle identity; the raw binary breaks them
```

CI builds the Rust core, then runs `swift build` and `swift test`, the
cargo tests on macOS, Windows and Linux, and the full bundle pipeline on every PR —
green CI is a merge requirement.

### The Rust core (`rust/`)

Stage 2 of `PLAN-any-device-any-os.md` moves platform-independent logic into
`powerup-core`, a Rust library every OS app links (ADR 0012). It lives in the
cargo workspace `rust/`; the toolchain is pinned in `rust/rust-toolchain.toml`,
so [rustup](https://rustup.rs) installs the right compiler on first use.

```sh
cd rust
cargo test                                  # core tests
cargo clippy --all-targets -- -D warnings   # lints; unwrap/expect are denied in library code
```

`cargo test` runs the scripted ACP agent (`tests/acp_mock_agent.rs`) with
Python 3: `POWERUP_PYTHON`, else `python3`, else `python`. Without one it
skips that test with a note; on CI (`CI` set) a missing Python fails it.

The rules for core work:

- **Workspace.** `rust/` holds `powerup-core` (the logic), `powerup-core-ffi`
  (the uniffi bridge the macOS app links) and `uniffi-bindgen` (generates the
  Swift side). The compiler is pinned in `rust/rust-toolchain.toml`.
- **What lives there.** The device layer (intents, actions, mappings,
  profiles, the Controller slot rule and the hold rule) lives in
  `powerup-core` since slice 2.2; the app reaches it only through
  `CoreBridge.swift` (DESIGN v2.11). Since slice 2.3 it also holds the
  Claude adapter's rules (`harness::claude`: the stream-json parser, the
  stdout line splitter, the stdin lines, the launch argv and the process
  rules, played against `Tests/Fixtures/harness/`), the session state
  machine with remote mode (`session`, played against every
  `Tests/Fixtures/session/` scenario), the status derivation (`status`,
  against `Tests/Fixtures/status/`) and the destructive-action classifier
  (`harness::destructive`), reached through `CoreBridgeHarness.swift` and
  `CoreBridgeSession.swift` (DESIGN v2.12). The core returns effects and
  the platform carries them out in order (CONTEXT.md, "Effect"):
  ClaudeService owns the process and pipes, AppState the adapters,
  config, transcript, speech and remote injector. Since slice 2.4 it also
  holds the ACP adapter's JSON-RPC rules, the agent presets and the
  environment scrub list (`harness::acp`, DESIGN v2.13), played against
  `Tests/Fixtures/harness/acp-*.json` and the scripted mock agent and
  reached through `CoreBridgeACP.swift`; ACPAdapter owns the agent
  process, its pipes and timers, the install paths and PATH. Since slice
  2.5 it also holds the configuration schema (`config`: the defaults, how
  config.json's bytes read, as `JSONDecoder` reads them, and the bytes it is
  saved as, as `JSONEncoder` writes them; `json::decoder` and
  `json::encoder`), played against `Tests/Fixtures/config/` and reached
  through `CoreBridgeConfig.swift` (DESIGN v2.14); ConfigStore keeps the
  file, its path, the atomic write and the backups. It also holds the
  transcript's JSON Lines (`transcript`: the line an entry is written as,
  how a file's bytes load and compact, and each project's file name),
  played against `Tests/Fixtures/transcript/` and reached through
  `CoreBridgeTranscript.swift`; TranscriptStore keeps the folder, the
  append, the atomic rewrite and the standardized project path.
- **Panic rule.** Every public core function is total: it returns its
  value, or a `Result` when it can fail, and never panics. Library code
  never calls `unwrap`, `expect` or `panic!` (clippy denies the first two).
  The one exception is the bridge probe `probe::panic_with`, which exists to
  test the boundary. The bridge runs every call inside `catch_unwind`, so a
  core panic reaches Swift as `CoreBridgeError.Panicked`, never as a crash;
  this needs the default `panic = "unwind"`, so no Cargo profile may set
  `panic = "abort"`.
- **Fixture rule.** Core tests read the shared `Tests/Fixtures/` in place
  (`rust/powerup-core/tests/support`), never a copy. A slice ports a rule by
  making its fixtures pass in Rust and recording that in `verifiedBy`: add
  `"rust"` to a session scenario's list, or name the Rust test in a case
  table's `verifiedBy` sentence.
- **Ledger rule.** `PORTING-LEDGER.md` lists the hidden knowledge the port
  must keep. A slice's PR updates the rows it owns; CI fails if any row says
  todo.
- **Licenses.** `rust/deny.toml` allows permissive licenses only (MPL-2.0 for
  the uniffi crates alone). After changing dependencies, run
  `python3 scripts/third-party-licenses.py` and commit
  `rust/THIRD-PARTY-LICENSES.md`; CI fails when it is stale.

The macOS app reaches the core through `powerup-core-ffi`, a uniffi bridge.
`./scripts/build-core.sh` builds it into `rust/build/` (an xcframework plus
the generated Swift), and the app always links it:

```sh
./scripts/build-core.sh debug   # or release; scripts/build.sh runs it for you
swift build                     # the app with the core
swift test                      # also runs Tests/PowerUpCoreTests (the bridge)
```

Without `rust/build/`, `swift build` stops with a message telling you to run
`./scripts/build-core.sh`. `scripts/build.sh` builds the core itself and
fails clearly when Rust or a full Xcode is missing, and the app
logs `Rust core linked and answering` (subsystem `com.powerup.claudepad`,
category `core`) at launch.

### Testing rules (please read — these protect real user machines)

- **Never** touch the real `~/.claude/settings.json`, PowerUp's real
  `config.json` or its Application Support folder in tests. Every storage
  path has a seam: `ConfigStore(fileURL:)`, `HookInstaller`'s injectable
  `settingsURL` plus `settingsURLOverride` / `supportDirectoryOverride`, and
  `TranscriptStore.supportDirectoryOverride`. In tearDown, park the
  overrides with `TestSandbox.parkOverrides()` rather than setting them back
  to nil. `HermeticStorageTests` checks every path resolves into a temp
  directory and scans the test sources for `ConfigStore()`, `AppState()`,
  `= nil` resets and `HookInstaller` calls without `settingsURL:`.
- **Never** run `cmux send`/`send-key` against real workspaces. Read-only cmux
  commands are fine; live round-trips go through a disposable workspace only.
- Don't spawn real `claude` processes in tests. The stream parser is testable
  directly via `ClaudeService.events(fromLine:)` (a wrapper over the core;
  `cargo test` plays `Tests/Fixtures/harness/`), and an end-to-end test
  points `config.claudePath` at a fake CLI script it writes
  (`ClaudeFakeCLITests`) — and the existing parser
  tests pin CLI quirks that were verified live; if the CLI changes behavior,
  update the tests *and* DESIGN.md together.

### Testing AppState (orchestration)

`AppState` holds the app's orchestration rules: what a button press does,
what happens when the controller drops mid-hold, when a permission request
arrives, when a turn ends. Test those rules through the AppState seam, the
only one there is:

```swift
@MainActor
final class MyScenarioTests: XCTestCase {
    private var env: AppStateTestEnvironment!

    override func setUpWithError() throws {
        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false            // TTS is real; keep the run silent
        config.mapping[.cross] = .approve    // pin what the test presses
        env = try AppStateTestEnvironment(config: config)
    }

    override func tearDownWithError() throws { env.tearDown() }

    func testCrossApprovesThePendingPermission() {
        let controller = ControllerService()
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, harness: harness)
        // ... drive the scenario, then assert on app's published state and on
        // harness.calls
    }
}
```

- `AppStateTestEnvironment` (`Tests/PowerUpTests/AppStateTestSupport.swift`)
  builds AppState with `sideEffects: []`, so nothing is started: no
  controller, audio device list, listener port, keyboard monitor, terminate
  observer or cmux probe. It points the config file, the support folder and
  the Claude settings file at a temp directory. Every collaborator of
  `makeAppState(...)` is optional. Pass your own instance when you need a
  handle on it.
- **Fakes:**
  - `FakeHarnessAdapter`: pass it as `harness:`. It records every call
    (`calls`) and emits scripted `HarnessEvent`s when you call
    `emitNext()`, `emitAll()` or `emit(_:)`. Alone, it is the harness
    whatever the harness kind says. To test a harness switch, pass a second
    one as `acpHarness:`; then `harness:` stands in for the built-in Claude
    adapter, `acpHarness:` for the ACP adapter, and the config's harness
    kind picks between them as in the app. Without `harness:` the
    environment supplies a fresh fake, so a test can never spawn a real
    `claude` or ACP agent.
  - `ScriptedSpeechEngine`: pass it as
    `speech: SpeechService(engine: engine)`. You script the permission
    answer, partial transcripts and the final transcript. Set
    `holdsPermissionPrompt = true` to keep the permission prompt up until
    `answerPermissionPrompt(_:)`, so you can act while it is showing.
    Its `onCall` closure sees each call as it is recorded, so you can
    check what another fake had recorded at that moment.
  - For **spoken replies**, pass a `TTSService()` as `tts:` with
    `recordsOutput = true` set before building AppState. Then `speak` and
    `stop` are recorded in `recordedOutput` and nothing is heard: a
    recorded `speak` only marks `isSpeaking` true, until `stop()` or
    `finishRecordedSpeech()`. With it you can turn `config.ttsEnabled` on
    (keep `speakSummaries` off: a summary runs a real `claude`). See
    `AppStateVoiceModeScenarioTests`.
  - For **controller input**, pass a plain `ControllerService()`. Its
    internal test hooks stand in for a pad: `simulateConnect()`,
    `simulateButton(_:pressed:)` and `simulateDisconnect()` go through the
    same connection, de-dup and drop paths as a real pad (a drop releases
    held buttons, then fires `onDisconnect`). You can also call
    `onButtonDown`, `onButtonUp`, `onDisconnect` and `onLowBattery`
    directly. Set `recordsOutput = true` to read the light and haptic
    writes back from `recordedOutput` (they still go to a real pad).
    For the Controller slot (DESIGN v2.7 B), call `simulateConnect` more
    than once: it returns the `ConnectedController`, the newest is active
    in Automatic, and `pinnedControllerID` (or the config's
    `controllerDeviceID`, which AppState syncs) pins one.
    `simulateButton(_:pressed:on:)`, `simulateDisconnect(_:)` and
    `simulateBattery(level:state:on:)` take a pad id (nil means the active
    one); a pad outside the slot is inert. `recordedWrites` says which pad
    each write went to. See `ControllerServiceSlotTests` and
    `AppStateControllerSlotTests`.
  - **Remote mode** never types into a real terminal in a test: the
    environment's default `remote` service delivers into `env.injector`, a
    `RecordingInjector` that records every text and key (`calls`) and can
    report a scripted `failure`. Deliver Claude Code hooks by passing your
    own `RemoteListener()` as `listener:` and calling its `onEvent`.
  - **Remote-turn time:** pass a `ManualRemoteTurnClock` as `clock:` and
    call `advance(by:)` to make a silent remote turn expire (or the error
    haptic's second buzz land). Never wait for it. Without `clock:` the
    environment uses a clock that nobody advances.
  - For **audio devices**, pass a plain `AudioDeviceStore()` as
    `audioDevices:`. Call `simulateDevices(_:)` before building AppState
    to set what the first enumeration finds (no change callback, as at
    launch), then `simulateHotPlug(_:)` to unplug or replug: it runs the
    CoreAudio listener's path (lists first, then `onDevicesChanged`). The
    engine's `startCapture` call records which input device id each
    capture used (nil is the system default).
- A good test plays one scenario through public entry points (a fake's
  callback, a public method, an intent). It asserts on published state and
  on what the fakes recorded. It never reads private fields and never
  asserts on the order of internal calls. Tests are synchronous; when
  AppState hops through a main-actor Task, wait with the bounded
  `settle(until:)` helper (in `AppStateTestSupport.swift`), never with a
  sleep.
- Keep `let app` alive while you drive callbacks, because the services hold
  AppState weakly. Set `config.projectDir` (a temp folder) when a scenario
  sends a prompt. Without it, no session starts.

**Session rules are data.** A session rule is anything that happens between
the person and the harness: resume, restarts, permissions, effort, turns,
or remote-mode turn tracking (hook events, heartbeats, expiry, focus).
Pin it by adding a JSON scenario to `Tests/Fixtures/session/` instead of
writing a bespoke test. `SessionScenarioTests` finds every file there and
plays it through the same seam with a `FakeHarnessAdapter`. A broken rule
fails with the scenario's name and its first mismatched expectation. The
format, the step vocabulary and the expectation keys are documented in
`Tests/Fixtures/README.md`. The Rust core runs the same files on its
session machine (`cargo test` in `rust/`), so keep them plain JSON, list
`"rust"` in `verifiedBy`, and make a new scenario pass in both. CI fails if
`Tests/Fixtures` is empty.

**The rule: orchestration changes ship with a seam test.** A change to a rule
in AppState must come with a test through `AppStateTestEnvironment`, and so
must a bug fix there. The test should fail without the change.

## Code conventions

- Swift 5.9 only; no APIs newer than the macOS 14.2 SDK.
- `ObservableObject` + `@Published` everywhere (no `@Observable` macro) — this
  is a uniformity choice, not a style debate to reopen per-file.
- Every service is `@MainActor`; background work hops to the main actor before
  touching published state.
- No force-unwraps of runtime-nullable values; parse all external JSON
  (CLI output, hook payloads) defensively — unknown types/fields are ignored,
  never fatal.
- No third-party dependencies in the macOS app.
- User-facing strings are friendly and jargon-light.

## Finding something to work on

- Issues labeled **`good first issue`** are curated to be genuinely small.
- Workstream labels (`ws:core`, `ws:harness`, `ws:device`, `ws:speech`,
  `ws:platform`, `ws:ux`, `ws:community`, `ws:release`, `ws:security`) map
  directly to the sections of [DEVELOPMENT.md §5](DEVELOPMENT.md#5-workstreams-and-tasks).
- Want to add a **device** or **harness**? Open an issue first — the
  device/harness plugin contracts (DEVELOPMENT.md §3.1) are being designed
  right now, and early input shapes them.

## Pull requests

1. Fork, branch from `main`.
2. Keep PRs focused — one logical change.
3. Add or update tests for anything in the pure-logic modules (parser, config,
   speech text, hook installer). New protocol quirks especially: pin them.
4. Make sure `swift test` passes and the app still builds.
5. Sign off your commits (`git commit -s`, [DCO](https://developercertificate.org)) —
   certifying you have the right to contribute the change.
6. Describe *why*, not just *what*, in the PR description. If you're deviating
   from DESIGN.md, say so explicitly and propose the contract change.

Architecture-level decisions (new dependency, new module, protocol changes)
should get a short ADR in `docs/adr/` — copy the format of the existing ones.

## Communication and expectations

- **GitHub Issues** for bugs and feature requests; **GitHub Discussions** for
  questions, ideas, and design conversations.
- This is a spare-time project. Best-effort response within a few days; a
  quiet week is not a rejection. Pinging after a week is fine and welcome.
- Be kind. The project follows the
  [Contributor Covenant 3.0](CODE_OF_CONDUCT.md); hands-free tooling exists in
  large part for accessibility, and this community should be at least as
  accessible as the software.

## A note on AI-assisted contributions

This project is itself substantially built with AI coding tools — that's not
just allowed, it's on-brand. Two asks: (1) you are responsible for
understanding and testing what you submit, whoever typed it; (2) disclose
heavy AI assistance in the PR description when it matters (e.g., large
generated changes), so reviewers know where to look harder.
