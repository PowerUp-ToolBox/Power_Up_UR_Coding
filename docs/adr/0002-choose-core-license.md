# 2. Choose the core license: Apache-2.0

Date: 2026-08-27

## Status

Accepted

## Context

PowerUp is opening up for outside contribution (DEVELOPMENT.md, milestone M1)
and needs a license before any launch announcement. Constraints:

- The roadmap touches physical hardware (game controllers, HID devices) and
  multiple AI vendors' harnesses — a surface where an explicit **patent grant**
  has real value. MIT has none.
- Planned optional dependencies are license-diverse: SDL (zlib) and
  whisper.cpp (MIT, *if built without its FFmpeg flag*) are permissive, but
  Piper TTS is now GPL-3.0 (the MIT repo is archived) and espeak-ng is
  GPL-3.0. Copyleft at the core would conflict with the goal of maximal
  community and downstream adoption; permissive-at-core with isolated GPL
  subprocesses does not.
- The project wants low contribution friction (DCO, not CLA), which means the
  license must be one contributors can accept implicitly per-commit.

Options considered: MIT (no patent grant), Apache-2.0 (patent grant +
retaliation clause, NOTICE requirement), MPL-2.0 (file-level copyleft; more
friction for casual contributors), GPL/AGPL (would propagate to anything
linking us and complicate commercial adoption of the protocol/SDKs).

## Decision

The PowerUp codebase is licensed under **Apache-2.0**, with a `NOTICE` file
("The PowerUp Authors"). GPL-licensed engines (e.g. Piper, espeak-ng) may only
ever be integrated as optional, separately-installed external subprocesses —
never linked, never bundled — and any such boundary gets documented in a
`LICENSE-THIRD-PARTY.md` when the first one lands.

## Consequences

- Contributors certify provenance via DCO sign-off; no CLA, no relicensing
  rights accumulate to anyone.
- The patent grant and retaliation clause protect users and contributors on
  the hardware/harness surface.
- Downstream commercial or proprietary use is allowed, which is intended: the
  device/harness protocol should spread.
- Relicensing later becomes effectively impossible once external contributions
  accumulate — this decision is durable by design.
- whisper.cpp must never be built with its FFmpeg integration flag in any
  build we distribute (GPL-2.0 taint on that path).
