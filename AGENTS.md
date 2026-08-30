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
  never re-grow the README. ADRs live in `docs/adr/`. README.md changes must
  be mirrored in README.zh-CN.md and README.ja.md (English is canonical).

## Build, test, run

```sh
swift build            # debug build
swift test             # unit tests — fast, no hardware, no network
./scripts/build.sh     # release build → build/PowerUp.app (assembled + signed)
open build/PowerUp.app # ALWAYS launch as a bundle — macOS TCC permissions
                       # track bundle identity; running the raw binary breaks them
```

CI (`.github/workflows/ci.yml`) runs build, tests, the bundle pipeline, and
bundle verification on every PR; green CI is a merge requirement. `dco.yml`
enforces DCO sign-offs.

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
| `AppState.swift` | Central state machine; routes inputs through intent handlers |
| `Intent.swift` | High-level intent abstraction + `IntentMapper` wire conversion |
| `Models.swift` | Data model contracts (buttons, actions, config, transcript) |
| `Harness.swift` | `HarnessAdapter` protocol; `HarnessEvent`/configuration contracts |
| `ClaudeService.swift` | `claude` CLI subprocess driver; stream-json parser |
| `ACPAdapter.swift` | ACP adapter for external harnesses (opencode, Codex, …) |
| `ControllerService.swift` | DualSense input, light bar, haptics, battery |
| `SpeechService.swift` | Push-to-talk STT (AVAudioEngine + SFSpeechRecognizer) |
| `TTSService.swift` | Text-to-speech with language-aware voice selection |
| `SummaryService.swift` | Lightweight claude process that summarizes replies for TTS |
| `DestructiveActionClassifier.swift` | Pure classifier for actions needing confirmation |
| `RemoteControlService.swift` | Routes text/keys to cmux or keyboard injection |
| `RemoteListener.swift` | Localhost HTTP listener for Claude Code hook events |
| `HookInstaller.swift` | Installs/manages hooks in `~/.claude/settings.json` |
| `PowerUpProtocol.swift` | WebSocket upgrade + JSON-RPC message handling |
| `WebSocketFraming.swift` | Pure RFC 6455 frame codec |
| `ConfigStore.swift` | Persistent config (JSON, debounced, repairs corruption) |
| `TranscriptStore.swift` | Per-project transcript persistence (JSON Lines) |
| `MainView.swift` / `ComponentViews.swift` / `SettingsView.swift` / `MappingView.swift` | SwiftUI views |

## Safety rails for testing and verification

- **Never** run `cmux send` / `cmux send-key` against the user's real
  workspaces. Read-only cmux commands (ping, list-workspaces, --help) are
  fine. If a live round-trip must be verified, use a disposable workspace
  (`cmux new-workspace --name powerup-test --command cat --focus false`) and
  always close it afterwards.
- **Never** modify the real `~/.claude/settings.json` in tests. HookInstaller
  takes an injectable `settingsURL` and has a `supportDirectoryOverride` test
  seam — use both (see `HookInstallerTests`), so a live PowerUp installation
  is never touched.
- Don't spawn real `claude` sessions from tests; the stream parser is
  testable via `ClaudeService.events(fromLine:)`.
- Don't spawn real ACP agents or npx bridges (opencode, `claude-agent-acp`,
  `codex-acp`) from tests or ad-hoc verification — they hit the network and
  run under the user's real agent logins. ACPAdapter is tested against the
  scripted mock agent (see `ACPAdapterTests`); live wire shapes come from
  DESIGN.md's verified probes.
- The tests pin many wire-protocol details; update tests and DESIGN.md
  together only if the CLI genuinely changes.

## Commits and PRs

- Sign off every commit (`git commit -s`) — DCO is CI-enforced.
- Keep PRs focused on one logical change; describe *why*, not just what.
- Add or update tests for anything in the pure-logic modules (parser, config,
  speech text, hook installer, protocol framing).
- Deviating from DESIGN.md must be stated explicitly in the PR along with the
  proposed contract change. Architecture-level decisions (new dependency, new
  module, protocol changes) need a short ADR in `docs/adr/` — copy the format
  of the existing ones.
