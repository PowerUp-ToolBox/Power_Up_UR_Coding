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

Requirements: macOS 14+, Xcode Command Line Tools (`swift build` must work).
A DualSense controller and the `claude` CLI are needed to *use* the app, but
**not** to build it or run the tests.

```sh
swift build              # debug build
swift test               # unit tests — fast, no hardware, no network
./scripts/build.sh       # release build → build/PowerUp.app (assembled + signed)
open build/PowerUp.app   # ALWAYS launch as a bundle — macOS permissions (TCC)
                         # track bundle identity; the raw binary breaks them
```

CI runs `swift build`, `swift test`, and the full bundle pipeline on every PR —
green CI is a merge requirement.

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
  directly via `ClaudeService.events(fromLine:)` — and the existing parser
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
    kind picks between them as in the app.
  - `ScriptedSpeechEngine`: pass it as
    `speech: SpeechService(engine: engine)`. You script the permission
    answer, partial transcripts and the final transcript. Set
    `holdsPermissionPrompt = true` to keep the permission prompt up until
    `answerPermissionPrompt(_:)`, so you can act while it is showing.
  - For **controller input**, pass a plain `ControllerService()`. Its
    internal test hooks stand in for a pad: `simulateConnect()`,
    `simulateButton(_:pressed:)` and `simulateDisconnect()` go through the
    same connection, de-dup and drop paths as a real pad (a drop releases
    held buttons, then fires `onDisconnect`). You can also call
    `onButtonDown`, `onButtonUp`, `onDisconnect` and `onLowBattery`
    directly. Set `recordsOutput = true` to read the light and haptic
    writes back from `recordedOutput` (they still go to a real pad).
  - **Remote mode** never types into a real terminal in a test: the
    environment's default `remote` service delivers into `env.injector`, a
    `RecordingInjector` that records every text and key (`calls`) and can
    report a scripted `failure`. Deliver Claude Code hooks by passing your
    own `RemoteListener()` as `listener:` and calling its `onEvent`.
  - **Remote-turn time:** pass a `ManualRemoteTurnClock` as `clock:` and
    call `advance(by:)` to make a silent remote turn expire. Never wait for
    it.
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
`Tests/Fixtures/README.md`. The Rust core will later run the same files, so
keep them plain JSON. CI fails if `Tests/Fixtures` is empty.

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
