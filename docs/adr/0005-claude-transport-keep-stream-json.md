# 5. Claude built-in transport: keep raw stream-json (for now)

Date: 2026-08-27

## Status

Accepted

## Context

PowerUp's built-in mode drives Claude Code over the CLI's stream-json wire
protocol, hand-rolled and pinned by the parser test suite (behavior verified
live against claude v2.1.243). The officially supported alternative is the
Claude Agent SDK (TypeScript/Python), which wraps the same CLI; the raw wire
protocol is officially undocumented and could drift. A third path now exists:
Claude Code **via the ACP bridge** (`@agentclientprotocol/claude-agent-acp`),
verified working live on this machine (ADR 0004).

Weighing:

- The Agent SDK would add a Node or Python runtime dependency to a Swift app
  that proudly has none — a heavy price for a wrapper around the same CLI.
- The drift risk of raw stream-json is real but mitigated twice over: the
  test suite pins every quirk we depend on (breakage is detected, not
  silent), and the ACP bridge now provides a supported-shape fallback path to
  the same harness if the raw protocol ever breaks for good.
- The cross-platform core (M4, Rust) can revisit this — an SDK sidecar is a
  more natural fit there than inside the Swift bundle.

## Decision

Built-in Claude Code stays on the **hand-rolled stream-json adapter**
(`ClaudeService`), test-pinned. The **ACP bridge is the sanctioned fallback**
(selectable as a harness) rather than a replacement. Adopting the Agent SDK
is deferred to the M4 core, where a sidecar runtime is architecturally
cheap; revisit this ADR then.

## Consequences

- No new runtime dependencies; the 60+ parser tests remain the compatibility
  tripwire, and CLI updates that change the protocol must update tests and
  DESIGN.md together (existing rule).
- Claude-native capabilities ACP lacks (dollar cost, the hook taxonomy, live
  `set_model`/`set_permission_mode` control requests) keep working untouched.
- If stream-json breaks before M4, users switch the harness picker to
  "Claude Code (ACP bridge)" and keep working while the adapter is fixed.
