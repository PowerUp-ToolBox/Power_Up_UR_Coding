# 9. Wayland stance: portal-first, consented uinput fallback, honest degradation

Date: 2026-08-30

## Status

Proposed (resolves #53)

## Context

Wayland has no XTEST equivalent by design: silent global keystroke injection
does not exist. The available paths are the XDG RemoteDesktop portal
(compositor-mediated consent dialogs; support varies across GNOME, KDE, and
wlroots), raw uinput (requires group membership or elevated udev rules and
types at the kernel level), and pretending — promising parity we cannot
deliver. On Linux, the cmux control socket needs no injection at all and is
the preferred target when present.

## Decision

**Portal-first.** Keystroke injection on Wayland uses the XDG RemoteDesktop
portal (`ashpd`) as the primary path. **uinput is an explicit opt-in
fallback** behind its own consent flow that states exactly what it grants —
never a silent default. Capability is detected at runtime; when neither path
is available, PowerUp degrades with an actionable message (and steers toward
cmux-socket control) instead of failing quietly. Documentation says plainly
that full X11-style parity on Wayland is not achievable and why.

## Consequences

- Manual QA across GNOME/KDE/wlroots portals is budgeted per release; the
  consent UX is part of the product, not a chore.
- The parity checklist (#88) records Wayland as degraded-by-design, so the
  ADR 0008 flip is not blocked on an impossible bar.
- If portals gain a persistent-authorization path later, this ADR is amended
  rather than silently exceeded.
