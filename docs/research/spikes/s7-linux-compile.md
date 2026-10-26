# S7: Which Swift files compile unchanged on Linux?

- **Spike:** S7 of `PLAN-any-device-any-os.md` stage 1, step 8; ticket #137 (part 1), epic #95.
- **Status:** DONE (informational; not on the critical path).
- **Run:** 2026-10-23, by an agent, against commit `79ea897` (branch `stage-1-text-views-spikes`).
- **Verdict:** **2 of 26 files compile unchanged on Linux.** Six more compile after one
  constant is moved out of `Models.swift`; eleven compile when the observable-object
  pattern (Combine) is stubbed. The boundary between core and adapter is set by two
  things the import lines do not show: `Models.swift` importing AVFAudio for one
  constant, and Linux Foundation not re-exporting Combine.

## Question

Which files under `Sources/PowerUp` typecheck unchanged with Swift 5.9 on Linux, and
what blocks the rest? The answer tells stage 2 whether the "pure" files are really
platform-free, so the core/adapter boundary matches reality (#95, user story 6).

## Method

1. Typecheck each file **alone** (`swiftc -typecheck -parse-as-library`), on Linux.
   This mostly fails on cross-file types, so it only shows the first blocker per file.
2. Build the **pure set** by fixed point: start from every file whose only import is
   `Foundation` (or nothing), typecheck them together, drop every file that reports an
   error, repeat until the remaining set typechecks cleanly.
3. **Control:** run the same script on macOS (same compiler version) so a Linux failure
   can be told apart from a dependency-graph failure.
4. **Counterfactuals** on a throwaway copy (the repository is not edited):
   - `models`: `Models.swift` drops `import AVFAudio`; its single use of
     `AVSpeechUtteranceDefaultSpeechRate` becomes the literal `0.5`.
   - `models+combine-stub`: as above, plus every `import Combine` is removed and a stub
     declares an empty `ObservableObject` protocol and a trivial `@Published` wrapper.
     A file that still fails uses real Combine (publishers, `sink`, `AnyCancellable`).

Scripts (re-runnable, read-only mounts):
[`s7-linux-compile/typecheck.sh`](s7-linux-compile/typecheck.sh),
[`s7-linux-compile/whatif.sh`](s7-linux-compile/whatif.sh).

## Exact commands

From the repository root:

```sh
docker info                      # daemon was down; started once with: open -a Docker
docker pull swift:5.9
docker image inspect swift:5.9 --format '{{index .RepoDigests 0}} {{.Architecture}} {{.Os}}'

docker run --rm -v "$PWD":/src:ro -w /src swift:5.9 \
  bash docs/research/spikes/s7-linux-compile/typecheck.sh
docker run --rm -v "$PWD":/src:ro -w /src swift:5.9 \
  bash docs/research/spikes/s7-linux-compile/whatif.sh models
docker run --rm -v "$PWD":/src:ro -w /src swift:5.9 \
  bash docs/research/spikes/s7-linux-compile/whatif.sh models+combine-stub
bash docs/research/spikes/s7-linux-compile/typecheck.sh        # macOS control
```

## Versions

| Item | Value |
|---|---|
| Image | `swift:5.9` = `swift@sha256:006635153a77dfc9d096dfc954b362d9017f1560d74c357100b50429bf5174c7` (linux/arm64) |
| Container OS | Ubuntu 22.04.5 LTS, `Linux aarch64` |
| Linux compiler | Swift version 5.9.2 (swift-5.9.2-RELEASE), target `aarch64-unknown-linux-gnu` |
| Docker | Docker Desktop, server 28.5.1 |
| Host / control | macOS 27.2 (26B118), Apple Swift 5.9.2 (swiftlang-5.9.2.2.56), SDK 14.2 |

Raw outputs: [`s7-linux-compile/results/`](s7-linux-compile/results/)
(`baseline-linux.txt`, `baseline-macos.txt`, `whatif-models-linux.txt`,
`whatif-models-combine-stub-linux.txt`).

## Raw per-file results

Columns: **Alone** = typechecked by itself on Linux (first error shown).
**Pure set** = member of the Linux fixed-point set as the code stands.
**+models** / **+combine stub** = member of the fixed-point set under the counterfactuals.
**macOS alone** = control.

| File | Lines | Imports | Linux alone | Pure set | +models | +combine stub | macOS alone |
|---|---:|---|---|:-:|:-:|:-:|:-:|
| `ACPAdapter.swift` | 582 | Foundation | FAIL: cannot find type 'HarnessState' | - | - | PASS | FAIL |
| `AppState.swift` | 2137 | AppKit, Combine, Foundation | FAIL: no such module 'Combine' | - | - | - | FAIL |
| `AudioDeviceStore.swift` | 194 | CoreAudio, Foundation | FAIL: no such module 'CoreAudio' | - | - | - | PASS |
| `ClaudeService.swift` | 873 | Combine, Foundation | FAIL: no such module 'Combine' | - | - | PASS | FAIL |
| `ComponentViews.swift` | 1091 | AppKit, SwiftUI | FAIL: no such module 'SwiftUI' | - | - | - | FAIL |
| `ConfigStore.swift` | 123 | Foundation | FAIL: cannot find type 'AppConfig' | - | - | PASS | FAIL |
| `ControllerService.swift` | 310 | CoreHaptics, Foundation, GameController | FAIL: no such module 'GameController' | - | - | - | FAIL |
| `ControllerSlot.swift` | 142 | (none) | FAIL: cannot find type 'VoiceCaptureMode' | - | PASS | PASS | FAIL |
| `DestructiveActionClassifier.swift` | 38 | Foundation | PASS | PASS | PASS | PASS | PASS |
| `Harness.swift` | 113 | Foundation | FAIL: cannot find type 'ClaudeState' | - | PASS | PASS | FAIL |
| `HookInstaller.swift` | 426 | Foundation | PASS | PASS | PASS | PASS | PASS |
| `Intent.swift` | 119 | Foundation | FAIL: cannot find type 'Action' | - | PASS | PASS | FAIL |
| `MainView.swift` | 876 | AppKit, SwiftUI | FAIL: no such module 'SwiftUI' | - | - | - | FAIL |
| `MappingView.swift` | 237 | SwiftUI | FAIL: no such module 'SwiftUI' | - | - | - | FAIL |
| `Models.swift` | 630 | AVFAudio, Foundation | FAIL: no such module 'AVFAudio' | - | PASS | PASS | PASS |
| `PowerUpApp.swift` | 82 | SwiftUI | FAIL: no such module 'SwiftUI' | - | - | - | FAIL |
| `PowerUpProtocol.swift` | 193 | Foundation | FAIL: cannot find type 'Intent' | - | - | - | FAIL |
| `RemoteControlService.swift` | 906 | AppKit, ApplicationServices, Combine, CoreGraphics, Foundation | FAIL: no such module 'Combine' | - | - | - | FAIL |
| `RemoteListener.swift` | 852 | Combine, Foundation, Network | FAIL: no such module 'Combine' | - | - | - | FAIL |
| `SettingsView.swift` | 1052 | AVFAudio, AppKit, Speech, SwiftUI | FAIL: no such module 'SwiftUI' | - | - | - | FAIL |
| `SpeechService.swift` | 277 | AVFAudio, AudioToolbox, Foundation, Speech | FAIL: no such module 'Speech' | - | - | - | FAIL |
| `SummaryService.swift` | 136 | Foundation | FAIL: cannot find type 'ObservableObject' | - | - | PASS | FAIL |
| `TTSService.swift` | 677 | AVFAudio, AudioToolbox, CoreAudio, Foundation, NaturalLanguage | FAIL: no such module 'AVFAudio' | - | - | - | PASS |
| `TranscriptStore.swift` | 140 | CryptoKit, Foundation | FAIL: no such module 'CryptoKit' | - | - | - | FAIL |
| `ViewLogic.swift` | 118 | Foundation | FAIL: cannot find type 'ControllerButton' | - | - | - | FAIL |
| `WebSocketFraming.swift` | 141 | CryptoKit, Foundation | FAIL: no such module 'CryptoKit' | - | - | - | PASS |

Fixed-point rounds: 7 (Linux baseline), 6 (`models`), 3 (`models+combine-stub`).
The macOS control produced the same two-file pure set as Linux, which shows the small
set is caused by the dependency graph (everything leans on `Models.swift`), not by
Linux alone.

## Findings

1. **Pure today (2):** `DestructiveActionClassifier.swift`, `HookInstaller.swift`.
   `HookInstaller` uses `FileManager`, `JSONSerialization` and POSIX permissions; all
   work in swift-corelibs-foundation.
2. **One constant away (4 more):** `Models.swift` imports AVFAudio only for
   `AVSpeechUtteranceDefaultSpeechRate` (one use, line 370). With that literal moved out,
   `Models`, `Intent`, `Harness` and `ControllerSlot` join the pure set. Every other
   candidate depends on `Models.swift`, so this single import is the largest blocker.
3. **Hidden Combine (3 files that import only Foundation):** `ACPAdapter`, `ConfigStore`
   and `SummaryService` use `ObservableObject` / `@Published` while importing only
   Foundation. On macOS, Foundation re-exports Combine; on Linux it does not
   (`unknown attribute 'Published'`, `cannot find type 'ObservableObject'`). The
   import line alone is therefore not a reliable purity test.
4. **Combine is only the observable-object pattern:** with a two-declaration stub,
   `ClaudeService` (the stream-json parser and the process plumbing, including
   `Process` and `Pipe`), `ACPAdapter`, `ConfigStore` and `SummaryService` all
   typecheck on Linux. No file in that group uses publishers, `sink` or
   `AnyCancellable`.
5. **CryptoKit:** `WebSocketFraming` (SHA-1 for the handshake) and `TranscriptStore`
   (SHA-256 of the path) need CryptoKit, which does not exist on Linux. swift-crypto
   would cover both, but it is a third-party dependency, which CLAUDE.md rules out for
   the app. `PowerUpProtocol` fails only because it uses `WebSocketFraming`.
6. **AppState coupling:** `ViewLogic.swift` imports only Foundation but references
   `AppState`, so it cannot leave the app target as it stands.
7. **Adapters by nature (11):** views (`SwiftUI`/`AppKit`), `AppState`,
   `AudioDeviceStore` (CoreAudio), `ControllerService` (GameController, CoreHaptics),
   `RemoteControlService` (AppKit, ApplicationServices, CoreGraphics), `RemoteListener`
   (Network), `SpeechService` (Speech), `TTSService` (AVFAudio, NaturalLanguage).
   These match the plan's "Swift keeps UI and platform adapters" split.

## Verdict

Informational, no GO/NO-GO. The pure logic the plan expects to move into the Rust core
(`Models`, `Intent`, `ControllerSlot`, the harness types, the stream-json parser in
`ClaudeService`, `DestructiveActionClassifier`, the hook settings merge in
`HookInstaller`) is platform-free in substance. Two small couplings hide that:
the AVFAudio constant in `Models.swift` and the observable-object pattern on the
services that hold the parsers.

## Consequence

- **Stage 2 (#96-#101):** no change of direction. The port is still a port of pure
  logic. When a module moves to the core, the Swift side keeps the `ObservableObject`
  wrapper and the logic moves out; nothing here suggests compiling Swift on Linux.
- **Plan stage 3 assumptions:** "the pure Swift files are pure" is **confirmed with two
  caveats**: (a) `Models.swift`'s default TTS rate is a platform constant, so the
  core's config defaults need a per-OS value for it; (b) hashing (SHA-1, SHA-256)
  must come from the Rust side's own crates, not from CryptoKit.
- **No app change is made by this spike.** If the maintainer wants the Swift purity
  boundary to be checkable in CI later, the cheapest step is replacing
  `AVSpeechUtteranceDefaultSpeechRate` with a named constant inside `TTSService.swift`;
  that is a separate ticket, not part of #137.
- To be folded into the plan and ADRs together with S1/S4/S5/S6 by #137 part 2.
