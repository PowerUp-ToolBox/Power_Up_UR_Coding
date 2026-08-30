# 7. Cross-platform stack: Rust core + Tauri v2

Date: 2026-08-30

## Status

Proposed (resolves #49)

## Context

M4 needs DualSense-parity on Windows and Linux/X11. DEVELOPMENT.md assessed
four stacks: Electron (mature, but 150 MB+ bundles and a Node runtime for an
app whose core is device I/O), Flutter (rejected — desktop device APIs
immature, Dart isolates awkward for HID), Wails (rejected — Go core would
duplicate the protocol/device work Rust crates already serve), and Rust core
+ Tauri v2 (2–20 MB bundles, one core reusable by the CLI, plugins, and the
server, first-class SDL3/hidapi/tokio crates).

## Decision

The cross-platform app is a **Rust core with a Tauri v2 shell**. The core is
a cargo workspace (`powerup-protocol`, `powerup-core`, `powerup-server`,
`powerup-harness`, `powerup-devices`) that implements protocol spec v0
verbatim and consumes the ADR 0006 device schema — a second client of the
existing contracts, never a second source of truth. Harness access is ACP
(ADR 0004); the hand-rolled Claude stream-json parser is deliberately not
ported (fallback scope: #89).

**Electron is the documented fallback**, triggered only if Tauri cannot
deliver a concrete blocker — tray + global-shortcut behavior on all three
OSes, or WebView parity on Linux — after a time-boxed spike, recorded here
as an amendment if it happens.

## Consequences

- A CI bundle-size budget guards the core argument vs Electron (#81); every
  added crate is justified in its PR.
- The 3-OS build matrix (#81), license/GPL gate (#82), and the shared
  Swift↔Rust conformance suite (#80) exist from the first workspace commit.
- Windows ships before Linux (#43 via Azure Artifact Signing, then #29);
  voice arrives per ADR 0011.
- The Swift app's coexistence is ADR 0008's decision, not this one's.
