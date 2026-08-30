# 6. Device/control model: serializable profiles at the model layer

Date: 2026-08-30

## Status

Proposed (gates #14; consumers: #63, #67, #70, #31, the M7 phone track, the
M4 Rust core)

## Context

Today the mapping is `ControllerButton → ControllerAction`: a DualSense-shaped
enum wired to GameController-framework types. Every planned input surface
breaks that shape — headset media keys, foot pedals, macropads, Stream Decks,
and remote/virtual devices registering over the protocol — and the M4 Rust
core plus the phone client must consume the same model without Swift in the
loop. Widening the enum per device means N enums and a mapping editor
hardcoded to each; putting the model in framework types means it can never
cross the wire.

## Decision

The mapping model becomes **data, not types**, defined at the model layer as
Codable structs mirroring a published JSON schema (#71):

- **`DeviceProfile`** — `id` (string, e.g. `"dualsense"`), `displayName`, and
  an ordered list of controls.
- **`ControlDescriptor`** — string `id` (e.g. `"cross"`, `"pedal-1"`), `kind`
  (`button` | `hold` | `axis` | `key`), `displayName`, `symbolName`,
  capability hints.
- **`DeviceMapping`** — `[controlId: intentName]`, stored per profile id in
  `AppConfig`.

Input services emit `(profileId, controlId, phase)` events; one mapper
resolves them through the per-profile mapping to **existing intents only**
(the `IntentMapper` allowlist stays the single reviewed chokepoint). The
DualSense ships as the first built-in profile carrying today's controls and
their display metadata; legacy `config.json` mappings migrate losslessly with
a backup written first (#63). Push-to-talk is level-triggered and owned by
whichever device asserted it (last assert wins, release by owner).

Nothing in the serialized form uses Swift-only constructs — no enums with
associated values, no GameController types — so the identical schema serves
protocol `registerDevice` (#67), bundled HID profile files (#70), the phone,
and the Rust core.

## Consequences

- New devices become data (a profile JSON plus a service that emits control
  events), not enum surgery; the mapping editor renders any device from
  `ControlDescriptor` metadata (#31).
- DESIGN.md gains an addendum with the new cross-module signatures, and the
  migration is pinned by a fixture test — a botched rewrite silently loses
  user bindings, so the fixture and pre-migration backup are part of the
  contract.
- Virtual devices can only reach existing intents; nothing in this model can
  mint an intent or touch the fixed permission cycle.
- The schema must freeze (versioned draft) before the Rust core's controller
  service starts, or M4 inherits churn.
