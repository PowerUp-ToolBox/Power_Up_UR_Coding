# CLAUDE.md

PowerUp — a native macOS SwiftUI app that turns a PS5 DualSense controller
into a voice remote for Claude Code. Swift 5.9 / SwiftPM, no Xcode project,
no third-party dependencies.

## The documents

- **DESIGN.md** — binding implementation contract for the current macOS app.
- **DEVELOPMENT.md** — the cross-platform/multi-device/multi-harness roadmap:
  architecture direction, workstreams, milestones, open decisions (ADR-gated).
- **CONTRIBUTING.md** — contributor-facing build/test/PR rules.
- **AGENTS.md** — the same rules for AI coding agents that don't read this file.
- **README.md** is a short front page; user documentation lives in `docs/`
  (getting-started, controls, voice, harnesses, remote-control, configuration,
  troubleshooting, privacy, protocol). Feature changes must update the
  matching `docs/` guide, not re-grow the README. ADRs live in `docs/adr/`.
  README.md changes must be mirrored in README.zh-CN.md and README.ja.md
  (English is canonical).

## The binding contract

**DESIGN.md is the binding implementation contract.** It specifies exact
cross-module signatures, the verified `claude` CLI wire protocol, and default
behavior, amended by addenda v1.1–v2.2 (higher-numbered addenda supersede
lower-numbered text where they conflict). Code against it exactly; don't invent, rename, or widen
cross-module APIs. If a module needs something the contract doesn't provide,
solve it privately inside that module's file.

Protocol details in DESIGN.md marked "verified live" were tested against a
real claude CLI (v2.1.243) — treat them as ground truth over intuition. The
tests in `Tests/PowerUpTests` pin many of them; update tests and DESIGN.md
together if the CLI genuinely changes.

## Commands

```sh
swift build            # debug build
swift test             # 66+ unit tests, no hardware needed
./scripts/build.sh     # release build → build/PowerUp.app (assembled + signed)
open build/PowerUp.app # ALWAYS launch as a bundle — TCC permissions track
                       # bundle identity; running the raw binary breaks them
```

## Hard constraints

- Swift 5.9 only; macOS 14.2 SDK APIs at most. `ObservableObject` +
  `@Published` everywhere (no `@Observable` macro) for uniformity.
- Every service is `@MainActor`; background work (pipes, audio taps,
  recognition callbacks) hops to the main actor before touching published
  state or invoking contract callbacks.
- No force-unwraps of runtime-nullable things; parse CLI/hook JSON
  defensively — unknown types and fields are silently ignored.
- No third-party dependencies. Keep user-facing strings friendly.
- The bundle ID `com.powerup.claudepad` is stable — never change it.
- The flat control-request shape `{"type":"control_request","subtype":…}`
  kills the CLI (exit 1). Always use the nested `request` envelope with a
  `request_id` (see DESIGN.md v1.1A).

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
  scripted mock agent (see `ACPAdapterTests`).
