# 1. Record architecture decisions

Date: 2026-08-26

## Status

Accepted

## Context

PowerUp is evolving from a single-purpose macOS app into a cross-platform,
multi-device, multi-harness project (see DEVELOPMENT.md). Several consequential
decisions are coming — license, cross-platform stack, harness abstraction,
protocol design — and the *reasons* behind such decisions are exactly what gets
lost as contributors join and documents drift. DEVELOPMENT.md §7 lists eight
open decisions that each need a recorded rationale.

## Decision

We record architecture decisions as Architecture Decision Records (ADRs) in
`docs/adr/`, numbered sequentially (`0002-…md`, `0003-…md`), using this
Nygard-style format: Title, Date, Status (proposed | accepted | superseded by
NNNN), Context, Decision, Consequences. File names are lowercase, dash
separated, imperative ("choose-core-license", not "license-was-chosen").

A decision that changes the contracts in DESIGN.md or the plan in
DEVELOPMENT.md gets an ADR *before or alongside* the change, in the same PR.

## Consequences

- The "why" behind consequential choices survives maintainer turnover and
  document rewrites.
- PRs that make architecture-level changes without an ADR can be asked to add
  one — reviewers should treat a missing ADR like a missing test.
- Superseded decisions stay in the tree, marked superseded, as history.
