# 12. One core library, one UI per OS, platform adapters at the edge

Date: 2026-09-17

## Status

Accepted (2026-09-17; supersedes ADR 0008; narrows ADR 0007; decided in a
grilling session, see `CONTEXT.md` for the vocabulary it fixes)

## Context

The goal is "any device × any OS × any harness" with the logic written
once. ADR 0008 chose to run the Swift app and a future Rust app in parallel
over the wire protocol with no FFI, sharing only the protocol and its
conformance fixtures. The maintainer's actual wish is the opposite split:
separate UI per operating system, identical logic underneath. A daemon
(`powerupd`) with the UI as a protocol client was the other candidate; on
macOS it would force Rust bindings to Apple's speech, game-controller and
audio frameworks and move TCC grants onto a helper process.

## Decision

The **core is a Rust library**, compiled into each OS app. It owns
everything that is pure logic today: intent dispatch, mappings and the hold
rule, device-slot selection, harness adapters (Claude stream-json, ACP),
session and transcript state, configuration, and the remote-control
protocol server. Each OS ships **its own UI** (SwiftUI on macOS; Tauri or
egui on Windows and Linux, chosen at the first Windows frontend) and its own
**platform adapters**: device input, speech recognition, text to speech,
audio devices, and the remote-mode injector. On macOS the adapters stay in
Swift; the core is reached through a generated bridge (uniffi is the leading
option). One process per OS.

The macOS app is **migrated module by module**, smallest pure module first,
each move gated on the core passing the same fixtures the Swift code
passes today. The UI does not change during migration; the Swift
orchestration in `AppState` is the body of work being moved.

## Considered options

- **Parallel apps over the protocol, no FFI (ADR 0008).** Rejected: logic
  written twice, and a parity treadmill the maintainer does not want.
- **Daemon plus thin UI clients.** Rejected: Apple framework bindings in Rust
  and TCC attribution on a subprocess are exactly the risks the modify-not-
  rewrite plan set out to avoid.
- **Hybrid (daemon on Windows/Linux, library on macOS).** Rejected: two
  integration shapes to maintain.

## Consequences

- ADR 0008's "no FFI" reasoning (C ABI plumbing, coupled release cadences)
  is accepted as a cost: the core and every UI release together, from one
  repository.
- Rust code runs inside the process that holds the macOS TCC grants. Panics
  must not cross the bridge; the core's public surface is total.
- The wire protocol stays for phones and other remote clients; it is no
  longer the seam between the app and its own logic.
- A first Windows frontend may be a command-line one, since remote mode
  plus hooks makes Windows usable before a GUI exists.
