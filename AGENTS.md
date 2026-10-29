# AGENTS.md

Guidance for AI coding agents working on this repository. It carries the same
rules as CLAUDE.md (which Claude Code reads); where anything here seems to
disagree with DESIGN.md, DESIGN.md wins.

PowerUp is a native macOS SwiftUI app that turns a PS5 DualSense controller
into a voice remote for coding agents — Claude Code natively, and opencode,
Codex, and other harnesses through the ACP (Agent Client Protocol) adapter.
Swift 5.9 / SwiftPM, no Xcode project, no third-party dependencies.

## Read these first

- **DESIGN.md** — the **binding implementation contract**. It specifies exact
  cross-module signatures, the verified `claude` CLI wire protocol, and default
  behavior, amended by addenda (v1.1 … v2.2; higher-numbered addenda supersede
  lower-numbered text where they conflict). Code against it exactly; don't invent, rename, or
  widen cross-module APIs. If a module needs something the contract doesn't
  provide, solve it privately inside that module's file. Protocol details
  marked "verified live" were tested against a real claude CLI (v2.1.243) —
  treat them as ground truth over intuition.
- **DEVELOPMENT.md** — the cross-platform/multi-device/multi-harness roadmap:
  milestones M1–M6, workstreams (`ws:*` issue labels), and ADR-gated open
  decisions.
- **CONTRIBUTING.md** — contributor-facing build/test/PR rules.
- **README.md** is a short front page by design; user documentation lives in
  `docs/` (getting-started, controls, voice, harnesses, remote-control,
  configuration, troubleshooting, privacy, protocol). A change that alters
  user-facing behavior must update the matching `docs/` guide in the same PR —
  never re-grow the README. ADRs live in `docs/adr/`; the glossary is
  `CONTEXT.md` — use its terms. README.md changes must
  be mirrored in README.zh-CN.md and README.ja.md (English is canonical).

## Build, test, run

```sh
./scripts/build-core.sh debug  # Rust core bridge; once, and after any rust/ change
swift build            # debug build
swift test             # unit tests — fast, no hardware, no network
./scripts/build.sh     # release build → build/PowerUp.app (assembled + signed)
open build/PowerUp.app # ALWAYS launch as a bundle — macOS TCC permissions
                       # track bundle identity; running the raw binary breaks them
```

CI (`.github/workflows/ci.yml`) runs build, tests, the bundle pipeline, and
bundle verification on every PR; green CI is a merge requirement. `dco.yml`
enforces DCO sign-offs.

## The Rust core (stage 2)

Stage 2 of `PLAN-any-device-any-os.md` moves platform-independent logic into
the Rust library `powerup-core` (ADR 0012); Swift keeps the UI and every
Apple-framework adapter.

```sh
(cd rust && cargo test && cargo clippy --all-targets -- -D warnings)
./scripts/build-core.sh debug     # bridge → rust/build/ (xcframework + Swift)
swift test                        # app tests plus Tests/PowerUpCoreTests
```

`cargo test` needs Python 3 for the mock ACP agent test
(`tests/acp_mock_agent.rs`; `POWERUP_PYTHON`, else `python3`, else
`python`); it skips without one, except on CI, where that fails.

The app always links the core (slice 2.2): `swift build` and `swift test`
need `./scripts/build-core.sh` to have run, and again after any change under
`rust/`; without `rust/build/` the manifest stops with that instruction.
Rust and a full Xcode are build requirements, and `scripts/build.sh` fails
clearly without them. CI runs the cargo job on macOS, Windows and Linux.

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
  file, its path, the atomic write and the backups.
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

## Hard constraints

- Swift 5.9 only; macOS 14.2 SDK APIs at most. `ObservableObject` +
  `@Published` everywhere (no `@Observable` macro) — a uniformity choice, not
  a per-file debate.
- Every service is `@MainActor`; background work (pipes, audio taps,
  recognition callbacks) hops to the main actor before touching published
  state or invoking contract callbacks.
- No force-unwraps of runtime-nullable things; parse CLI/hook JSON
  defensively — unknown types and fields are silently ignored, never fatal.
- No third-party dependencies. Keep user-facing strings friendly.
- The bundle ID `com.powerup.claudepad` is stable — never change it.
- The flat control-request shape `{"type":"control_request","subtype":…}`
  kills the CLI (exit 1). Always use the nested `request` envelope with a
  `request_id` (see DESIGN.md, v1.1 addendum §A).

## Repo layout

Everything lives in `Sources/PowerUp/` (one file per module) with tests in
`Tests/PowerUpTests/`. Don't add files beyond the documented layout without a
contract change.

| File | Purpose |
| --- | --- |
| `PowerUpApp.swift` | `@main` entry point, scenes, environment injection |
| `AppState.swift` | Central glue; routes inputs to the core's session rules and carries out their effects (DESIGN v2.12) |
| `Intent.swift` | High-level intent abstraction + `IntentMapper` wire conversion |
| `Models.swift` | Data model contracts (buttons, actions, config, transcript) |
| `Harness.swift` | `HarnessAdapter` protocol; `HarnessEvent`/configuration contracts |
| `ClaudeService.swift` | `claude` CLI subprocess adapter (spawn, pipes, kill grace); parsing and the adapter rules run in the core |
| `ACPAdapter.swift` | ACP agent subprocess adapter for external harnesses (opencode, Codex, …): spawn, pipes, kill grace, install paths, PATH; its rules run in the core |
| `ControllerService.swift` | DualSense input, light bar, haptics, battery |
| `SpeechService.swift` | Push-to-talk STT (AVAudioEngine + SFSpeechRecognizer) |
| `TTSService.swift` | Text-to-speech with language-aware voice selection |
| `SummaryService.swift` | Lightweight claude process that summarizes replies for TTS |
| `DestructiveActionClassifier.swift` | Thin wrapper; the destructive-action rule and pattern list live in the core |
| `ControllerSlot.swift` | Controller slot (`ControllerSlotSelector`) and hold (`HoldTracker`) value types; the rules run in the Rust core |
| `ControllerPicker.swift` | Pure rows and caption for the Settings → Devices Controller picker |
| `ViewLogic.swift` | Pure view rules extracted from MainView/ComponentViews (#126; DESIGN v2.7 §F) |
| `RemoteControlService.swift` | Routes text/keys to cmux or keyboard injection |
| `RemoteListener.swift` | Localhost HTTP listener for Claude Code hook events |
| `HookInstaller.swift` | Installs/manages hooks in `~/.claude/settings.json` |
| `PowerUpProtocol.swift` | WebSocket upgrade + JSON-RPC message handling |
| `WebSocketFraming.swift` | Pure RFC 6455 frame codec |
| `ConfigStore.swift` | Persistent config file: path, debounced atomic save, corrupt and pre-profiles backups; the schema and bytes are the core's |
| `TranscriptStore.swift` | Per-project transcript persistence (JSON Lines) |
| `MainView.swift` / `ComponentViews.swift` / `SettingsView.swift` / `MappingView.swift` | SwiftUI views |
| `CoreBridge.swift` | Imports the Rust core (with the other `CoreBridge*.swift` files, the only files that do): launch check and the device-layer wrappers (DESIGN v2.10, v2.11) |
| `CoreBridgeHarness.swift` | Bridge wrappers for the Claude harness: line parser, `LineBuffer`, stdin lines, argv, the `ClaudeAdapter` object (DESIGN v2.12) |
| `CoreBridgeSession.swift` | Bridge wrappers for the session: the `Session` object and its effects, status derivation, classifier, cycles (DESIGN v2.12) |
| `CoreBridgeACP.swift` | Bridge wrappers for the ACP harness: the `ACPStateMachine` object and its effects, the permission choice, the agent presets, the environment scrub list (DESIGN v2.13) |
| `CoreBridgeConfig.swift` | Bridge wrappers for the configuration schema: defaults, load, encode, the project bookkeeping migration, the fixed vocabularies (DESIGN v2.14) |

The Rust core lives in `rust/` (see "The Rust core" above); its bridge tests
are in `Tests/PowerUpCoreTests/`.

## Safety rails for testing and verification

- **Never** run `cmux send` / `cmux send-key` against the user's real
  workspaces. Read-only cmux commands (ping, list-workspaces, --help) are
  fine. If a live round-trip must be verified, use a disposable workspace
  (`cmux new-workspace --name powerup-test --command cat --focus false`) and
  always close it afterwards.
- **Never** modify the real `~/.claude/settings.json`, PowerUp's real
  `config.json` or `~/Library/Application Support/PowerUp/` in tests. Use the
  seams: `ConfigStore(fileURL:)`; HookInstaller's injectable `settingsURL`
  plus `settingsURLOverride` and `supportDirectoryOverride` (see
  `HookInstallerTests`); `TranscriptStore.supportDirectoryOverride`. In
  tearDown call `TestSandbox.parkOverrides()` (or
  `parkHookInstallerOverrides()` off the main actor), never `= nil`, so a
  late write cannot fall through to the real folders. `HermeticStorageTests`
  enforces this: it fails on `ConfigStore()`, `AppState()`, `= nil` resets
  or a `HookInstaller` call without `settingsURL:` anywhere in
  `Tests/PowerUpTests/`.
- Don't spawn real `claude` sessions from tests; the stream parser is
  testable via `ClaudeService.events(fromLine:)` (a wrapper over the core;
  `cargo test` plays `Tests/Fixtures/harness/`). An end-to-end test points
  `config.claudePath` at a fake CLI script it writes (`ClaudeFakeCLITests`).
- Don't spawn real ACP agents or npx bridges (opencode, `claude-agent-acp`,
  `codex-acp`) from tests or ad-hoc verification — they hit the network and
  run under the user's real agent logins. ACPAdapter is tested against the
  scripted mock agent (`Tests/Fixtures/harness/acp-mock-agent.py`, run by
  `ACPAdapterTests`; `cargo test` runs it too, `tests/acp_mock_agent.rs`); live wire shapes come from
  DESIGN.md's verified probes.
- The tests pin many wire-protocol details; update tests and DESIGN.md
  together only if the CLI genuinely changes.

## Testing AppState

AppState's orchestration rules are tested through one seam. Don't invent
another one.

- **Construct:** in a `@MainActor` XCTestCase, call
  `env = try AppStateTestEnvironment(config:)` in setUp, where `config` is
  written to a sandboxed `config.json` and nil means first launch. Then
  `let app = env.makeAppState(configStore:controller:speech:tts:claude:harness:acpHarness:remote:listener:audioDevices:transcriptStore:clock:)`,
  where every argument is optional. Call `env.tearDown()` in tearDown. The
  environment is `Tests/PowerUpTests/AppStateTestSupport.swift`. It calls the
  internal `AppState.init(configStore:…, sideEffects: [])`, so nothing
  starts: no controller, audio devices, listener port, keyboard monitor,
  terminate observer or cmux probe. The config file, the support folder and
  the Claude settings file all resolve into its temp directory.
- **Fakes:**
  - `FakeHarnessAdapter` (`harness:`). It records `calls` and emits queued
    `HarnessEvent`s synchronously via `emitNext()`, `emitAll()` and
    `emit(_:)`. Without `harness:` the environment supplies a fresh one, so
    no test can spawn a real `claude` or ACP agent. Alone it is the harness for every harness kind; with a second fake as
    `acpHarness:`, the two stand in for the Claude and ACP adapters and the
    harness kind picks between them (harness-switch tests).
  - `ScriptedSpeechEngine` (`speech: SpeechService(engine:)`). It scripts
    authorization, partials and the final transcript, and records its own
    `calls`. `holdsPermissionPrompt = true` keeps the permission prompt up
    until `answerPermissionPrompt(_:)`. `onCall` sees each call as it is
    recorded.
  - Spoken replies: pass `TTSService()` as `tts:` with
    `recordsOutput = true` set first. `speak`/`stop` go to
    `recordedOutput` and nothing is heard; a recorded `speak` sets
    `isSpeaking` until `stop()` or `finishRecordedSpeech()`.
  - Controller input needs no fake. Pass `ControllerService()` and drive
    its test hooks: `simulateConnect()`, `simulateButton(_:pressed:)` and
    `simulateDisconnect()` (a drop releases held buttons, then fires
    `onDisconnect`), or invoke `onButtonDown`, `onButtonUp`, `onDisconnect`
    and `onLowBattery` directly. With `recordsOutput = true`, light and
    haptic writes are recorded in `recordedOutput`. For two pads, connect
    twice (`simulateConnect` returns the `ConnectedController`; the newest
    is active unless `pinnedControllerID` / `config.controllerDeviceID`
    pins one), then pass `on: id` to `simulateButton`, `simulateDisconnect`
    and `simulateBattery(level:state:on:)`. `recordedWrites` names the pad
    each write went to.
  - `RecordingInjector` (`env.injector`). The environment's default
    `remote` delivers into it, so remote mode records text and keys instead
    of typing into cmux or the frontmost app. Never construct
    `RemoteControlService()` in a test (the source scan rejects it); pass
    `RemoteControlService(injector:)`. Deliver hooks through your own
    `RemoteListener()` (`listener:`) by calling `onEvent`.
  - `ManualRemoteTurnClock` (`clock:`). `advance(by:)` runs remote-turn
    expiry checks and the error haptic's second buzz (140 ms) as they fall
    due; never wait. Without `clock:` the environment supplies one that
    nobody advances.
  - Audio devices need no fake either. Pass `AudioDeviceStore()` as
    `audioDevices:`; `simulateDevices(_:)` sets the launch enumeration
    (no callback) and `simulateHotPlug(_:)` runs the hot-plug path (lists,
    then `onDevicesChanged`). See `AppStateAudioDeviceScenarioTests`.
- **Conventions:**
  - Set `config.ttsEnabled = false`, because TTS is real and would speak,
    unless the suite passes a TTS service with `recordsOutput = true`
    (then also keep `speakSummaries = false`: a summary runs a real
    `claude`).
  - Pin the mapping a test presses.
  - Set `config.projectDir` to a temp folder for any send path.
  - Keep `app` alive while driving callbacks, because they capture it
    weakly.
  - Never sleep. Wait on main-actor Tasks with the bounded `settle(until:)`
    from `AppStateTestSupport.swift`.
  - Assert on published state and on what the fakes recorded. Never assert
    on private fields or on the order of internal calls.
- **Session rules are fixtures.** These are the rules for resume, restarts,
  permissions, effort, turns and remote-mode turn tracking. Pin one by adding a JSON scenario to
  `Tests/Fixtures/session/`, named `<name>.json`, rather than writing a
  bespoke test. The format is documented in `Tests/Fixtures/README.md`.
  `SessionScenarioTests` runs every scenario through the seam. The parser is
  strict, so an unknown key is a load error. The Rust core plays the same
  files on its session machine (`cargo test`, `tests/session.rs`), and since
  slice 2.3 AppState runs those very rules through the bridge, so the Swift
  runner exercises the core too. Keep them plain JSON with the header and a
  `reason`, list `"rust"` in `verifiedBy`, and make a new one pass in both.
  `lastAssistantReply` checks the reply Replay speaks.
- **Rule: orchestration changes ship with a seam test.** Any change to an
  AppState rule, including a bug fix, comes with a test through
  `AppStateTestEnvironment` that fails without the change.

## Commits and PRs

- Sign off every commit (`git commit -s`) — DCO is CI-enforced.
- Keep PRs focused on one logical change; describe *why*, not just what.
- Add or update tests for anything in the pure-logic modules (parser, config,
  speech text, hook installer, protocol framing), and a seam test (see
  "Testing AppState") for any change to AppState's orchestration.
- Deviating from DESIGN.md must be stated explicitly in the PR along with the
  proposed contract change. Architecture-level decisions (new dependency, new
  module, protocol changes) need a short ADR in `docs/adr/` — copy the format
  of the existing ones.
