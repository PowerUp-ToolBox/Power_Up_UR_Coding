# 13. Three device slots, one device each, no cross-device arbitration

Date: 2026-09-17

## Status

Accepted (2026-09-17; amends the hold-semantics note in ADR 0006; replaces
the cross-device arbitration design in `PLAN-any-device-any-os.md` §5)

## Context

The plan proposed letting every connected device drive PowerUp at once, with
a first-assert-wins arbiter keyed on (profile, control), owner-only release,
and release-all on disconnect. That design has to answer who owns a hold
when two DualSenses are paired, what a losing device's release means, and
whether the arbiter key is the device kind or the instance. The maintainer's
position is simpler: the app restricts itself to one device per role, so
there is nothing to arbitrate.

## Decision

PowerUp has exactly three **slots**, each holding at most one device:

- **Controller**: the device whose controls fire actions (a gamepad, a foot
  pedal, a macropad, a phone registered as a device).
- **Input**: the microphone.
- **Output**: the speaker.

Any device not in a slot is ignored, not merged. The host computer's own
keyboard and mouse are outside this model: they always work, and in the
macOS app they are a window-local monitor, not a global device.

Within the Controller device, holds do not fight either: if a second hold
control is pressed while one hold is active, **both cancel**, the partial
capture is discarded, and the person gets a haptic or audible cue. Analog
triggers keep their existing press threshold so a brushed trigger does not
cancel a dictation.

Profiles describe kinds of devices and belong to the Controller slot only;
Input and Output are plain picks from the system's audio devices.

## Considered options

- **All devices live, arbitrated** (the plan). Rejected: three unanswerable
  edge cases for a benefit nobody asked for.
- **Second hold ignored** (ADR 0006's shipped rule). Rejected in favour of
  cancel-both, which doubles as the abort gesture.
- **One "setup" bundling all three slots** (desk / couch presets). Deferred:
  it layers on top of this decision without changing it.

## Consequences

- Control events carry a device instance id so the app can tell which
  device is in the slot; the profile id names only the kind.
- The wire protocol's future `registerDevice` makes a protocol client a
  candidate for the Controller slot; it is not live until selected.
- ADR 0006's "first-assert-wins, second press ignored" sentence is
  superseded by cancel-both.
