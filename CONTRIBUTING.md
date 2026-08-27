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

- **Never** touch the real `~/.claude/settings.json` in tests. `HookInstaller`
  takes an injectable `settingsURL` and has a `supportDirectoryOverride` test
  seam — see `Tests/PowerUpTests/HookInstallerTests.swift` for the pattern.
- **Never** run `cmux send`/`send-key` against real workspaces. Read-only cmux
  commands are fine; live round-trips go through a disposable workspace only.
- Don't spawn real `claude` processes in tests. The stream parser is testable
  directly via `ClaudeService.events(fromLine:)` — and the existing parser
  tests pin CLI quirks that were verified live; if the CLI changes behavior,
  update the tests *and* DESIGN.md together.

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
- Be kind. The project follows the Contributor Covenant; hands-free tooling
  exists in large part for accessibility, and this community should be at
  least as accessible as the software.

## A note on AI-assisted contributions

This project is itself substantially built with AI coding tools — that's not
just allowed, it's on-brand. Two asks: (1) you are responsible for
understanding and testing what you submit, whoever typed it; (2) disclose
heavy AI assistance in the PR description when it matters (e.g., large
generated changes), so reviewers know where to look harder.
