# 10. Remote-listener transport trust: pinned self-signed certificate (leaning)

Date: 2026-08-30

## Status

Proposed — gated on the iOS cert-trust spike (resolves #75; consumed by #76)

## Context

Phone control (M7) adds a second, opt-in, TLS-only listener; the loopback
listener and its static-token model never leave 127.0.0.1. The remote channel
needs mutual trust with zero third-party dependencies. Two workable options:

- **TLS-PSK** (per-device pre-shared keys via Network.framework): mutual
  authentication from byte zero, no X.509 at all. But browsers cannot speak
  PSK ciphersuites — no web/PWA clients, ever, and the reference client must
  be native.
- **Pinned self-signed certificate**: the pairing QR carries the SPKI
  fingerprint out-of-band, so there is no trust-on-first-use window; browsers
  can connect, enabling a PWA served by the Mac itself. Costs: macOS has no
  public API to mint certificates (the OS-shipped `/usr/bin/openssl` via
  subprocess is the candidate path), and iOS's trust flow for self-signed
  certs is awkward enough to need a spike before committing.

Rejected outright for either path: plaintext LAN binding, cloud relays,
short-PIN pairing via hand-rolled PAKE, and mDNS as a trust mechanism
(discovery may advertise, never authorize).

## Decision

**Leaning: pinned self-signed certificate**, because the product vision is
"people build their own apps on top" and the web is the widest on-ramp. The
decision is **gated on a spike**: an iPhone must complete QR pairing and hold
a working `wss://` connection (Safari PWA) against the Mac's pinned cert with
an acceptable one-time trust UX. If the spike fails, TLS-PSK is adopted and
the reference client becomes a thin native app; the protocol above the
transport is identical either way, so nothing else in M7 moves.

## Consequences

- #76 (the remote listener) and #78 (the reference client) are blocked until
  the spike resolves this ADR to Accepted with one option recorded.
- Either option keeps per-device identity and revocation (#74) — the
  transport authenticates the device; pairing mints its credential.
- Off-LAN access stays "bind to a VPN/Tailscale interface", documented, not
  relayed.
