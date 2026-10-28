# S1: DualSense light bar, adaptive triggers and haptics on current macOS

- **Spike:** S1 of `PLAN-any-device-any-os.md` stage 1, step 8; ticket #136, epic #95.
- **Status:** light bar **NO-GO** on macOS 27.2 from a bundle, over Bluetooth and
  over USB, observed 2026-10-28. Raw-binary runs not done; haptics and adaptive
  triggers not verdicted (see below).
- **Time box:** 0.5 day.
- **OS under test:** the plan and #136 were written for macOS 26. The maintainer's Mac
  now runs **macOS 27.2 (build 26B118)**, so this record answers the question for 27.2.
  Record the exact version you test on; if you can also test a macOS 26 machine, add a
  second results block.

## Question

On the maintainer's current macOS, can a process still:

1. write the DualSense light bar color (the feature PowerUp uses to mirror state),
2. set adaptive-trigger feedback and read the mode back,
3. play a transient haptic through the controller's haptics engine,

and does the answer differ between a **raw command-line binary** and an **ad-hoc signed
`.app` bundle**? PowerUp ships only as a bundle, so the bundle result decides the
feature; the raw result tells us whether bundle identity matters.

## Method

A throwaway program, [`s1-macos-light-bar/main.swift`](s1-macos-light-bar/main.swift),
built two ways by [`s1-macos-light-bar/build.sh`](s1-macos-light-bar/build.sh):

- `build/s1-light-bar`: raw binary, ad-hoc signed, identifier `com.powerup.spike.s1lightbar.raw`.
- `build/S1LightBar.app`: ad-hoc signed bundle, id `com.powerup.spike.s1lightbar`
  (deliberately **not** `com.powerup.claudepad`, so it never touches the real app's TCC
  grants), `LSUIElement` and `GCSupportsControllerUserInteraction` set like PowerUp.

The program sets `GCController.shouldMonitorBackgroundEvents = true`, waits up to 60 s
for a controller, then runs a fixed script and prints one line per observation:

| Step | What it does | What you must observe |
|---|---|---|
| `ENV` | OS version, bundle id (or "raw binary"), run loop | nothing |
| `C0`-`C5` | connection, vendor, `GCDualSenseGamepad` or not, light / haptics / battery presence | nothing |
| `L1`-`L4` | set RED, GREEN, BLUE, ORANGE (PowerUp's thinking color); read `light.color` back at +0 s, +0.5 s, +2 s | **LOOK:** does the bar actually change to each color? |
| `T1`-`T4` | R2 `setModeFeedback(0.2, 0.9)`, L2 `setModeWeapon(0.3, 0.6, 0.9)`; read `mode`, `status`, `armPosition` at +0 s, +0.5 s, then every 2 s for 8 s; then both off | **PRESS:** squeeze R2 (resistance from ~20%) and L2 (a click between 30% and 60%) |
| `H1`-`H3` | haptic engine (`.default` locality): one transient, one 0.4 s continuous | **FEEL:** one tap, then a short buzz |
| `I1`-`I2` | 10 s window logging button down/up | **PRESS:** a few face buttons, touchpad, PS |
| `R1` | light back to blue | nothing |

The API readback (`light.color`, `trigger.mode`) can simply echo the value the process
just set, so **your eyes and fingers are the verdict**; the readback is supporting
evidence only. The program never touches PowerUp's config, settings or bundle.

## Exact commands

Quit PowerUp first (it owns the light bar while running). From the repository root:

```sh
cd docs/research/spikes/s1-macos-light-bar
./build.sh                                   # builds build/s1-light-bar and build/S1LightBar.app
mkdir -p results
sw_vers > results/versions.txt; swiftc --version >> results/versions.txt 2>&1
system_profiler SPBluetoothDataType 2>/dev/null | grep -A6 -i "DualSense" >> results/versions.txt

# Run A: raw binary, USB cable
./build/s1-light-bar --log results/A-raw-usb.log

# Run B: raw binary, Bluetooth (unplug the cable; pad paired in System Settings > Bluetooth)
./build/s1-light-bar --log results/B-raw-bt.log

# Run C: bundle via LaunchServices, USB (output goes only to the log file; open -W waits)
open -W -n build/S1LightBar.app --args --log "$PWD/results/C-bundle-usb.log"; cat results/C-bundle-usb.log

# Run D: bundle via LaunchServices, Bluetooth
open -W -n build/S1LightBar.app --args --log "$PWD/results/D-bundle-bt.log"; cat results/D-bundle-bt.log
```

Optional extra runs (do them if A-D disagree):

```sh
# E: raw binary without NSApplication (plain dispatchMain run loop)
./build/s1-light-bar --no-appkit --log results/E-raw-noappkit-bt.log
# F: both signed with the stable local identity from scripts/setup-signing.sh
S1_SIGN_IDENTITY="PowerUp Local Signing" ./build.sh
open -W -n build/S1LightBar.app --args --log "$PWD/results/F-bundle-stable-bt.log"
# G: control: the real app. Build and open PowerUp; idle is blue, push-to-talk turns it red, a running turn orange.
(cd ../../../.. && ./scripts/build.sh && open build/PowerUp.app)
```

Exit codes: `0` script completed, `2` no controller connected within 60 s
(`--wait <seconds>` changes the timeout).

## Versions (fill in)

| Item | Value |
|---|---|
| macOS (`sw_vers`) | |
| Mac model / chip | |
| Swift compiler (`swiftc --version`) | |
| DualSense firmware (if shown in System Settings > Game Controllers) | |
| Connection(s) tested | USB / Bluetooth |
| Spike commit | |

## Results (fill in)

Use `yes` / `no` / `n/a` for what you saw or felt, and paste the readback values from
the log. One row per run.

| Run | Light changed visibly (R/G/B/Orange) | `light.color` readback at +2 s matches | R2 resistance felt | `T1` mode after set (expect 1) | L2 weapon click felt | `T2` mode after set (expect 2) | Transient haptic felt | Continuous haptic felt | Buttons logged in `I1` | Errors in log |
|---|---|---|---|---|---|---|---|---|---|---|
| A raw, USB | | | | | | | | | | |
| B raw, BT | | | | | | | | | | |
| C bundle, USB | not run (see C2) | | | | | | | | | |
| C2 bundle, USB, slow (6 s per color, spoken) | **no** (bar stayed dim red for red, green, blue, white, off, green) | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | none |
| D bundle, BT | no (bar stayed dim red throughout) | yes (readback echoes every set color) | not tried | 0 | not tried | 0 | not observed | not observed | none pressed (seen=0) | none |
| D2 bundle, BT, slow (6 s per color, spoken) | **no** (bar stayed dim red for red, green, blue, white, off, green) | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | none |
| E raw, no AppKit (optional) | | | | | | | | | | |
| F bundle, stable identity (optional) | | | | | | | | | | |
| G real PowerUp (control) | **no**: idle showed dim red with blue and with green set; the pad's buttons, triggers and voice holds all worked in the same session | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | |

Raw logs: commit `results/*.log` next to this record (they hold no personal data
beyond the OS build and the controller's vendor name).

## Verdict rules

- **Light bar GO:** the bar visibly changes to all four colors in run **C or D** (bundle).
  A raw-only success with a bundle failure is a NO-GO for the feature (PowerUp is a
  bundle) and must be called out.
- **Light bar NO-GO:** the bar does not change in either bundle run while the pad is
  otherwise working (buttons logged in `I1`). If buttons are not logged either, the
  run is **INCONCLUSIVE** (input delivery problem, not a light-bar answer): re-pair and
  repeat before recording a verdict.
- **Adaptive triggers and haptics** are recorded as GO/NO-GO each, but are
  informational: PowerUp uses haptics today (rumble feedback) and does not use
  adaptive triggers yet. A haptics NO-GO in the bundle runs is a regression worth its
  own issue.

Notes on runs C2, D, D2 and G (2026-10-28, macOS 27.2 build 26B118; DualSense over
Bluetooth for D, D2 and G, plugged in by USB for C2, where the USB host listing showed
the pad; PowerUp quit for C2, D and D2):

- Before any write, a fresh process reads `light.color` as `(0.502, 0.125, 0.020)`
  (`D-bundle-bt.log` `L1 before`, `D2-bundle-bt-slow.log`): a dim red-orange, which is
  the color the bar actually shows. Every later readback echoes what the process set,
  so the readback proves nothing about the hardware.
- D2 is a slower re-run for the maintainer to watch: [`results/D2-slowlight-main.swift`](s1-macos-light-bar/results/D2-slowlight-main.swift),
  an ad-hoc signed bundle (`com.powerup.spike.slowlight`, `LSUIElement`,
  `GCSupportsControllerUserInteraction`) that holds each color 6 s and speaks its name.
- `I1` saw no buttons in run D only because none were pressed; the pad's input was
  working in PowerUp in the same session (G), so the NO-GO is not an input problem.
- `T1`/`T2` read mode 0 right after setting feedback/weapon, but nobody squeezed the
  triggers, so adaptive triggers stay unverdicted.

## Verdict

| Check | GO / NO-GO / INCONCLUSIVE | Evidence (run + log line) |
|---|---|---|
| Light bar (bundle) | **NO-GO** on 27.2, Bluetooth and USB | C2, D, D2, G: bar stayed dim red; `L1 before=(r 0.502, g 0.125, b 0.020)` |
| Light bar (raw) | not run | |
| Adaptive triggers | INCONCLUSIVE | D: `T1`/`T2` mode 0 after set; not squeezed |
| Haptics | INCONCLUSIVE | D: `H1`/`H2` played without error; not felt-checked |

## Consequence

| Outcome | What changes |
|---|---|
| Light bar GO in the bundle | Keep light mirroring in the macOS adapter. Note the tested OS version in ADR 0007's amendment / the plan's stage 3 assumptions. |
| Light bar NO-GO in the bundle | File a follow-up issue: **the macOS adapter drops light mirroring on this OS version** (gate the feature by OS version, hide or explain the setting in `docs/controls.md`). There is no Rust-plugin fallback on the Mac any more (ADR 0012), so the feature is dropped, not rerouted. Do not change the app inside this spike (#95 Out of Scope). |
| Raw GO, bundle NO-GO | Same as NO-GO, plus a note that bundle identity / signing is the cause; try run F before closing. |
| Haptics NO-GO in the bundle | File a bug against `ControllerService` haptics on this OS version. |
| Adaptive triggers GO | Record only; adaptive-trigger feedback stays a stage 5 idea. |

After the verdict: update the plan's stage 1 spike line and stage 3 assumptions, and
delete `build/` (it is git-ignored). Keep `main.swift`, `build.sh` and the logs as the
archive of this spike.
