# S6: Claude Code on native Windows

- **Spike:** S6 of `PLAN-any-device-any-os.md` stage 1, step 8; ticket #133, epic #95.
- **Status:** PENDING (needs a Windows 11 machine with Claude Code installed and logged in).
- **Time box:** 1 day. Run this one **first** of the Windows spikes: its answer decides
  whether stage 3 targets native Windows or WSL2.
- **Kit:** [`s6-windows-claude-code/`](s6-windows-claude-code/) and
  [`windows-common/collect-versions.ps1`](windows-common/collect-versions.ps1).
  The scripts were exercised on PowerShell 7.4 (Linux container) against a mock CLI and
  a temporary settings file; they have **not** yet run on Windows.

## Question

Does Claude Code on native Windows 11 behave like the macOS build PowerUp was verified
against, on the three things PowerUp depends on?

| Id | Check | What PowerUp needs |
|---|---|---|
| **K** | Keystroke injection | `SendInput` with `KEYEVENTF_UNICODE`, one down/up per UTF-16 code unit, delivers mixed text (CJK, surrogate pairs, code punctuation) plus Enter into Windows Terminal running the CLI, without splitting surrogate pairs. |
| **H** | Hooks | The five events PowerUp registers (`Stop`, `UserPromptSubmit`, `Notification`, `SessionEnd`, `PostToolUse`) fire from the **user** settings file `%USERPROFILE%\.claude\settings.json` and reach a local listener with the header **`X-PowerUp-Token: <token>`** (not `Authorization: Bearer`). |
| **S** | stream-json | `claude -p --verbose --input-format stream-json --output-format stream-json --include-partial-messages` emits `system/init`, completes a turn, and accepts the **nested** control-request envelope `{"type":"control_request","request_id":"…","request":{"subtype":"…"}}` (DESIGN.md v1.1A). |

## Before you start

- Windows 11 on the machine you will actually use; Windows Terminal; Claude Code
  installed the way a user would (record the method) and **logged in**.
- Run every script **non-elevated** (normal user). Injection across elevation levels is
  blocked by Windows (UIPI) and would fake a K NO-GO.
- Copy or clone the repository to e.g. `C:\src\PowerUp`. All commands below assume:

```powershell
cd C:\src\PowerUp\docs\research\spikes\s6-windows-claude-code
New-Item -ItemType Directory -Force results | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File ..\windows-common\collect-versions.ps1 > results\versions.md
```

## Check K: keystroke injection

Terminal A (a Windows Terminal tab; PowerShell 7 preferred):

```powershell
pwsh -NoProfile -File .\echo-target.ps1          # or: powershell -NoProfile -File .\echo-target.ps1
```

Terminal B (a **separate** window, so focus can move to A):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\send-unicode.ps1 -Case all
# within 5 s, click into terminal A
```

The script prints the expected UTF-16 units for each case; terminal A prints what it
received with `units=` and `loneSurrogates=`. Copy both into `results\K-echo.txt`.

| Case | Text | Expected UTF-16 units |
|---|---|---|
| `bmp` | `hello 世界` | `0068 0065 006C 006C 006F 0020 4E16 754C` |
| `emoji` | `emoji 😀 and 𠮷 ok` | contains `D83D DE00` and `D842 DFB7` |
| `code` | ``fix `parseConfig()` in src/app.ts — 修一下`` | contains `0060`, `2014`, `4FEE 4E00 4E0B` |

If any surrogate pair arrives split (`loneSurrogates` > 0 or units differ), repeat with
the fallback ordering and record both:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\send-unicode.ps1 -Case emoji -Mode PairedDown
powershell -NoProfile -ExecutionPolicy Bypass -File .\send-unicode.ps1 -Case emoji -DelayMs 5
```

Then the real target. Terminal A: `cd $env:TEMP; mkdir s6-scratch -Force; cd s6-scratch; claude`.

```powershell
# B: type without Enter first, look at the prompt box, take a screenshot
powershell -NoProfile -ExecutionPolicy Bypass -File .\send-unicode.ps1 -Case all -NoEnter
# clear the prompt in A (Ctrl+U or Esc twice), then with Enter: each case must submit as one turn
powershell -NoProfile -ExecutionPolicy Bypass -File .\send-unicode.ps1 -Case all
```

Save screenshots as `results\K-claude-*.png` (keep them out of git if they show
anything private; describe them in the table instead).

## Check H: hooks

1. Terminal C, keep it running for the whole check:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\hook-listener.ps1
   ```

2. Self-test the listener with the exact header (terminal B):

   ```powershell
   '{"hook_event_name":"SelfTest"}' | Set-Content -Encoding ascii results\selftest.json
   curl.exe -s -w "%{http_code}`n" -X POST -H "Content-Type: application/json" -H "X-PowerUp-Token: spike-token-7f3a" --data-binary "@results\selftest.json" http://127.0.0.1:47800/event   # expect 204
   curl.exe -s -w "%{http_code}`n" -X POST -H "Authorization: Bearer spike-token-7f3a" --data-binary "@results\selftest.json" http://127.0.0.1:47800/event   # expect 401
   ```

3. Register the five hooks in the **user** settings file. The script backs the file up
   first (`settings.json.s6-backup-<time>`) and writes UTF-8 without a BOM:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-hooks.ps1 -Variant curl
   Get-Content -Raw $env:USERPROFILE\.claude\settings.json
   ```

4. In terminal A start a **new** `claude` session (hooks load at start-up; run `/hooks`
   to confirm all five are listed), then trigger each event:

   | Event | How to trigger it |
   |---|---|
   | `UserPromptSubmit` | submit any prompt |
   | `Notification` | ask "Run the shell command `echo powerup-spike` and show the output." and wait at the permission prompt for a few seconds |
   | `PostToolUse` | approve that command |
   | `Stop` | let the turn finish |
   | `SessionEnd` | type `/exit` |

5. Stop the listener (Ctrl+C). `results\hook-events.jsonl` now has one JSON line per
   request with `tokenHeader`, `tokenOk`, `authorizationHeader`, `hook_event_name` and
   the raw body.
6. Informational: start the listener **stopped**, run one turn, and note whether the CLI
   shows any hook error or delay (PowerUp's macOS script always exits 0; `curl.exe` here
   exits non-zero when nothing listens).
7. If the curl variant delivered nothing, rule out a quoting problem before calling
   NO-GO: `.\restore-settings.ps1`, then `.\install-hooks.ps1 -Variant relay`, and repeat
   steps 4-5 (the relay runs `hook-relay.ps1` through `powershell.exe`).
8. **Always restore** the real settings file at the end:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-settings.ps1
   Get-Content -Raw $env:USERPROFILE\.claude\settings.json   # must match your original
   ```

## Check S: stream-json and the nested control request

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\stream-json-probe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\stream-json-probe.ps1 -FlatShapeControl
```

The first run sends, in order: a user turn, `set_permission_mode` (plan), `set_model`
(haiku), the non-existent `set_effort`, a second user turn and an `interrupt`, then
closes stdin. It prints PASS/FAIL per step and writes every line in both directions to
`results\stream-json-nested.jsonl` (`>>` sent, `<<` received) plus stderr. The second
run sends only the flat shape, which kills the CLI on macOS (exit 1, "Missing request on
control_request"); it records whether Windows matches. Use `-ClaudePath` if `claude`
is not on `PATH` (an npm `claude.cmd` shim is handled through `cmd.exe`).

## Versions (fill in from `results\versions.md`)

| Item | Value |
|---|---|
| Windows edition, version, build | |
| Machine (bare metal?) | |
| Windows Terminal | |
| PowerShell used for each script | |
| Claude Code version (`claude --version`) and install method | |
| Git for Windows (`git --version`) | |
| `curl.exe --version` | |
| Spike commit | |

## Results (fill in)

### K: keystroke injection

| Target | Case | Mode | Units identical | loneSurrogates | Enter submitted one turn | Notes |
|---|---|---|---|---|---|---|
| echo-target | bmp | PerUnit | | | n/a | |
| echo-target | emoji | PerUnit | | | n/a | |
| echo-target | code | PerUnit | | | n/a | |
| echo-target | emoji | PairedDown (only if needed) | | | n/a | |
| claude | bmp | PerUnit | visual: | n/a | | |
| claude | emoji | PerUnit | visual: | n/a | | |
| claude | code | PerUnit | visual: | n/a | | |

### H: hooks

| Event | Arrived | `tokenHeader` exact | `authorizationHeader` empty | Body JSON parses | Latency feel (instant / delayed) | Variant |
|---|---|---|---|---|---|---|
| `UserPromptSubmit` | | | | | | |
| `Notification` | | | | | | |
| `PostToolUse` | | | | | | |
| `Stop` | | | | | | |
| `SessionEnd` | | | | | | |
| listener stopped: visible error or delay? | | n/a | n/a | n/a | | |

### S: stream-json

Paste the probe's summary block and fill the table.

| Step | PASS / FAIL | Observation |
|---|---|---|
| `system/init` arrives (session_id, model) | | |
| S1 turn completes with `result` | | |
| S2 `set_permission_mode` acked `success` | | |
| S3 `set_model` acked `success` | | |
| S4 unknown subtype answered `error`, process alive | | |
| S5 `interrupt` acked, turn ends with `result` | | |
| S6 clean exit after stdin closes | | |
| Flat shape (parity): exit code and stderr | info | |

## GO thresholds

- **K GO:** in the echo target all three cases arrive with identical UTF-16 units and
  `loneSurrogates=0` in `PerUnit` mode, and in `claude` all three are visually intact
  and Enter submits exactly one turn each. **Partial:** BMP text is fine but surrogate
  pairs split in every mode: record GO for CJK text and NO-GO for non-BMP characters.
- **H GO:** all five events arrive with the exact `X-PowerUp-Token` header, a parseable
  JSON body and the right `hook_event_name`, with no visible delay to the CLI, in at
  least one variant. If only the relay variant works, it is still GO, with the note that
  the Windows hook command must not depend on shell quoting (the plan's
  `powerup hook-relay` subcommand already avoids it).
- **S GO:** `system/init` and steps S1 to S5 all PASS.

## Verdict (fill in)

| Check | GO / NO-GO / partial | Evidence |
|---|---|---|
| K keystroke injection | | |
| H hooks | | |
| S stream-json | | |

## Consequence

| Outcome | What changes in the plan |
|---|---|
| All GO | Stage 3 targets native Windows as planned; Windows fixtures recorded here sit next to the macOS ones. |
| **H NO-GO** | Stage 3 routes Claude Code through **WSL2** (the CLI and its hooks run inside WSL; the Windows app talks to it there). Update plan stage 3 and the risk table. |
| **S NO-GO** | **ACP becomes the first built-in harness on Windows**; the ported stream-json parser stays for macOS/Linux. Update plan stage 3 and ADR 0007's amendment (which assumed the parser keeps Windows independent of ACP). |
| K NO-GO (all text) | Remote mode on Windows cannot use `SendInput` typing; file a follow-up to choose another delivery (for example clipboard paste) before stage 3 injection work. |
| K partial (non-BMP only) | Keep `SendInput`; the Windows injector documents or works around non-BMP characters; add a fixture for it. |
| Flat shape does not kill the CLI on Windows | Informational: DESIGN.md's rule stays (always send the nested envelope). |

Clean-up: run `restore-settings.ps1`, delete the backup once checked, delete
`%TEMP%\s6-scratch`. Commit `results\*.jsonl`, `results\versions.md` and the
filled-in tables; leave out screenshots that show private content.
