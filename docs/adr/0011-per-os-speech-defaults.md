# 11. Per-OS speech defaults

Date: 2026-08-30

## Status

Proposed (resolves #54; gates #85, #86)

## Context

macOS speech is served by SpeechAnalyzer/SFSpeech and AVSpeechSynthesizer in
the Swift app — mature, on-device, TCC-integrated. Windows and Linux (M4)
have no equivalent single stack, and ADR 0002's Apache-2.0 patent-grant
posture forbids linking GPL engines. Remote devices (M7) do their own speech
on-device and are unaffected — the wire carries text only.

## Decision

- **macOS**: Apple speech stays Swift-side, unchanged. The Rust core does not
  reimplement macOS speech.
- **Windows/Linux STT**: whisper.cpp as a subprocess over the selected input
  device — never built with the FFmpeg flag, enforced by the CI GPL gate
  (#82).
- **Windows/Linux TTS**: OS-native voices as the zero-setup default;
  Kokoro-82M as the quality option, run out-of-process. GPL engines (e.g.
  some Piper builds) are subprocess-only and opt-in, never linked.
- Code-vocabulary biasing (#22) applies per backend: contextual strings on
  Apple speech, prompt/vocabulary injection on whisper.cpp.

## Consequences

- Speech quality differs per OS and the docs say so honestly; the parity
  checklist (#88) records the deltas.
- Model downloads (whisper, Kokoro) are explicit user actions with disk-size
  shown — never silent.
- The GPL gate (#82) must merge before any speech code lands in the Rust
  workspace.
