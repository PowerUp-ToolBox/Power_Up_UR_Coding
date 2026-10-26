# S4: Rust controller stack on Windows

- **Spike:** S4 of `PLAN-any-device-any-os.md` stage 1, step 8; ticket #134, epic #95.
- **Status:** PENDING (needs a Windows 11 machine on bare metal, a DualSense, a USB cable and
  Bluetooth).
- **Time box:** 1.5 days.
- **Feeds:** ADR 0007's amendment (which rung the Windows and Linux controller adapter is
  built on).
- **Kit:** [`s4-windows-controller/`](s4-windows-controller/), a Cargo workspace with one
  probe per rung, versions pinned in `Cargo.lock`. All three probes pass
  `cargo check --locked` for `aarch64-unknown-linux-gnu` and `x86_64-pc-windows-gnu`
  (Rust 1.90 container, 2026-10-23); none has been **run** yet (no pad, no Windows here).

## Question

Which Rust gamepad stack, walked as a ladder, reads a DualSense on Windows **with
background events** (console not focused) and drives its light bar and rumble, over USB
and then Bluetooth?

| Rung | Probe | Stack |
|---|---|---|
| 1 | `rung1-sdl3` | `sdl3` crate 0.20.0 (safe API), SDL 3.4.18 built from source and linked statically |
| 2 | `rung2-sdl3-sys` | `sdl3-sys` 0.7.2 raw C API, same SDL build; isolates "the wrapper is the problem" from "SDL is the problem" |
| 3 | `rung3-gilrs-hidapi` | `gilrs` 0.11.2 (default Windows.Gaming.Input backend) for input + `hidapi` 2.6.7 raw DualSense reports for light, rumble, battery and a raw-report button check |

Every probe sets `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` (SDL rungs) **before** init and
runs the same script: wait for the pad, input checklist, background-event window, four
light colors, both rumble motors, battery. Each line is prefixed with a step id
(`C`, `I`, `B`, `L`, `R`, `P`, and `G`/`H` on rung 3) so the output can be pasted into
the record. Lines starting with `PRESS:`, `LOOK:`, `FEEL:`, `BACKGROUND:` ask you to act.

Rung 3's raw report layout was written from the publicly documented DualSense HID format
(byte offsets only), as the plan requires; no GPL driver code is copied. It tries both
rumble flag variants (`v1` in valid_flag0, `v2` in valid_flag2) because firmware differs;
note which one buzzes.

## Setup (once)

PowerShell, non-elevated:

```powershell
winget install --id Rustlang.Rustup -e
winget install --id Kitware.CMake -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
# open a NEW terminal, then:
rustup default stable            # sdl3 0.20 needs rustc >= 1.87
rustc --version; cargo --version; cmake --version

cd C:\src\PowerUp\docs\research\spikes\s4-windows-controller
New-Item -ItemType Directory -Force results | Out-Null
powershell -NoProfile -ExecutionPolicy Bypass -File ..\windows-common\collect-versions.ps1 > results\versions.md

cargo build --release --locked -p rung1-sdl3 --features build-sdl
cargo build --release --locked -p rung2-sdl3-sys --features build-sdl
cargo build --release --locked -p rung3-gilrs-hidapi
```

Before every run: quit **Steam** (Steam Input grabs the DualSense and can hide or remap
it), DS4Windows, DSX and any other controller tool; note in the record what was running.
Bare metal only: Bluetooth in a VM is out of scope (#95).

Pairing for the Bluetooth runs: unplug the cable, hold **PS + Create** until the light
bar flashes, then Settings > Bluetooth & devices > Add device > Bluetooth > "DualSense
Wireless Controller".

## Exact commands (one log per rung and transport)

```powershell
# Rung 1, USB then Bluetooth
.\target\release\rung1-sdl3.exe | Tee-Object results\rung1-usb.log
.\target\release\rung1-sdl3.exe | Tee-Object results\rung1-bt.log

# Rung 2 only if rung 1 fails a check (or to confirm a rung 1 failure is SDL's, not the wrapper's)
.\target\release\rung2-sdl3-sys.exe | Tee-Object results\rung2-usb.log
.\target\release\rung2-sdl3-sys.exe | Tee-Object results\rung2-bt.log

# Rung 3 only if rungs 1-2 fail a check
.\target\release\rung3-gilrs-hidapi.exe | Tee-Object results\rung3-usb.log
.\target\release\rung3-gilrs-hidapi.exe | Tee-Object results\rung3-bt.log
#   --skip-gilrs   runs only the raw hidapi part;   --input-seconds 60   shortens the checklists
```

During the **background** step, click into another window (Notepad is fine) so the
console loses focus **before** pressing Cross; the record must say where focus was.

## Versions (fill in)

| Item | Value |
|---|---|
| Windows edition, version, build; bare metal confirmed | |
| Bluetooth adapter (`Get-PnpDevice -Class Bluetooth`) | |
| `rustc --version`, `cargo --version` | |
| MSVC (`cl`) and `cmake --version` | |
| Crates (from `Cargo.lock`) | sdl3 0.20.0, sdl3-sys 0.7.2+SDL-3.4.18, sdl3-src 3.4.18, gilrs 0.11.2, gilrs-core 0.6.8, hidapi 2.6.7 |
| DualSense model and firmware (rung 1 `C1` prints `firmware`) | |
| Controller software that was running / quit | |
| Spike commit | |

## Results (fill in, one row per run)

| Run | Pad found (`C1`) | Buttons + axes seen (`I3` / `G4` / `H7`) | Background presses (`B2`, of 3) with focus elsewhere | Light: 4 colors visible | Rumble: left / right felt (rung 3: v1 or v2) | Battery (`P1`) | Errors |
|---|---|---|---|---|---|---|---|
| rung1 USB | | /23 | | | | | |
| rung1 BT | | /23 | | | | | |
| rung2 USB (if run) | | /23 | | | | | |
| rung2 BT (if run) | | /23 | | | | | |
| rung3 USB (if run) | | gilrs /21, raw /19 + triggers | | | | | |
| rung3 BT (if run) | | gilrs /21, raw /19 + triggers | | | | | |

For each rung that was tried and rejected, write one sentence on **what failed** (build,
device not found, missing buttons, no background events, light or rumble silent).

## GO rule

A rung is **GO** when, on **both USB and Bluetooth**:

1. every button and both analog triggers are seen (SDL rungs: 17 buttons incl. touchpad
   and mic mute (`Misc1`) + 6 axes; rung 3: gilrs or the raw-HID check covers all
   19 buttons and both triggers),
2. 3 of 3 background presses arrive while another app has focus,
3. all four light colors are visible,
4. both rumble motors are felt.

Battery is recorded when exposed and does not block GO. The **winning rung** is the lowest
rung that is GO; stop climbing once one is GO (time box).

## Verdict (fill in)

| Question | Answer |
|---|---|
| Winning rung | 1 / 2 / 3 / none |
| What failed on the rungs below it | |
| USB-only limitations (if any) | |
| Bluetooth-only limitations (if any) | |

## Consequence

| Outcome | What changes |
|---|---|
| Rung 1 GO | ADR 0007 amendment: Windows (and Linux) controller adapter uses the `sdl3` crate with `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` set before init; SDL built from source and statically linked. |
| Rung 2 GO, rung 1 not | ADR 0007 amendment: adapter calls SDL through `sdl3-sys` behind a small safe module of our own; note the wrapper defect that ruled out rung 1. |
| Rung 3 GO only | ADR 0007 amendment: gilrs for input + hidapi raw reports for light, rumble and battery; the report format is maintained in our code (format-only, no GPL copies); profile ids and control ids stay identical to the Mac (plan stage 3). |
| No rung GO on Bluetooth, GO on USB | Windows ships USB-only controller support first; docs say so; follow-up issue for Bluetooth. |
| No rung delivers background events | The adapter needs another input path on Windows (for example a hidden window with Raw Input `RIDEV_INPUTSINK`); file a follow-up before stage 3 controller work. |
| Nothing works | Stage 3 Windows controller support is blocked; keyboard and mouse parity (DESIGN v2.6, controller-optional) still ships. |

Clean-up: `cargo clean` (or delete `target\`, which is git-ignored). Commit the logs in
`results\` and the filled-in tables.
