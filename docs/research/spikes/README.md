# Stage 1 spikes (epic #95)

Time-boxed experiments from `PLAN-any-device-any-os.md` stage 1, step 8. Each spike has a
record (question, method, exact commands, versions, raw observations, verdict,
consequence) and, where it needs code, a kit directory next to it. Spike code is
throwaway: it is never built by `swift build` and never ships in the app.

| Spike | Ticket | Record | Kit | Status |
|---|---|---|---|---|
| S7 Linux compile of the Swift sources | #137 | [s7-linux-compile.md](s7-linux-compile.md) | [s7-linux-compile/](s7-linux-compile/) | DONE (informational) |
| S1 macOS light bar, adaptive triggers, haptics | #136 | [s1-macos-light-bar.md](s1-macos-light-bar.md) | [s1-macos-light-bar/](s1-macos-light-bar/) | PENDING: maintainer's Mac + DualSense |
| S6 Claude Code on native Windows | #133 | [s6-windows-claude-code.md](s6-windows-claude-code.md) | [s6-windows-claude-code/](s6-windows-claude-code/) | PENDING: Windows 11 + Claude Code |
| S4 Rust controller stack on Windows | #134 | [s4-windows-controller.md](s4-windows-controller.md) | [s4-windows-controller/](s4-windows-controller/) | PENDING: Windows 11 bare metal + DualSense |
| S5 Windows speech engines | #135 | [s5-windows-speech.md](s5-windows-speech.md) | [s5-windows-speech/](s5-windows-speech/) | PENDING: Windows 11 + microphone + maintainer's voice |

Suggested order on Windows: S6 first (it decides native Windows versus WSL2), then S4
and S5. [`windows-common/collect-versions.ps1`](windows-common/collect-versions.ps1)
prints the versions table rows all three Windows records ask for.

When every record has a verdict, #137 folds them into the plan's stage 3 assumptions and
ADRs 0007 and 0011 in one pull request.
