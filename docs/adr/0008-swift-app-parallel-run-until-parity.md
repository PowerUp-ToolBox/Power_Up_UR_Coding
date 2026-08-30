# 8. The Swift app runs in parallel until parity, then maintenance mode

Date: 2026-08-30

## Status

Proposed (resolves #51)

## Context

Once the Rust core exists, the macOS Swift app could be rewritten as a Swift
shell over the Rust core (FFI), retired immediately, or kept as a parallel
implementation. FFI bridging pulls C ABI plumbing into both codebases and
couples release cadences; immediate retirement throws away the only mature,
TCC-hardened implementation while the new one is still proving itself.

## Decision

**Parallel-run over the protocol, no FFI.** Both apps speak protocol v0 and
share the conformance suite (#80); new features land protocol-first so both
clients inherit them. The Swift app remains the macOS flagship until the
**published parity checklist (#88)** passes — every user-visible capability,
per OS, with protocol-level equivalence — at which point it moves to
maintenance mode (security and breakage fixes only). The checklist freezes
when macOS convergence starts; the flip is executed as a consequence of this
ADR, not re-litigated.

## Consequences

- Two implementations to maintain until the flip — priced in; the protocol
  being the product's stable center makes the second client cheap.
- The parity treadmill is the main risk: features that bypass the protocol
  widen the gap. Protocol-first is the rule for anything user-visible.
- One signing pipeline (#42) serves both apps; users choose per machine
  during the overlap.
