# PowerUp — DualSense controller for Claude Code (macOS)

A native SwiftUI macOS app that turns a PS5 DualSense controller into a remote for
Claude Code: hold a trigger to speak an instruction (speech-to-text → sent to a
persistent Claude Code session), hear replies via text-to-speech, and map every
button to configurable actions (approve, interrupt, quick prompts, …). The
controller light bar and haptics mirror session state.

**This document is the binding contract for implementation. Implementers: code
against the exact signatures below. Do not invent, rename, or widen any
cross-module API. If your module needs something not listed here, solve it
privately inside your own file(s).**

## Stack & constraints (verified against this machine)

- Swift 5.9 / SwiftPM executable target → packaged into a `.app` bundle by `scripts/build.sh`.
- macOS 14+ (`LSMinimumSystemVersion 14.0`), macOS 14.2 SDK (the installed Xcode). Do NOT use APIs newer than macOS 14.2 SDK (no SpeechAnalyzer, no `@Observable`-requiring-later features — `@Observable` macro IS fine, it's macOS 14, but we standardize on `ObservableObject` + `@Published` everywhere for uniformity).
- Frameworks: SwiftUI, AppKit, GameController, CoreHaptics, Speech, AVFoundation/AVFAudio, Foundation. No third-party dependencies.
- The app is NOT sandboxed, ad-hoc signed. No entitlements file. TCC works via Info.plist usage strings; the app must be launched as a bundle (`open build/PowerUp.app`), never as a raw binary.
- There is NO AVAudioSession on macOS. Mic capture = `AVAudioEngine.inputNode` tap using `inputNode.outputFormat(forBus: 0)` (never a hand-rolled format).
- `GCController.shouldMonitorBackgroundEvents = true` must be set at startup or a non-frontmost app gets zero controller events on macOS 11.3+.

## File layout

```
Package.swift
Sources/PowerUp/
  PowerUpApp.swift        # @main SwiftUI App + scenes (module: Entry)
  AppState.swift          # central glue/state machine (module: Entry)
  Models.swift            # shared types (module: Foundation)
  ConfigStore.swift       # config persistence (module: Foundation)
  ControllerService.swift # DualSense input/haptics/light (module: Controller)
  SpeechService.swift     # push-to-talk STT (module: Speech)
  TTSService.swift        # text-to-speech (module: Speech)
  ClaudeService.swift     # claude CLI subprocess, stream-json (module: Claude)
  MainView.swift          # main window UI (module: MainUI)
  ComponentViews.swift    # reusable UI pieces (module: MainUI)
  SettingsView.swift      # settings scenes (module: SettingsUI)
  MappingView.swift       # button-mapping editor (module: SettingsUI)
scripts/build.sh          # SPM build → .app bundle → ad-hoc codesign (module: Foundation)
README.md                 # setup/usage/troubleshooting (module: Foundation)
```

`Package.swift`: swift-tools-version 5.9; package name `PowerUp`; `platforms: [.macOS(.v14)]`; one executable target `PowerUp` at `Sources/PowerUp`. No dependencies, no plugins.

## Module: Foundation — Models.swift (exact contract)

```swift
import Foundation

enum ControllerButton: String, Codable, CaseIterable, Identifiable, Hashable {
    case cross, circle, square, triangle
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    case create      // left small button (GCExtendedGamepad.buttonOptions)
    case options     // right small button (GCExtendedGamepad.buttonMenu)
    case touchpad    // touchpad click (GCDualSenseGamepad.touchpadButton)
    case ps          // PS/home button (buttonHome) — mappable but default .none

    var id: String { rawValue }
    var displayName: String { ... }   // "Cross (✕)", "D-Pad Up", "L2 Trigger", "Create", ...
    var symbolName: String { ... }    // SF Symbol name; e.g. "xmark.circle", "circle.circle",
                                      // "square.circle", "triangle.circle", "dpad.up.filled",
                                      // "l1.button.roundedbottom.horizontal", "playstation.logo", ...
                                      // pick symbols that exist in SF Symbols 5 / macOS 14.
}

enum ControllerAction: Codable, Hashable {
    case none
    case pushToTalk               // hold to record, release to send transcript to Claude
    case sendPrompt(String)       // send a fixed text prompt to Claude
    case approve                  // sends "Yes" to Claude
    case reject                   // sends "No" to Claude
    case interrupt                // interrupt Claude's current turn
    case stopSpeaking             // stop TTS immediately
    case replayLastReply          // speak lastAssistantReply again
    case toggleTTS                // flip config.ttsEnabled
    case newSession               // discard session id, restart claude fresh
    case showWindow               // bring PowerUp to the foreground

    var displayName: String { ... }       // "Push to Talk", "Send Prompt…", "Approve (Yes)", ...
    var isHoldAction: Bool { self == .pushToTalk }
}

struct AppConfig: Codable, Equatable {
    var projectDir: String?               // absolute path of the coding project; nil = not chosen
    var model: String                     // "default" | "sonnet" | "opus" | "haiku" | "fable"
    var permissionMode: String            // "acceptEdits" (default) | "default" | "plan" | "bypassPermissions"
    var claudePath: String?               // manual override of the claude binary path
    var lastSessionID: String?            // for --resume across app launches
    var ttsEnabled: Bool
    var ttsRate: Float                    // AVSpeechUtterance rate; default AVSpeechUtteranceDefaultSpeechRate
    var ttsVoiceID: String?               // AVSpeechSynthesisVoice identifier; nil = best available en voice
    var maxSpokenChars: Int               // cap spoken reply length; default 600
    var localeID: String                  // STT locale; default "en-US"
    var onDeviceRecognition: Bool         // default false
    var hapticsEnabled: Bool              // default true
    var lightEnabled: Bool                // default true
    var mapping: [ControllerButton: ControllerAction]

    static func defaultConfig() -> AppConfig   // uses defaultMapping()
    static func defaultMapping() -> [ControllerButton: ControllerAction]
}
```

Default mapping (chosen from prior-art research — VibePad/ClaudeGamepad conventions):

| Button | Action |
|---|---|
| r2 | pushToTalk (hold) |
| cross | approve |
| circle | interrupt |
| square | sendPrompt("Continue") |
| triangle | stopSpeaking |
| l1 | replayLastReply |
| r1 | toggleTTS |
| dpadUp | sendPrompt("Run the tests and report the results") |
| dpadDown | sendPrompt("Explain what you just did, briefly") |
| dpadLeft | sendPrompt("Undo the last change you made") |
| dpadRight | sendPrompt("Commit the current changes with a good message") |
| options | newSession |
| create | showWindow |
| touchpad, l2, l3, r3, ps | none |

```swift
enum AppStatus: Equatable {
    case noController      // light: off (0,0,0) — or dim white
    case idle              // light: blue   (0.0, 0.25, 1.0)
    case listening         // light: red    (1.0, 0.0, 0.0)
    case thinking          // light: amber  (1.0, 0.45, 0.0)
    case speaking          // light: purple (0.55, 0.0, 1.0)
    var label: String { ... }   // "No Controller", "Ready", "Listening…", "Claude is working…", "Speaking"
}

struct TranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tool, system, error }
    let id: UUID
    let kind: Kind
    var text: String
    let date: Date
    init(kind: Kind, text: String)   // id/date auto
}

enum ClaudeState: Equatable { case stopped, starting, ready, working }

enum ClaudeEvent {
    case ready(sessionID: String, model: String)         // system/init parsed
    case textDelta(String)                               // stream_event text_delta
    case assistantMessage(String)                        // joined text blocks of an assistant message
    case toolUse(name: String, detail: String)           // e.g. ("Edit", "src/main.py")
    case turnCompleted(resultText: String?, costUSD: Double?, isError: Bool, subtype: String)
    case processError(String)                            // stderr content / spawn failure
    case terminated(exitCode: Int32)
}
```

`ControllerAction` uses Swift's synthesized Codable for enums with associated
values (Swift 5.5+ auto-synthesis) — do not hand-write coding.
`[ControllerButton: ControllerAction]` encodes as a keyed dictionary because the
key is `RawRepresentable<String>` (`CodingKeyRepresentable`, Swift 5.6+).

## Module: Foundation — ConfigStore.swift (exact contract)

```swift
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: AppConfig      // mutating triggers debounced save
    static var configURL: URL             // ~/Library/Application Support/PowerUp/config.json
    init()                                // load or defaultConfig(); tolerate/repair corrupt json
    func save()
    func resetMappingToDefault()
}
```

Persist as pretty-printed JSON. On decode failure, back up the bad file to
`config.json.bak` and start from defaults (never crash).

## Module: Controller — ControllerService.swift (exact contract)

```swift
@MainActor
final class ControllerService: ObservableObject {
    @Published private(set) var isConnected: Bool
    @Published private(set) var controllerName: String?     // e.g. "DualSense Wireless Controller"
    @Published private(set) var isDualSense: Bool           // productCategory == GCProductCategoryDualSense
    @Published private(set) var batteryLevel: Float?        // 0...1, polled every 60s + on connect
    @Published private(set) var isCharging: Bool

    var onButtonDown: ((ControllerButton) -> Void)?
    var onButtonUp: ((ControllerButton) -> Void)?

    func start()                                            // observers + discovery + existing controllers
    func setLight(r: Float, g: Float, b: Float)             // no-op if none/unsupported
    func rumble(intensity: Float, duration: TimeInterval)   // CoreHaptics transient/continuous; no-op if unsupported
}
```

Implementation requirements (from SDK-header research):
- `GCController.shouldMonitorBackgroundEvents = true` inside `start()`.
- Observe `.GCControllerDidConnect`/`.GCControllerDidDisconnect` AND seed from `GCController.controllers()` (already-paired controllers fire no synthetic connect).
- `startWirelessControllerDiscovery`.
- Use `pressedChangedHandler` on every button (including L2/R2 — their built-in hysteresis is fine for press/release semantics). Wire ALL `ControllerButton` cases: face buttons via `buttonA`(cross)/`buttonB`(circle)/`buttonX`(square)/`buttonY`(triangle), `dpad.up/.down/.left/.right` individual button inputs, `leftShoulder`/`rightShoulder`, `leftTrigger`/`rightTrigger`, `leftThumbstickButton`/`rightThumbstickButton`, `buttonOptions`(create)/`buttonMenu`(options), `buttonHome`(ps), and if the profile casts to `GCDualSenseGamepad`, `touchpadButton`.
- Fall back gracefully to plain `GCExtendedGamepad` for non-DualSense pads (light/haptics/touchpad become no-ops).
- Handlers arrive on the main queue by default (`GCDevice.handlerQueue`) — keep it that way.
- Haptics: `controller.haptics?.createEngine(withLocality: .default)`, CHHapticPattern with a transient event (or continuous for duration > 0.1); guard nil, wrap in do/catch, recreate engine on reconnect. Keep one lazily-created engine cached per connection.
- Light: `controller.light?.color = GCColor(red:green:blue:)`.
- Battery: `controller.battery?.batteryLevel/batteryState`, polled on a Timer (60s).

## Module: Speech — SpeechService.swift (exact contract)

```swift
@MainActor
final class SpeechService: ObservableObject {
    enum AuthState: Equatable { case unknown, authorized, denied }
    @Published private(set) var authState: AuthState
    @Published private(set) var isListening: Bool
    @Published private(set) var partialTranscript: String    // live text while listening

    func configure(localeID: String, onDevice: Bool)         // safe to call anytime; applies to next start
    func requestPermissionsIfNeeded() async -> Bool          // speech auth (mic TCC fires on first engine start)
    func startListening()                                    // begins capture + recognition
    func stopListening(completion: @escaping (String?) -> Void)
        // ends audio; waits up to 1.5s for a final result, else uses the last
        // partial; completion exactly once, on main; nil/empty → no usable speech
}
```

Implementation requirements (from research):
- `SFSpeechRecognizer(locale:)`, `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`; `addsPunctuation = true` (macOS 13+, we target 14).
- `requiresOnDeviceRecognition` only when configured AND `recognizer.supportsOnDeviceRecognition`.
- Tap: `let fmt = engine.inputNode.outputFormat(forBus: 0); installTap(onBus: 0, bufferSize: 4096, format: fmt)` → `request.append(buffer)`. Install tap before `engine.start()`. Remove tap + stop engine on stop. Fully tear down request/task each cycle (fresh objects per press — server STT caps ~1min; push-to-talk is well inside).
- Guard reentrancy: `startListening()` while listening is a no-op; `stopListening` while not listening → `completion(nil)`.
- If recognizer unavailable or auth denied: set `partialTranscript` to a short error hint, stay not-listening.

## Module: Speech — TTSService.swift (exact contract)

```swift
@MainActor
final class TTSService: NSObject, ObservableObject {
    struct Voice: Identifiable, Hashable { let id: String; let name: String; let quality: String }
    @Published private(set) var isSpeaking: Bool
    @Published private(set) var availableVoices: [Voice]     // en-* voices sorted best-first
    var onFinished: (() -> Void)?                            // fired on didFinish AND didCancel

    func speak(_ text: String, voiceID: String?, rate: Float)  // stops current speech first
    func stop()
    static func speechText(fromMarkdown text: String, maxChars: Int) -> String
}
```

`speechText` rules: fenced code blocks → the phrase "code omitted"; strip inline
backticks, `#`/`*`/`>`/link syntax; collapse whitespace; hard-truncate at
`maxChars` at a sentence boundary if possible, appending "… reply truncated."
Voice pick: `voiceID` if installed, else best `en` voice by quality
(premium > enhanced > default), else `AVSpeechSynthesisVoice(language: "en-US")`.

## Module: Claude — ClaudeService.swift (exact contract)

```swift
@MainActor
final class ClaudeService: ObservableObject {
    @Published private(set) var state: ClaudeState
    @Published private(set) var sessionID: String?
    @Published private(set) var modelName: String?
    @Published private(set) var totalCostUSD: Double

    var onEvent: ((ClaudeEvent) -> Void)?    // always invoked on the main actor

    static func resolveClaudeBinary(override: String?) -> String?
        // 1) override if it exists+executable  2) `/bin/zsh -l -c 'command -v claude'`
        // 3) common paths: ~/.claude/local/claude, /opt/homebrew/bin/claude,
        //    /usr/local/bin/claude, ~/.local/bin/claude, ~/.npm-global/bin/claude

    func start(projectDir: URL, model: String, permissionMode: String,
               resumeSessionID: String?, claudePathOverride: String?)
        // spawns: claude -p --verbose --input-format stream-json --output-format stream-json
        //                --include-partial-messages [--model M unless "default"]
        //                --permission-mode MODE [--resume ID]
        // NOTE: --verbose is REQUIRED — verified live: without it the CLI exits with
        // "Error: When using --print, --output-format=stream-json requires --verbose".
        // cwd = projectDir; env = inherited + claude bin dir prepended to PATH
    func send(_ text: String)      // writes user-message envelope + "\n" to stdin
    func interrupt()               // writes {"type":"control_request","subtype":"interrupt"} + "\n"
    func stop()                    // close stdin, terminate() after 2s grace, state = .stopped
}
```

Wire protocol (validated against claude CLI v2.1.243 — parse defensively;
UNKNOWN message types and unknown fields MUST be silently ignored):

stdin, one JSON object per line:
```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"PROMPT"}]},"parent_tool_use_id":null}
{"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt"}}
```
DANGER (verified live): the flat shape `{"type":"control_request","subtype":"interrupt"}`
is FATAL — the CLI exits code 1 with "Error: Missing request on control_request".
Control requests MUST use the nested `request` envelope with a `request_id`.
See the v1.1 addendum for the full verified control protocol (set_model,
set_permission_mode, control_response handling).

stdout, one JSON object per line — mapping to `ClaudeEvent`. (These shapes were
verified LIVE against claude v2.1.243 on this machine, including quirks below.)
- `{"type":"system","subtype":"init","session_id":"…","model":"…","cwd":…,…}` → `.ready`; state `.ready` (first init only; later inits just refresh fields)
- `{"type":"stream_event","event":{"type":"content_block_delta","index":N,"delta":{"type":"text_delta","text":"…"}}}` → `.textDelta`. IGNORE all other delta types (`thinking_delta`, `signature_delta`, `input_json_delta`) and all other stream_event subtypes (`message_start`, `content_block_start/stop`, `message_delta`, `message_stop`).
- `{"type":"assistant","message":{"content":[…]}}` — VERIFIED QUIRK: this arrives MULTIPLE times per turn, roughly once per completed content block (e.g. first with only a `thinking` block, later with only a `text` block). Handling: skip `thinking` blocks entirely; join `text` blocks → one `.assistantMessage` (only if non-empty, and suppress if identical to the previous assistantMessage this turn); one `.toolUse` per `tool_use` block, `detail` = best short human string from `input` (file_path / command / description / pattern / url / prompt / first string value, truncated ~80 chars).
- `{"type":"result","subtype":"success"|…,"is_error":bool,"result":…,"total_cost_usd":…,"num_turns":…,…}` → `.turnCompleted(resultText:costUSD:isError: is_error || subtype != "success", subtype:)`; accumulate `totalCostUSD`; state `.ready`
- IGNORE silently (all verified to occur): `system` subtypes `status`, `hook_started`, `hook_response`, `thinking_tokens`, `api_retry`, `compact_boundary`; type `rate_limit_event`; type `user` echoes; anything else unknown.

State machine: `.starting` on spawn → `.ready` on init → `.working` when `send()`
is called → `.ready` on result. `send()` while `.working` is allowed (CLI queues
stdin messages) but still emits the event flow normally.

Process-management requirements:
- `Process` + three `Pipe`s. stdout MUST be consumed with
  `fileHandleForReading.readabilityHandler` (never blocking reads on the main
  thread), accumulating a `Data` buffer and splitting on `\n`; a trailing
  partial line waits for more data. Parse each line with `JSONSerialization`;
  non-JSON lines → ignore. Hop to `MainActor` (e.g. `Task { @MainActor in … }`)
  before touching state or calling `onEvent`.
- stderr: accumulate; on nonzero termination emit `.processError` with the tail
  (last ~500 chars) before `.terminated`.
- `terminationHandler` → `.terminated(exitCode:)`, state `.stopped`, clear
  readabilityHandlers (retain-cycle hazard: set them to nil).
- If the binary can't be resolved: emit `.processError("claude CLI not found — set the path in Settings")`, state `.stopped`, don't crash.
- `start()` while running: `stop()` first, then relaunch.

## Module: Entry — AppState.swift (exact contract)

```swift
@MainActor
final class AppState: ObservableObject {
    let configStore: ConfigStore
    let controller: ControllerService
    let speech: SpeechService
    let tts: TTSService
    let claude: ClaudeService

    @Published private(set) var transcript: [TranscriptEntry]
    @Published private(set) var status: AppStatus
    @Published private(set) var lastAssistantReply: String?
    @Published private(set) var liveAssistantText: String    // accumulating deltas this turn
    @Published private(set) var isPTTActive: Bool

    init()                       // builds services, wires callbacks, controller.start()
    func startSessionIfNeeded()  // spawn claude if stopped and projectDir chosen
    func newSession()            // clear lastSessionID, restart claude, transcript system-note
    func sendUserText(_ text: String)   // transcript .user entry + startSessionIfNeeded + claude.send
    func interruptClaude()
    func chooseProjectDirectory()       // NSOpenPanel (directories only) → config.projectDir + restart session
    func speakLastReply()
}
```

Behavior spec:
- **Button dispatch**: `controller.onButtonDown` looks up `configStore.config.mapping[button]`:
  `.pushToTalk` → PTT-start; every other action fires on DOWN. `onButtonUp` only matters for `.pushToTalk` → PTT-stop.
- **PTT-start**: `tts.stop()`; `speech.requestPermissionsIfNeeded()` (async) then `speech.startListening()`; `isPTTActive = true`; status `.listening`; haptic tick (0.5, 0.05s).
- **PTT-stop**: `speech.stopListening { text in … }`; `isPTTActive = false`; empty/nil → status back to idle + double haptic buzz (error); text → `sendUserText(text)`.
- **Actions**: approve → `sendUserText("Yes")`; reject → `sendUserText("No")`; sendPrompt(p) → `sendUserText(p)`; interrupt → `claude.interrupt()` + haptic; stopSpeaking → `tts.stop()`; replayLastReply → `speakLastReply()`; toggleTTS → flip config + if now off `tts.stop()`; newSession/showWindow as named (`showWindow`: `NSApp.activate(ignoringOtherApps: true)` + unminiaturize key window).
- **Claude events → UI**: textDelta appends `liveAssistantText`; assistantMessage appends a `.assistant` transcript entry (and clears `liveAssistantText`); toolUse appends `.tool` entry "Name — detail"; turnCompleted: set `lastAssistantReply = resultText` (only when non-error, non-empty), status timeline (below), success haptic (0.8, 0.1) + if `ttsEnabled` speak `TTSService.speechText(fromMarkdown: resultText, maxChars: config.maxSpokenChars)`; error subtype → `.error` transcript entry. ready → store `config.lastSessionID = sessionID`, `.system` entry "Session started (model)". processError → `.error` entry. terminated → status recompute; if termination was unexpected (not user-initiated stop) AND we were resuming, retry ONCE without `resumeSessionID` (covers stale session ids).
- **Status derivation** (single function, called on every change): noController if `!controller.isConnected`; else listening if `isPTTActive`; else speaking if `tts.isSpeaking`; else thinking if `claude.state == .working`; else idle. On status change: set light color per `AppStatus` table (respect `config.lightEnabled`).
- TTS `onFinished` → recompute status.
- Config changes to model/permissionMode/projectDir take effect on next session start; MappingView/Settings edits mutate `configStore.config` directly.

## Module: Entry — PowerUpApp.swift

```swift
@main struct PowerUpApp: App   // @StateObject AppState
```
- `WindowGroup("PowerUp")` → `MainView().environmentObject(appState)` (+ its sub-objects as environmentObjects: configStore, controller, speech, tts, claude — inject ALL so views can observe any of them directly), min size 980×640.
- `Settings` scene → `SettingsView()` with the same environment objects.
- `.commands`: an app menu item "New Claude Session" (⌘N → appState.newSession()).

## Modules: MainUI / SettingsUI

Aesthetic: dark, premium "gamer-meets-developer" look. Dark gradient background
(near-black blue), one accent (electric blue #3B82F6-ish), monospaced font for
code/tool lines, rounded cards, subtle borders (white 8%). Use only system
capabilities (SF Symbols, gradients, materials). No external assets.

**MainView.swift** — `struct MainView: View` (uses environment objects only):
- Toolbar: project folder picker button (shows current dir name; calls `appState.chooseProjectDirectory()`), session status pill, "New Session" button, Interrupt button (prominent while thinking), Settings gear (opens the Settings scene via `SettingsLink` or selector fallback).
- Left sidebar (~280pt): controller card (big gamecontroller SF symbol, name, connection dot, battery gauge, DualSense badge), status card (`AppStatus.label` + colored dot matching light-bar color), quick legend of current mappings (button glyph → action name, from config).
- Center: transcript list (ScrollViewReader auto-scroll to bottom): chat bubbles — user right-aligned accent, assistant left neutral card w/ markdown-ish plain text, tool entries as compact monospaced rows with icon, system/error entries as centered captions (error = red). While `claude.state == .working` and `liveAssistantText` non-empty, show it as a live "typing" bubble with a subtle pulsing indicator.
- Bottom bar: TextField for typed input (submit → `appState.sendUserText`), send button; big circular PTT indicator that glows red + shows `speech.partialTranscript` while `isPTTActive`.
- Empty states: no projectDir → centered call-to-action card "Choose a project folder"; no controller → hint card with pairing instructions (System Settings → Bluetooth, hold PS+Create).

**ComponentViews.swift**: the reusable bits used above (StatusPill, ControllerCard, BatteryGauge, TranscriptBubble, ToolRow, PTTIndicator, MappingLegendRow, card/background styles). Keep every view small.

**SettingsView.swift** — `struct SettingsView: View`: `TabView` with tabs:
- General: project dir (path + Choose…), model Picker (default/sonnet/opus/haiku/fable), permission mode Picker with one-line explanations (acceptEdits recommended; bypassPermissions row in red "auto-approves everything"), claude binary path override (TextField + auto-detected path shown), session id (read-only) + "New Session" button.
- Voice: TTS enabled toggle, voice Picker from `tts.availableVoices`, rate Slider (0.3–0.7), max spoken chars Stepper, "Test voice" button; STT locale TextField ("en-US"), on-device toggle, speech auth status + "Request permissions" button.
- Buttons: embeds `MappingView()`.
- Feedback: haptics toggle, light bar toggle.

**MappingView.swift** — `struct MappingView: View`: a List/Table of all `ControllerButton.allCases`: symbol + name | Picker of actions (none/pushToTalk/approve/reject/interrupt/stopSpeaking/replayLastReply/toggleTTS/newSession/showWindow/sendPrompt) | when `.sendPrompt`, an inline TextField editing the prompt text. Footer: "Reset to Defaults" button → `configStore.resetMappingToDefault()`. Live-highlight rows while their physical button is held (observe `controller` via a lightweight `@Published` last-pressed passthrough is NOT in the contract — instead highlight via `onButtonDown` is owned by AppState; MappingView just shows static rows. Keep it simple.). Edits write straight to `configStore.config.mapping`.

## Module: Foundation — scripts/build.sh + README.md

`scripts/build.sh` (bash, `set -euo pipefail`, run from repo root):
1. `swift build -c release --arch arm64`
2. Assemble `build/PowerUp.app/Contents/{MacOS,Resources}`; copy binary; `PkgInfo` = `APPL????`.
3. Write `Contents/Info.plist`: CFBundleExecutable=PowerUp, CFBundleIdentifier=`com.powerup.claudepad` (STABLE — never change), CFBundleName=PowerUp, CFBundleDisplayName=PowerUp, CFBundlePackageType=APPL, CFBundleShortVersionString=1.0, CFBundleVersion=1, LSMinimumSystemVersion=14.0, NSHighResolutionCapable=true, NSPrincipalClass=NSApplication, GCSupportsControllerUserInteraction=true, NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription (friendly strings).
4. `codesign --force --deep --sign - build/PowerUp.app`
5. Print: `open build/PowerUp.app` reminder (never run the raw binary — TCC misattribution).

README.md: what it is, requirements (macOS 14+, claude CLI logged in, DualSense paired via Bluetooth), build (`./scripts/build.sh`), first-run (permissions prompts on first push-to-talk), default mapping table, configuration (Settings + `~/Library/Application Support/PowerUp/config.json`), troubleshooting (tccutil reset Microphone/SpeechRecognition com.powerup.claudepad; controller not responding in background → it's handled, but re-pair steps; claude not found → Settings path override), how sessions/resume work, cost display note.

## Cross-cutting rules

- Every service is `@MainActor`; background work (process I/O, audio taps, recognition callbacks) hops to the main actor before touching published state or invoking the callbacks in these contracts.
- No force-unwraps of anything that can be nil at runtime (optionals from GameController, JSON fields, file I/O). No `fatalError` outside truly impossible paths.
- No third-party dependencies; no new files beyond the layout above.
- Swift 5.9-compatible code ONLY (no typed throws, no noncopyable generics, nothing from Swift 5.10+).
- Keep user-facing strings friendly; the user may be new to some tooling.

---

# v1.1 addendum — TTS overhaul + session-control button actions

This section SUPERSEDES anything above where they conflict. Everything here was
verified live against claude CLI v2.1.243 on this machine on 2026-08-24.

## A. Verified control-request protocol (replaces all earlier control_request info)

All control requests use the nested envelope. `request_id` is any unique string
(use `UUID().uuidString`). The CLI acknowledges every request on stdout:

```json
→ {"type":"control_request","request_id":"R1","request":{"subtype":"interrupt"}}
← {"type":"control_response","response":{"subtype":"success","request_id":"R1","response":{"still_queued":[]}}}

→ {"type":"control_request","request_id":"R2","request":{"subtype":"set_model","model":"sonnet"}}
← {"type":"control_response","response":{"subtype":"success","request_id":"R2"}}
   (also emits a type:"user" message whose content is a plain STRING like
   "<local-command-stdout>Set model to sonnet (claude-sonnet-5)</local-command-stdout>" — ignore it;
   NOTE: user-message content can be a STRING, not always an array — the parser must not assume array)

→ {"type":"control_request","request_id":"R3","request":{"subtype":"set_permission_mode","mode":"plan"}}
← {"type":"control_response","response":{"subtype":"success","request_id":"R3","response":{"mode":"plan"}}}

→ unknown subtypes (e.g. set_effort — DOES NOT EXIST) are SAFE:
← {"type":"control_response","response":{"subtype":"error","request_id":"…","error":"Unsupported control request subtype: set_effort"}}
```

- The FLAT shape `{"type":"control_request","subtype":"…"}` KILLS the process (exit 1). Never send it.
- `set_model` and `set_permission_mode` apply LIVE mid-session — no restart needed.
- There is NO live effort switch. Changing effort = restart the process with
  `--effort <level>` + `--resume <sessionID>` (conversation is preserved).
- After a set_model, later `system/init` events carry the new model — refresh `modelName` from them.

## B. Contract changes — Models.swift

`ControllerAction` gains three cases (keep ALL existing cases including sendPrompt):
```swift
case cycleModel            // displayName "Cycle Model"
case cycleEffort           // displayName "Cycle Effort"
case cyclePermissionMode   // displayName "Cycle Permission Mode"
```

`AppConfig` gains:
```swift
var effort: String            // "default" (= omit --effort flag) | "low" | "medium" | "high" | "xhigh"; default "default"
var modelCycle: [String]      // default ["sonnet", "opus", "haiku", "fable"] — aliases cycleModel steps through
```
Give both properties decode defaults (custom `init(from:)` with
`decodeIfPresent` fallbacks for JUST these two new keys is acceptable — or a
wrapper — so existing config.json files keep decoding; all other keys unchanged).
Effort cycle order (fixed, not configurable): low → medium → high → xhigh → low….
Permission-mode cycle order (fixed): acceptEdits → plan → default → acceptEdits…
(bypassPermissions is deliberately EXCLUDED from the cycle — a stray button press
must never escalate to auto-approve-everything; it stays available in Settings).
`maxSpokenChars`: 0 now means "no limit" (speechText already returns full text
when maxChars <= 0); default for fresh configs becomes 1500.
Default mapping changes: l3 → cycleModel, r3 → cycleEffort, touchpad → cyclePermissionMode
(previously .none; all other defaults unchanged).

## C. Contract changes — ClaudeService.swift

```swift
func start(projectDir: URL, model: String, permissionMode: String, effort: String,
           resumeSessionID: String?, claudePathOverride: String?)
    // appends "--effort", effort when effort != "default"
func interrupt()                       // NESTED envelope + UUID request_id (fatal-flat-shape fix)
func setModel(_ model: String)         // control_request set_model
func setPermissionMode(_ mode: String) // control_request set_permission_mode
```

`ClaudeEvent` gains:
```swift
case controlResult(action: String, ok: Bool, detail: String)
// action: "interrupt" | "set_model" | "set_permission_mode" (the subtype sent)
// emitted by parsing type:"control_response" lines — match response.request_id
// against a [String: String] map of in-flight request ids → subtype recorded when sending;
// ok = (response.subtype == "success"); detail = error text when !ok, "" when ok.
// Unmatched request ids → ignore. Clear the in-flight map on process termination.
```
`modelName` must refresh from every `system/init` (not just the first).
The stdout parser must tolerate `type:"user"` messages whose `content` is a
plain string (see A) — current array assumption must not crash (it already
ignores user messages; just ensure no force-cast).

## D. Contract changes — TTSService.swift (the "voice readout" fix)

Voice selection was picking the legacy robotic "compact Samantha" (and could
pick novelty voices like Zarvox/Bubbles on some machines). New rules:

```swift
static func rankedVoices() -> [AVSpeechSynthesisVoice]
// All en-* voices, EXCLUDING: voiceTraits.contains(.isNoveltyVoice),
// identifiers containing "eloquence", and the legacy bucket
// (identifier hasPrefix "com.apple.speech.synthesis.voice").
// Sorted: quality desc (premium 3 > enhanced 2 > default 1),
// then Samantha first among defaults, then name asc.
```
- `resolveVoice(voiceID:)`: explicit voiceID if installed → else `rankedVoices().first`
  → else `AVSpeechSynthesisVoice(language: "en-US")`.
- `availableVoices` = `rankedVoices()` mapped to `Voice` (same struct); novelty/
  legacy/eloquence voices are NOT listed.
- speak() unchanged otherwise. speechText unchanged.

## E. Contract changes — AppState.swift behavior

New action handling (all fire on button DOWN; all give haptic tick 0.5/0.05):
- `.cycleModel`: advance `config.model` to the next entry of `config.modelCycle`
  (if current not in list, go to first; empty list → first of the default list).
  If `claude.state` is `.ready`/`.working` → `claude.setModel(newAlias)` (live).
  Transcript `.system` entry "Model → sonnet". Announce (below).
- `.cycleEffort`: advance `config.effort` through the fixed cycle. If claude is
  `.working` → transcript note "Effort → high (applies when this turn finishes)"
  and set a private `pendingEffortRestart = true`, honored on the next
  `.turnCompleted` (restart with resume). Otherwise restart now with
  `--resume` current sessionID (conversation preserved). Announce.
- `.cyclePermissionMode`: advance `config.permissionMode` through the fixed
  cycle; if running → `claude.setPermissionMode(mode)` (live). Transcript note. Announce.
- Announce = if `config.ttsEnabled`: `tts.speak(shortPhrase, voiceID:…, rate:…)`
  with phrases like "Model: Sonnet", "Effort: high", "Permissions: plan"
  (plain text, NOT run through speechText). If TTS disabled: transcript+haptic only.
- `.controlResult(action:ok:detail:)` handling: ok → nothing extra (the optimistic
  transcript entry already covered it). !ok → `.error` entry
  "Couldn't apply <action>: <detail>" + errorHaptic + REVERT the corresponding
  config field to what the CLI last confirmed (keep a small `lastConfirmed`
  snapshot per field, seeded at session start).
- Session spawn passes `effort: config.effort` through to `claude.start`.

## F. UI changes

- **MainView toolbar**: add a compact "session chips" cluster showing current
  model (claude.modelName ?? config.model), effort, and permission mode — small
  capsule chips, monospaced, so controller-driven changes are instantly visible.
- **MappingView**: the action Picker gains the three new kinds, grouped:
  Conversation (approve/reject/sendPrompt), Voice (pushToTalk/stopSpeaking/replayLastReply/toggleTTS),
  Session (interrupt/newSession/cycleModel/cycleEffort/cyclePermissionMode), App (showWindow/none).
  (Plain sections in one Picker menu are fine.)
- **SettingsView General tab**: add an Effort picker (default/low/medium/high/xhigh)
  and a "Model cycle" comma-separated TextField editing `config.modelCycle`
  (trim whitespace, drop empties; show hint "Aliases the Cycle Model button steps through").
- **SettingsView Voice tab**: max-spoken-chars Stepper now allows 0 with the
  label suffix "(0 = no limit)". Add a hint card: "For a much nicer voice,
  download an Enhanced or Premium voice (System Settings → Accessibility →
  Spoken Content → System Voice → Manage Voices…), then pick it here." with an
  "Open Voice Settings" button:
  `NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.universalaccess")!)`.
- **README.md**: document the new actions, the new default mappings for
  L3/R3/touchpad, the voice-quality tip, effort restart semantics (session is
  resumed, nothing is lost), and correct the interrupt description if needed.

---

# v1.2 addendum — multilingual TTS + dictate-to-draft

Supersedes anything above where they conflict. Two changes only.

## A. Multilingual TTS (Chinese replies are currently silent)

Root cause: voice resolution always returns an `en-*` voice; AVSpeechSynthesizer
speaks nothing (or garbage) when handed CJK text with an English voice.

TTSService.swift contract changes (import NaturalLanguage, macOS 10.14+):

```swift
static func dominantLanguageCode(of text: String) -> String?
// NLLanguageRecognizer.dominantLanguage(for:) → primary code ("en","zh","ja",…);
// map NLLanguage.simplifiedChinese → "zh-Hans" handling: return the raw
// NLLanguage rawValue's primary subtag lowercased ("zh" for both zh-Hans/zh-Hant).

static func rankedVoices(languagePrefix: String) -> [AVSpeechSynthesisVoice]
// generalization of rankedVoices(): same exclusions (novelty traits, "eloquence",
// legacy "com.apple.speech.synthesis.voice" prefix), filtered to voices whose
// language's primary subtag matches languagePrefix; sort quality desc, then name.
// Keep rankedVoices() (en) delegating to this.
```

`speak(_:voiceID:rate:)` new resolution order:
1. `lang = dominantLanguageCode(of: text) ?? "en"`.
2. If `voiceID` is set AND that voice exists AND its language primary subtag == lang → use it.
3. Else `rankedVoices(languagePrefix: lang).first`.
4. Else `AVSpeechSynthesisVoice(language: fallbackBCP47(lang))` where fallbackBCP47
   maps "zh"→"zh-CN", "ja"→"ja-JP", "ko"→"ko-KR", "en"→"en-US", else "\(lang)-\(lang.uppercased())" attempt then nil.
5. Else fall back to the existing en chain (so speech never silently no-ops).

`availableVoices` (Settings picker): now ALL installed voices passing the
exclusion rules, any language — sorted language asc, quality desc, name asc;
`Voice.name` becomes "Name (language) · Quality" e.g. "Tingting (zh-CN) · Default".
(An explicitly picked voice still yields to language routing on mismatch — rule 2.)

`speechText(fromMarkdown:maxChars:)`: localize the two injected phrases by
detected language of the INPUT text: zh → "（代码已省略）" and "……回复已截断。";
everything else keeps "code omitted" / "… reply truncated.". Signature unchanged.

AppState announcements ("Model: …") are English constants — rule 1 detects en; no change needed.

## B. Dictate-to-draft with manual send

New ControllerAction cases (keep all existing):
```swift
case pushToTalkDraft   // hold: dictate into the prompt box; nothing is sent
case sendDraft         // send the prompt box's current text
// displayName: "Dictate to Prompt Box", "Send Prompt Box"
// isHoldAction is now: self == .pushToTalk || self == .pushToTalkDraft
```
Default mapping additions (fresh configs only): l2 → pushToTalkDraft, ps → sendDraft.
(README: note PS button may be reserved by the system in some setups; remap freely.)

AppState contract changes:
```swift
@Published var draftText: String          // the main window's input box text (moved from MainView local @State)
func sendDraft()                          // trimmed draftText non-empty → sendUserText(it), clear draftText;
                                          // empty → errorHaptic only
```
Behavior:
- AppState tracks a private `enum PTTMode { case send, draft }` for the active hold.
  Button DOWN with .pushToTalk → mode .send (existing flow, unchanged).
  DOWN with .pushToTalkDraft → mode .draft: tts.stop(), permissions, startListening,
  isPTTActive = true, status .listening, same haptic tick. A second hold press of
  either kind while one is active is ignored. Button UP only acts if it matches the active mode.
- Draft dictation is LIVE: on .draft DOWN, snapshot `draftBase = draftText`
  (+ " " separator if non-empty). While listening, observe
  `speech.$partialTranscript` (Combine sink, stored cancellable) and set
  `draftText = draftBase + partial` as partials arrive (only while mode == .draft).
  On UP: stopListening completion sets `draftText = draftBase + (finalText ?? lastShown)`;
  empty result → restore `draftText = original snapshot` + errorHaptic. NOTHING is sent.
- .sendDraft action → `sendDraft()`.
- MainView: the bottom-bar TextField binds to `$appState.draftText` (delete the
  local @State; keyboard submit calls `appState.sendDraft()` so typed and
  dictated text share one path; the send button likewise).
- MappingView picker: pushToTalkDraft joins the Voice group, sendDraft the
  Conversation group.
- README: document the review-then-send flow (hold L2 → words appear in the box →
  edit if needed → press the Send Prompt Box button or Enter).

---

# v1.3 addendum — layout defaults, slim controls list, top info bar, app icon, live chips

Supersedes anything above where they conflict. Four changes.

## A. Default mapping changes (Models.swift)

defaultMapping() changes ONLY these entries (all else unchanged):
| Button | Action |
|---|---|
| l2 | pushToTalkDraft (unchanged from v1.2) |
| l1 | sendDraft (was replayLastReply) |
| r2 | pushToTalk (unchanged) |
| ps | none (sendDraft moved to l1) |
replayLastReply simply has no default button now (still fully mappable).
README: update the default-mapping table; the three "core controls" story is
L2 = dictate to prompt box, L1 = send prompt box, R2 = talk straight to Claude.

## B. Main-window layout restructure (MainView.swift + ComponentViews.swift)

Goal: session/status info moves from the left sidebar to a TOP INFO BAR inside
the window content (NOT inside .toolbar — toolbar item refresh quirks are part
of the staleness bug); the sidebar shrinks to a compact "Controls" card.

- **Top info bar** (a horizontal strip directly under the title bar area, full
  width, above the transcript): controller chip (gamecontroller symbol + name +
  connection dot + battery %), status pill (existing colored-dot style), the
  model/effort/permission chips (moved OUT of .toolbar into this bar), and
  total cost. It must be built from small subviews that each declare the
  @EnvironmentObjects they read (controller, claude, configStore, appState) so
  every value re-renders live. Wrap in the existing card styling; keep it one
  row (HStack, Spacer-separated groups) that gracefully truncates.
- **Toolbar** keeps only: project folder picker, New Session, Interrupt, Settings gear.
- **Left sidebar** becomes a narrow (~240pt) single "Controls" card listing ONLY,
  in this order, each as glyph + short label:
  1. the button(s) mapped to pushToTalkDraft  → "Dictate to prompt box (hold)"
  2. the button(s) mapped to sendDraft        → "Send prompt box"
  3. the button(s) mapped to pushToTalk       → "Talk to Claude (hold)"
  4. button(s) → cycleModel  → "Change model"
  5. button(s) → cycleEffort → "Change effort"
  6. button(s) → cyclePermissionMode → "Change permission mode"
  Rows derive LIVE from configStore.config.mapping (reverse lookup; a row is
  hidden when nothing maps to its action). Below the rows: an "All Buttons…"
  button opening a SHEET (on MainView) — a controller cheat sheet: every
  ControllerButton (all 18, in a stable order), glyph + button name + mapped
  action displayName (or "—" for none), plus a footer hint "Edit in Settings →
  Buttons". Reuse existing row/card components where sensible. Pairing hint and
  no-project empty states stay as they are (pairing hint may live under the
  Controls card in the slim sidebar).

## C. Live chips fix (the "top info sometimes stale" bug)

Root cause 1: after a Cycle Model press, ClaudeService.modelName only refreshes
on the NEXT system/init (i.e. next turn), so the chip lags. Fix in
ClaudeService: on a successful set_model control_response, immediately set
modelName to the acked value (the in-flight map already carries it).
Root cause 2: chips lived in .toolbar items (macOS toolbar closures have
observation quirks) — solved structurally by section B's move into the content
hierarchy.
Chip display rules (in the new top bar): model chip shows config.model unless
it's "default", else claude.modelName ?? "default" — config.model changes
instantly on cycle, so the chip is optimistic/live; effort + permission chips
read config directly. Battery text refreshes from the existing 60s poll (also
refresh battery immediately inside the poll timer setup AND on connect — verify
it already does).

## D. App icon (scripts/ + build.sh)

New file `scripts/IconGen.swift` — a standalone CLI program (AppKit +
CoreGraphics, compiled with swiftc at build time) that renders the icon and
writes a finished `.icns`:
- 1024×1024 canvas, transparent background. Draw the macOS-style squircle
  (rounded rect 832×832 centered, corner radius ~186, NSBezierPath) filled with
  a diagonal gradient: deep navy (#0B1220) bottom-left → indigo (#1E3A8A) →
  electric blue (#3B82F6) top-right, plus a subtle lighter radial glow top-left.
- Centered white "gamecontroller.fill" SF Symbol (NSImage(systemSymbolName:),
  ~440pt, weight .medium, white, slight drop shadow). If symbol lookup fails,
  fall back to drawing a simple white rounded "PU" text monogram — never fail.
- Emit PNGs at 16/32/64/128/256/512/1024 (and @2x pairs) into a temp
  AppIcon.iconset via NSBitmapImageRep, then run iconutil -c icns to produce
  the final AppIcon.icns at the output path given as CommandLine argument.
`scripts/build.sh` additions: if `build/AppIcon.icns` is missing (or
`REGEN_ICON=1`), `swiftc scripts/IconGen.swift -o <tmp>/icongen && icongen
build/AppIcon.icns`; copy it to `Contents/Resources/AppIcon.icns`; add
`CFBundleIconFile = AppIcon` to the generated Info.plist. Keep the script
`set -euo pipefail`-clean.

---

# v1.4 addendum — Remote Control mode (drive cmux / terminal Claude Code sessions)

Supersedes anything above where they conflict. All protocol facts verified live
on this machine on 2026-08-25.

## Verified facts (ground truth)

- cmux is installed (/Applications/cmux.app) with a CLI at
  `/Applications/cmux.app/Contents/Resources/bin/cmux` controlling the app over
  a Unix socket. Verified: `cmux ping` → "PONG"; `cmux list-workspaces` (alias
  of `cmux workspace list`) prints lines like
  `* workspace:11  ⠐ Build PS5 controller voice app  [selected]` (leading `*` +
  `[selected]` mark the selected workspace; a legacy-alias notice line may
  precede output — suppress with env CMUX_QUIET=1); `cmux send [--workspace R]
  [--surface R] <text>` types text into a terminal surface; `cmux send-key
  [--workspace R] <key>` sends keys — verified help shows examples `enter`,
  `ctrl+c` (so `escape`, `shift+tab` use the same naming). No Accessibility
  permission needed for cmux.
- Claude Code hooks (v2.1.243, verified by live runs): `Stop` hook stdin JSON
  includes `hook_event_name:"Stop"`, `session_id`, `cwd`, `permission_mode` and
  **`last_assistant_message`** (the full final reply text — no transcript
  parsing needed). `UserPromptSubmit` hook stdin includes
  `hook_event_name:"UserPromptSubmit"`, `session_id`, `cwd`, `prompt`.
  `Notification` hook (not live-tested; per docs) includes `message`. Hooks
  configured in `~/.claude/settings.json` fire for EVERY claude session of this
  user — including sessions inside cmux (cmux wraps the same claude CLI) and
  PowerUp's own built-in session.

## Concept

`config.controlMode`: `"builtin"` (today's behavior, default) or `"remote"`.
In remote mode PowerUp does NOT run its own claude; instead controller/voice
input is delivered INTO an existing session (cmux surface, or any app via
keystroke injection), and replies come BACK via Claude Code hooks posting to a
local HTTP listener → TTS, transcript, lights, haptics as usual.

## Models.swift additions

```swift
// AppConfig new fields (all with decode-tolerant defaults like effort/modelCycle):
var controlMode: String          // "builtin" | "remote"; default "builtin"
var remoteTargetKind: String     // "cmux" (default) | "frontmost" | "app"
var remoteCmuxWorkspace: String? // "workspace:11" etc.; nil = auto (the [selected] one)
var remoteCmuxSurface: String?   // optional surface ref
var remoteAppBundleID: String?   // target for kind "app"
var remoteAutoSubmit: Bool       // default true — press Enter after typed text
var listenerPort: Int            // default 48738
var listenerToken: String        // default "" — ConfigStore.init MUST replace "" with UUID().uuidString and save

// New ControllerAction case:
case toggleControlMode           // displayName "Toggle Built-in / Remote"
```

## New file: RemoteControlService.swift

```swift
@MainActor final class RemoteControlService: ObservableObject {
    enum RemoteKey { case enter, escape, shiftTab }
    @Published private(set) var axTrusted: Bool          // AXIsProcessTrusted()
    @Published private(set) var cmuxAvailable: Bool      // binary found AND ping == PONG
    @Published private(set) var cmuxWorkspaces: [CmuxWorkspace]  // struct: ref, title, selected
    func refreshStatus()                                 // async probe: ping, AX, workspace list
    func requestAXTrust()                                // AXIsProcessTrustedWithOptions prompt
    func sendText(_ text: String, submit: Bool, config: AppConfig,
                  completion: @escaping (String?) -> Void)   // nil = ok, else user-facing error
    func sendKey(_ key: RemoteKey, config: AppConfig,
                 completion: @escaping (String?) -> Void)
}
```
- cmux route (kind "cmux"): resolve the binary (`/Applications/cmux.app/Contents/Resources/bin/cmux`,
  else `command -v cmux`). Workspace = config.remoteCmuxWorkspace, or when nil
  parse `list-workspaces` for the `[selected]` row at send time. Run
  `cmux send --workspace REF [--surface REF] -- TEXT` then, if submit,
  `cmux send-key --workspace REF [--surface REF] enter`. Keys: enter/escape/shift+tab.
  Env CMUX_QUIET=1. Process runs off-main (utility queue), completion hopped to
  main. Nonzero exit → completion(stderr tail).
- Injection route (kinds "frontmost"/"app"): requires axTrusted, else
  completion("Grant Accessibility access in Settings → Remote"). For "app":
  NSRunningApplication(bundleIdentifier).activate + 150ms delay. Type text via
  CGEvent(keyboardEventSource:) + CGEventKeyboardSetUnicodeString in chunks of
  ≤20 UTF-16 units (keyDown+keyUp per chunk, ~2ms spacing, posted to
  .cgSessionEventTap); enter = keycode 36, escape = 53, shiftTab = 48 with
  .maskShift. All posting on a background queue.

## New file: RemoteListener.swift

```swift
@MainActor final class RemoteListener: ObservableObject {
    @Published private(set) var isRunning: Bool
    @Published private(set) var lastError: String?
    var onEvent: ((RemoteHookEvent) -> Void)?            // main actor
    func start(port: UInt16, token: String)              // idempotent restart on port/token change
    func stop()
}
struct RemoteHookEvent {                                  // lives in RemoteListener.swift
    enum Kind { case stop, userPromptSubmit, notification }
    let kind: Kind; let text: String?    // last_assistant_message / prompt / message
    let sessionID: String?; let cwd: String?
}
```
Network.framework NWListener bound to 127.0.0.1 ONLY. Minimal HTTP: accept
POST /event with header `X-PowerUp-Token: <token>` (403 otherwise, 404 other
paths), body = the hook's stdin JSON verbatim; map hook_event_name → Kind;
respond `204 No Content` immediately. Tolerate garbage bodies silently.
Connection handling fully defensive; listener failure sets lastError, never crashes.

## New file: HookInstaller.swift

```swift
enum HookInstaller {
    static func hookScriptURL() -> URL        // ~/Library/Application Support/PowerUp/powerup-hook.sh
    static func writeHookScript(port: Int, token: String) throws  // rewrite every install
    static func isInstalled() -> Bool         // ~/.claude/settings.json Stop hooks contain our script path
    static func install(port: Int, token: String) throws
    static func uninstall() throws
}
```
Hook script (bash, chmod +x): body posts stdin to the listener without delaying
Claude: `curl -s -o /dev/null --max-time 1 -X POST -H "Content-Type: application/json" -H "X-PowerUp-Token: TOKEN" --data-binary @- "http://127.0.0.1:PORT/event" & exit 0`
— note stdin must be handed to curl before backgrounding (read into a var with
`payload=$(cat)` then `--data-binary "$payload"` in the backgrounded curl; ALWAYS exit 0).
install(): read ~/.claude/settings.json via JSONSerialization (invalid JSON →
throw with clear message, DO NOT touch the file; missing file → start from {});
back up to settings.json.powerup-backup-<timestamp-free counter n>; append to
hooks.Stop, hooks.UserPromptSubmit, hooks.Notification a matcherless group
`{"hooks":[{"type":"command","command":"<script path>"}]}` — idempotent (skip
arrays already containing the script path); preserve every unknown key
verbatim. uninstall(): remove only entries whose command == our script path,
pruning empty groups/arrays.

## AppState wiring

- New members: `let remote: RemoteControlService`, `let listener: RemoteListener`,
  `@Published private(set) var remoteTurnActive: Bool`.
- init: ensure config.listenerToken non-empty (ConfigStore does it; assert-not-crash),
  start listener with config port/token, wire onEvent; observe port/token
  changes → restart listener.
- **Routing in remote mode** (`config.controlMode == "remote"`): sendUserText →
  remote.sendText(text, submit: config.remoteAutoSubmit) (transcript .user entry
  kept; on error → .error entry + errorHaptic). approve → sendKey(.enter);
  reject/interrupt → sendKey(.escape); newSession → sendText("/clear", submit true);
  cycleModel → advance config.model then sendText("/model <alias>", submit true);
  cycleEffort → advance config.effort then sendText("/effort <level>", submit true)
  (if the target CLI lacks /effort it prints an error there — harmless);
  cyclePermissionMode → sendKey(.shiftTab) (interactive Claude Code cycles
  permission modes with Shift+Tab) — do NOT change config.permissionMode in
  remote mode (we can't know the resulting mode); transcript note "Permission
  mode cycled (see session)". PTT/draft flows unchanged — they terminate in
  sendUserText/sendDraft which route as above.
- **Mode switching** (.toggleControlMode action + Settings): builtin→remote:
  claude.stop() (expected termination), transcript note, announce "Remote
  control"; remote→builtin: announce "Built-in session", claude restarts
  lazily on next send (existing startSessionIfNeeded path).
- **Listener events** (only honored while in remote mode; ALWAYS ignore events
  whose sessionID == claude.sessionID to avoid echo from our own spawned
  session): userPromptSubmit → remoteTurnActive = true; stop →
  remoteTurnActive = false, transcript .assistant entry (prefix "[<cwd
  basename>] " when cwd differs from config.projectDir), lastAssistantReply =
  text (so replayLastReply works), success haptic, TTS speak via the existing
  speechText pipeline + config gates; notification → transcript .system entry +
  (if ttsEnabled) speak "Claude needs your attention".
- Status derivation: in remote mode `thinking` when remoteTurnActive (claude.state
  is .stopped there); other statuses unchanged.

## UI

- **Top info bar**: new mode chip FIRST in the chips cluster: "Built-in" or
  "Remote · cmux ws 11" / "Remote · <app name>" / "Remote · frontmost";
  in remote mode the model/effort chips stay (they now reflect what the cycle
  buttons will send) but the permission chip shows "—" (unknown remotely).
- **SettingsView**: new "Remote" tab: mode picker (Built-in / Remote) with a
  sentence explaining each; target section (kind picker; for cmux: availability
  dot + workspace Picker fed by remote.cmuxWorkspaces with an "Auto (selected
  workspace)" nil option + Refresh button + optional surface TextField; for
  app: Picker over NSWorkspace.shared.runningApplications where
  activationPolicy == .regular, storing bundle id; frontmost: caption only);
  auto-submit toggle; Accessibility row (status + Grant Access button + caption
  "cmux targets don't need this"); Read-back section: listener status dot +
  port field + "Install Claude Code hooks" / "Uninstall hooks" buttons with
  isInstalled() status + caption explaining hooks give voice read-back from ANY
  terminal/cmux Claude session (install button also rewrites the script with
  current port/token and restarts the listener).
- **MappingView**: toggleControlMode joins the Session group.
- **README**: full section on Remote Control mode (what it does, cmux
  first-class, hooks install + what gets modified + backups, Accessibility only
  for non-cmux targets, port/token, troubleshooting: curl-test command).

## Safety rails for implementers/integrators

Read-only cmux commands (ping/capabilities/list-workspaces/--help) are fine to
run. NEVER run `cmux send`/`send-key` against the user's real workspaces. The
integrator MAY verify the cmux round-trip ONLY via a disposable workspace:
`cmux new-workspace --name powerup-test --command cat --focus false` → send
text → `read-screen` to confirm → `close-workspace` on it — and MUST clean it
up. Never modify ~/.claude/settings.json during tests (test HookInstaller merge
logic against a COPY in a temp dir via dependency-injected path or careful review).

---

# v1.5 addendum — input ordering fix, remote terminal targets, clearer AX guidance

Supersedes anything above where it conflicts. Three fixes.

## A. Controller input ordering + de-dup (fixes the "two buttons at once bugs out")

Root cause (verified in code): ControllerService.wireButtons dispatches each
pressedChangedHandler event via an unstructured `Task { @MainActor in … }`, which
has NO ordering guarantee. Pressing a trigger + another button near-simultaneously
(or analog L2/R2 jitter across the press threshold) can deliver a button's `up`
Task before its `down` Task, leaving PTT started-but-never-stopped (mic + status
wedged). Fixes in ControllerService.swift:
1. Set `controller.handlerQueue = .main` explicitly when a controller connects.
2. In `wire(...)`, replace the `Task { @MainActor [weak self] in … }` hop with a
   SYNCHRONOUS `MainActor.assumeIsolated { … }` block (valid because the handler
   now runs on the main queue) so events are processed in exact delivery order.
   Keep the `[weak controller]` capture + `currentController === controller` guard.
3. Add `private var pressedButtons: Set<ControllerButton> = []`. In the handler:
   on `pressed == true`, ignore if already in the set, else insert and call
   `onButtonDown`; on `pressed == false`, ignore if not in the set, else remove
   and call `onButtonUp`. This de-dups analog-trigger threshold jitter and any
   duplicate events. Clear `pressedButtons` on disconnect and when (re)wiring.
4. On disconnect: after clearing state, also emit `onButtonUp` for any buttons
   still in `pressedButtons` BEFORE clearing (so AppState can release a stuck
   hold if the pad drops mid-press), then clear the set.

AppState safety net (AppState.swift): add `func forceReleaseHold()` that, if
`isPTTActive`/`pttHoldButton != nil`, clears `pttHoldButton` and calls
`stopPushToTalk()`; call it from the controller disconnect observer path (wire a
new `controller.onDisconnect: (() -> Void)?` callback in ControllerService that
AppState sets — set it in init next to onButtonDown/onButtonUp). This guarantees
a dropped controller can never strand the recorder.

## B. Remote terminal targets (fixes "voice not typing into the remote app" + "terminal for remote input")

Context: the two delivery routes are (1) the **cmux socket** (`cmux send`) which
needs NO permission, and (2) **keystroke injection** (CGEvent) into a frontmost/
specific app which REQUIRES Accessibility. The user was on an injection target
without Accessibility, so nothing typed. Changes:

Models.swift: extend the target vocabulary. `remoteTargetKinds` (the static used
by the picker) becomes `["cmux", "app", "frontmost"]` in that order, with display
names: cmux → "cmux (no permission needed)", app → "Terminal / specific app",
frontmost → "Frontmost app". Add:
```swift
static let knownTerminalApps: [(name: String, bundleID: String)] = [
    ("cmux", "com.cmuxterm.app"),
    ("Terminal", "com.apple.Terminal"),
    ("iTerm2", "com.googlecode.iterm2"),
    ("Ghostty", "com.mitchellh.ghostty"),
    ("WezTerm", "com.github.wez.wezterm"),
    ("Warp", "dev.warp.Warp-Stable"),
    ("Alacritty", "org.alacritty"),
]
```
Note: even though cmux appears in knownTerminalApps, targeting cmux is best done
via the "cmux" kind (socket, no permission), NOT the "app" injection kind — the
Settings UI must steer users there (below).

RemoteControlService.swift: injection robustness — in `activateIfNeeded`, after
`app.activate()`, poll `NSRunningApplication.frontmostApplication` up to ~400ms
until the target is frontmost before returning (so the first keystrokes don't go
to the wrong window); if the app isn't running, return a friendly error
("<name> isn't running — open it first."). Keep the AX gate. No other route change.

## C. Clear Accessibility guidance so the failure is never silent

The AX-blocked failure currently only shows as a transcript error after a send.
Make it visible up front:
- **Main-window top info bar** (MainView): when `config.controlMode == "remote"`
  AND the resolved route is injection (`remoteTargetKind` is "app" or "frontmost")
  AND `!remote.axTrusted`, show a compact amber warning chip/banner:
  "Remote typing needs Accessibility — use cmux or grant access in Settings → Remote".
  Not shown for the cmux target.
- **SettingsView Remote tab**: 
  - Target picker uses the new display names; when "app" is selected show the
    known-terminal presets as quick-pick buttons (set remoteAppBundleID) in
    addition to the running-apps picker.
  - When an injection kind is selected and `!remote.axTrusted`, render the
    existing Accessibility section in its "needed" (amber/red) state with a
    one-line "Or switch to cmux — it needs no permission" + a "Switch to cmux"
    button (sets remoteTargetKind = "cmux").
  - Add a top-of-tab one-liner: "cmux is the easiest target — it needs no
    macOS permission. Terminal/other apps use keystroke injection and require
    Accessibility."
- README: document the target kinds, that cmux needs no permission, terminal
  apps need Accessibility (+ the stable-signing note already added), and that
  voice/prompts are delivered by `cmux send` (socket) or keystroke injection
  depending on target.

---

# v1.6 addendum — transcript persistence

Supersedes anything above where it conflicts. One feature: the transcript
survives relaunch, per project, so a session resumed with `--resume` shows the
conversation it is resuming.

## New file: TranscriptStore.swift

```swift
@MainActor final class TranscriptStore {
    static var supportDirectoryOverride: URL?      // test seam, mirrors HookInstaller's
    static let maxStoredEntries = 2000             // compaction threshold on load
    static let defaultRestoreCount = 200

    static var transcriptsDirectory: URL           // <Application Support>/PowerUp/transcripts/
    static func fileURL(forProjectDir path: String) -> URL
        // "<slug of basename ≤40 chars>-<first 12 hex of SHA-256(standardized path)>.jsonl";
        // slug empty → hash alone. Same path → same file; same basename in
        // different parents → different files.

    private(set) var projectDir: String?
    func setProject(_ path: String?)               // nil/empty disables persistence
    func append(_ entry: TranscriptEntry)          // one JSON line; ALL failures swallowed
    func loadTail(maxEntries: Int = defaultRestoreCount) -> [TranscriptEntry]
        // newest maxEntries, oldest first; undecodable lines skipped; a file
        // holding > maxStoredEntries decodable entries is rewritten (atomic)
        // down to its newest maxStoredEntries during the load.
}
```

On-disk format: JSON Lines, one object per entry
(`{"id":"<UUID>","kind":"user","text":"…","date":<epoch seconds>}`), encoded
with `.secondsSince1970` dates. Parse defensively: unknown fields and
undecodable lines are ignored, never fatal.

## Models.swift

`TranscriptEntry` gains `Codable`; `Kind` gains `String` raw values
(`user`, `assistant`, `tool`, `system`, `error`). Nothing else changes.

## AppState behavior

- Owns a `private let transcriptStore = TranscriptStore()`. `init` sets the
  store's project from config and restores; `chooseProjectDirectory` re-points
  the store, and on an actual project change clears `transcript` and restores
  the new project's history — all before the "Project folder: …" entry is
  appended (so that entry lands in the new project's file).
- `appendEntry` persists every entry it accepts via `transcriptStore.append`.
- Restore replaces `transcript` with the loaded tail (capped to
  `maxTranscriptEntries - 1`) plus a trailing `.system` marker
  "Earlier conversation restored — New Session starts clean." The marker is
  set directly, NOT via `appendEntry` — it must never be persisted, or every
  launch would stack another one into the file.
- Restore happens only when the store returns at least one entry; an empty or
  missing history changes nothing.

Tests must use `supportDirectoryOverride` (see `TranscriptStoreTests`) — a
live installation's history is never touched.

---

# v1.7 addendum — intent/harness contracts + the PowerUp protocol server

Supersedes anything above where it conflicts. This is the M2 "protocol
extraction" milestone (DEVELOPMENT.md): devices and the session driver are
decoupled through three new contracts, and the listener grows a WebSocket
protocol endpoint. Behavior of the app is unchanged.

## New file: Intent.swift

```swift
enum VoiceCaptureMode: String, Equatable { case send, draft }

enum Intent: Equatable {
    case beginVoiceCapture(VoiceCaptureMode), endVoiceCapture
    case sendPrompt(String), sendDraft
    case approve, reject, interrupt
    case stopSpeaking, replayLastReply, toggleTTS
    case newSession, showWindow
    case cycleModel, cycleEffort, cyclePermissionMode, toggleControlMode
}

enum ControlPhase: Equatable { case began, ended }

enum IntentMapper {
    static func intent(for action: ControllerAction, phase: ControlPhase) -> Intent?
        // hold actions → begin/end pair; others fire on .began, nil on .ended
    static func intent(forProtocolName name: String, text: String?) -> Intent?
        // the wire-safe subset — NO voice capture, NO direct setters; unknown → nil
}
```

`AppState` dispatch: `handleButtonDown/Up` do the hold bookkeeping
(`pttHoldButton`) then translate via `IntentMapper` into `handle(_ intent:)` —
the single dispatcher every input source funnels into (buttons and protocol
clients alike). Button release for a recorded hold always emits
`.endVoiceCapture` regardless of the current mapping (a mid-hold mapping edit
must not strand the recorder). The old `perform(_ action:)` is gone; the old
private `PTTMode` is replaced by `VoiceCaptureMode`.

## New file: Harness.swift

```swift
typealias HarnessState = ClaudeState

struct HarnessConfiguration: Equatable {
    var projectDir: URL
    var model: String; var permissionMode: String; var effort: String
    var resumeSessionID: String?; var binaryPathOverride: String?
}

enum HarnessEvent: Equatable {
    case sessionReady(sessionID: String, model: String)
    case replyDelta(String), reply(String)
    case toolUse(name: String, detail: String)
    case turnCompleted(resultText: String?, costUSD: Double?, isError: Bool, detail: String)
    case controlResult(action: String, ok: Bool, detail: String, value: String?)
    case permissionRequest(id: String, name: String, detail: String)  // reserved
    case notification(String)                                         // reserved
    case runtimeError(String), ended(exitCode: Int32)

    static func from(_ event: ClaudeEvent) -> HarnessEvent   // total, 1:1, tested
}

@MainActor protocol HarnessAdapter: AnyObject {
    var state: HarnessState { get }
    var sessionID: String? { get }
    var modelName: String? { get }
    var totalCostUSD: Double { get }
    var onHarnessEvent: ((HarnessEvent) -> Void)? { get set }
    func start(_ configuration: HarnessConfiguration)
    func send(_ text: String); func interrupt()
    func setModel(_ model: String); func setPermissionMode(_ mode: String)
    func stop()
}
```

`ClaudeService` conforms: it gains the stored `onHarnessEvent` (fed from
`emit`, alongside the wire-level `onEvent`) and `start(_ configuration:)`
delegating to the existing `start(projectDir:…)`. **AppState's session logic
uses only `harness` (an `any HarnessAdapter` computed over `claude`) and
`HarnessEvent`** — the concrete `claude` remains exposed solely for the views
until the UI generalizes. `permissionRequest`/`notification` have no emitter
yet; AppState surfaces them as transcript entries + announcements when they
arrive.

## New files: WebSocketFraming.swift, PowerUpProtocol.swift

Pure, fully unit-tested:

- `WebSocketFraming` — server-side RFC 6455: `acceptKey(forClientKey:)`,
  `decodeFrames(from:maxPayload:)` (client frames must be masked, RSV must be
  0, data frames must be final — v0 forbids fragmentation; control frames
  ≤ 125 bytes; violations throw), `encodeFrame/encodeText/encodeClose`
  (server frames unmasked, final).
- `PowerUpProtocol` — the wire vocabulary of **docs/protocol.md** (spec and
  file must change together): `upgradeDecision(method:path:header:)`
  (`/ws` only; GET; upgrade headers; **any non-empty Origin → 403**;
  version 13; key required), `parseClientMessage` (hello/intent/ping →
  `ClientMessage`, everything else → typed `ClientMessageFailure` with wire
  `code`/`message`), and the server-message builders
  (welcome/status/transcript/session/pong/error + `encode`).

## RemoteListener additions (same class, same port)

```swift
var onIntent: ((Intent) -> Void)?                 // main actor
var welcomeSnapshot: (() -> [[String: Any]])?     // main actor
func broadcast(_ message: [String: Any])          // to all authed WS clients
```

`GET /ws` upgrades a connection into WebSocket mode (`HookConnection` gains
the mode switch, a 2 MB buffer cap, 1 MB frame cap); in-band `hello` with the
listener token authenticates (15 s deadline — the existing idle timer now
spares authenticated sockets); on auth the client gets `welcome` + the
snapshot, then live broadcasts. `ConnectionRegistry` tracks authenticated
handlers separately: hook bursts can never evict a protocol client, and
authenticated clients cap at 16 (`server_busy` beyond that).
`POST /event` behavior is byte-for-byte unchanged.

## AppState wiring

- `wireListener` sets `onIntent` (voice-capture intents are dropped
  defensively — they can't arrive) and `welcomeSnapshot` (current status +
  session message).
- Broadcasts: every `appendEntry` → `transcript` message; every actual status
  change → `status` message; `scheduleDerivedUpdate` ends with
  `broadcastSessionIfChanged()` (keyed on model/liveModel/effort/permission/
  controlMode/sessionID/cost).

## Safety invariants (normative)

1. No input source can set `bypassPermissions`: the only permission intent is
   the cycle, and `AppConfig.permissionModeCycle` excludes it.
2. Unknown wire input is answered or ignored, never partially executed.
3. Growing the protocol intent vocabulary requires editing
   `IntentMapper.intent(forProtocolName:)`, whose tests assert the allowed
   set — a reviewed decision, never an accident.

---

# v1.8 addendum — remote-mode draft dictation types into the target

Supersedes anything above where it conflicts. One behavior fix, reported live:
in remote mode, dictate-to-draft (L2) dropped the transcript into PowerUp's
own prompt box — a window the user typically isn't looking at while driving a
cmux/terminal session — so the dictation appeared to vanish, and sending it
with L1 would immediately auto-submit, defeating review.

## Behavior (AppState)

- A `.draft` voice hold captures whether it belongs to remote mode **at hold
  start** (`pttDraftTargetsRemote`); a control-mode toggle mid-hold cannot mix
  the paths.
- **Remote draft hold** (`controlMode == "remote"` at hold start): no live
  mirroring into `draftText` and the prompt box is never touched. On release,
  the final transcript (or the last partial, as in the local path) is
  delivered via `sendText(_, submit: false)` — TYPED into the remote target
  (cmux input box / terminal prompt) **without Enter**, regardless of
  `remoteAutoSubmit`. The user reviews it where the session lives and sends
  with Enter there or the Approve button (✕ = Enter in remote mode). A
  `.system` transcript entry records `Dictated into the remote session (not
  sent): …`; success = tick haptic, nothing usable heard = error buzz and
  nothing typed. The permission-denied teardown must not restore `draftText`
  for a remote hold (it never captured).
- **Local draft hold**: unchanged (v1.2 behavior).
- `AppState` gains `var draftDictationTargetsRemote: Bool` (computed from
  published state) for the UI.

## UI

`PTTIndicator` and `PTTTranscriptBanner` gain `isRemoteDraft: Bool = false`
and say "…typed into the remote session…" instead of "…the prompt box…" when
it's true; `MainView` passes `appState.draftDictationTargetsRemote`.

---

# v1.9 addendum — recognition-language safety + super-compact voice exclusion

Supersedes anything above where it conflicts. Root cause of a live "voice to
text is really really off" report: the STT locale was silently set to a
language the user wasn't speaking (`localeID: "zh-CN"`, plus
`onDeviceRecognition: true`), and nothing in the UI made that visible. A
mismatched recognizer doesn't degrade — it produces garbage. Separately, the
config had `ttsVoiceID` pointing at a `com.apple.voice.super-compact.*` voice:
the picker's legacy-prefix filter missed that modern identifier tier.

## SettingsView (Voice tab)

- The free-typed locale TextField is REPLACED by a Picker over
  `SFSpeechRecognizer.supportedLocales()` labeled **"Language you speak"** —
  rows are localized display names ("English (United States) — en-US"),
  sorted; identifiers normalize `_` to `-`. A saved value not in the supported
  set is kept as an extra row labeled "— not supported on this Mac" so the
  picker never lies about current state.
- Caption under the picker states plainly that a mismatch produces gibberish.
- The on-device toggle gains a caption: less accurate, leave off for best
  results.

## MainView / ComponentViews

`PTTTranscriptBanner` gains `recognitionLanguage: String?`; `MainView` passes
a display name whenever `config.localeID` doesn't start with "en", and the
listening hint appends "Recognizing <language> — change it in Settings →
Voice if that's wrong." The #1 misconfiguration is now visible at the exact
moment it bites.

## TTSService

- New pure helper `static func isExcludedVoiceIdentifier(_:) -> Bool`
  (tested): excludes "eloquence", the legacy
  "com.apple.speech.synthesis.voice" prefix, and identifiers containing
  "super-compact". Plain "compact" voices remain — they're the standard
  default tier and often a language's only voice.
- `passesQualityExclusions` delegates to it (novelty-trait check unchanged).
- Voice-resolution rule 2 (explicit `voiceID`) additionally requires
  `passesQualityExclusions` — a stale config pointing at a now-excluded voice
  yields to quality routing instead of being honored.

---

# v1.10 addendum — per-session remote turn tracking (the stuck-amber fix)

Supersedes anything above where it conflicts. Live report: a Claude session
closed mid-turn and the light bar stayed amber ("working") forever. Two root
causes: a session that dies mid-turn never emits `Stop` (and PowerUp didn't
subscribe to `SessionEnd`), and `remoteTurnActive` was one global Bool fed by
every session on the machine, so concurrent sessions interleaved into
nonsense.

## HookInstaller

- `hookEvents` gains **`SessionEnd`** (now Stop, UserPromptSubmit,
  Notification, SessionEnd).
- `installState` additionally verifies **every** event in `hookEvents` is
  registered with the current quoted command — an install from an older build
  (missing SessionEnd) reports `.outOfDate`, and the existing Settings UI
  already prompts the reinstall. `install()` idempotently adds only what's
  missing.

## RemoteListener

`RemoteHookEvent.Kind` gains `.sessionEnd`; `SessionEnd` payloads parse with
`reason` as the text field, plus the usual `session_id`/`cwd`.

## AppState

- `remoteTurnActive` is now DERIVED, never written directly:
  `remoteActiveTurns: [String: Date]` maps session id (or
  `"unknown-session"`) → last sign of life. `userPromptSubmit` inserts and
  schedules an expiry check; `stop` and `sessionEnd` remove their session's
  entry; a `notification` refreshes an existing entry's timestamp (a turn
  waiting on the user is alive) but never creates one.
  `remoteTurnActive = !remoteActiveTurns.isEmpty` after pruning.
- **Expiry**: an entry with no hook activity for 15 minutes
  (`remoteTurnExpiry`) is presumed dead — missed Stop (killed terminal,
  crashed CLI, Escape pressed directly in the session). A legitimate longer
  turn may go idle early and self-corrects on its next hook event; the
  reverse tradeoff (amber forever) has no recovery.
- `sessionEnd` for a session we believed was working appends a `.system`
  entry "Claude session ended before replying." (label-prefixed by cwd);
  sessions we weren't tracking end silently.
- `clearRemoteTurns()` empties the table and the flag — used by Interrupt,
  Reject, remote New Session, and every control-mode switch (the user's
  escape hatches, unchanged in behavior).

---

# v1.11 addendum — L1 submits the remote input box

Supersedes anything above where it conflicts. Live report, and a hole v1.8
opened: after L2 dictation started landing in the REMOTE input box, L1
("Send Prompt Box") still only sent PowerUp's local `draftText` — which that
flow leaves empty — so L1 error-buzzed, the dictated text sat unsubmitted,
and the idle session's Notification hook had PowerUp announcing "Claude
needs your attention."

`sendDraft()` behavior now:

- Local box NON-empty: unchanged (send via `sendUserText`, clear the box) —
  both modes.
- Local box EMPTY, built-in mode: unchanged (error haptic).
- Local box EMPTY, remote mode: press **Enter in the remote target**
  (`sendKey(.enter)`), submitting whatever is typed there — the v1.8 framing
  completed: in remote mode the "prompt box" IS the target's input line, so
  "Send Prompt Box" submits it. Transcript notes "Sent the remote input
  (Enter)."; tick haptic. The L2 → L1 dictate-review-send flow is thereby
  identical in both modes.

The remote-draft transcript note now names the send options ("send it with
L1, ✕, or Enter there"), and docs/controls.md + docs/remote-control.md say
the same.

---

# v1.12 addendum — spoken summaries (lightweight-model conclusions)

Supersedes anything above where it conflicts. User-requested: long replies
take minutes to read aloud; with the toggle on, a lightweight model writes a
1–2 sentence conclusion and THAT is spoken instead. Off by default.

## Models.swift — AppConfig

```swift
var speakSummaries: Bool      // default false — summaries cost tokens, opt-in
var summaryModel: String      // default "haiku"; blank on disk decodes to default
```
Both tolerant-decoded like every post-v1.0 field. No UI for `summaryModel`
(config.json-editable).

## New file: SummaryService.swift

```swift
@MainActor final class SummaryService: ObservableObject {
    static let timeout: TimeInterval = 30
    nonisolated static func arguments(model: String) -> [String]
        // ["-p", "--model", M, "--output-format", "text", "--permission-mode", "default"]
        // one-shot, tool-less, prompt via stdin, cwd = temp dir — never touches a project
    nonisolated static func prompt(for reply: String) -> String
        // spoken prose only, no markdown, same language as the reply
    func summarize(_ reply: String, model: String, claudePathOverride: String?,
                   completion: @escaping (String?) -> Void)
        // completion once, main actor; nil = fall back to the full reply.
        // A newer summarize() silently supersedes (old completion never fires).
        // Output is rejected (nil) when empty or not meaningfully shorter than
        // the reply (>= max(200, reply.count/2)).
    func cancel()
}
```
Binary resolution reuses `ClaudeService.resolveClaudeBinary`. Bounded wait
(30 s) with concurrent stdout drain; nonzero exit / spawn failure / timeout →
nil. Tests cover the pure parts only — never spawn real `claude` in tests.

## AppState behavior

- Both reply paths (built-in `turnCompleted`, remote `stop` hook) converge on
  `speakReply(_:)`: TTS off or empty → nothing; summaries off OR reply
  shorter than `summaryMinimumReplyLength` (350) → speak the full reply
  exactly as before; otherwise request a summary and speak it on arrival —
  any nil falls back to the full reply, so the toggle can never silence
  read-back.
- The summary is also appended as a `.system` "Summary: …" transcript entry
  (persisted + broadcast). `lastAssistantReply` remains the FULL reply —
  Replay Last Reply always reads the full text.
- Staleness: `speechTurnGeneration` guards the async completion; it's bumped
  (and the in-flight request cancelled) by `sendUserText`, `newSession`,
  PTT start, and the `.stopSpeaking` intent, and the completion additionally
  refuses to speak while `isPTTActive`.
- The summary is spoken through `TTSService.spokenReply` (markdown-stripped,
  no truncation) with its language routing, so non-English summaries get the
  matching voice.

## SettingsView (Voice tab)

Toggle "Summarize long replies (uses a fast model)" in the Text to Speech
section, with a caption covering cost, the transcript keeping the full text,
Replay behavior, and the fallback.

---

# v2.0 addendum — the ACP adapter (M3 harness expansion)

Supersedes anything above where it conflicts. Adds the second
`HarnessAdapter`: any Agent Client Protocol agent — opencode natively, Claude
Code via the `@agentclientprotocol/claude-agent-acp` bridge (NOTE: renamed
from `@zed-industries/claude-code-acp`), Codex/Gemini via their bridges when
installed. Decisions: ADR 0004 (ACP-first), ADR 0005 (built-in Claude stays
on stream-json).

## Verified facts (live probes, this machine, 2026-08-27)

- ACP = JSON-RPC 2.0, newline-delimited JSON over stdio. `initialize`
  (`protocolVersion: 1`, client declares `fs` capabilities) → agent
  capabilities + `agentInfo` + `authMethods`. `session/new {cwd, mcpServers}`
  → `{sessionId, models: {currentModelId, availableModels}}` (opencode) —
  the bridge also returns config options including a permission-mode select.
- `session/prompt {sessionId, prompt: [{type: "text", text}]}` streams
  `session/update` notifications: `agent_thought_chunk` /
  `agent_message_chunk` (`content.text`), `tool_call` (toolCallId, title,
  kind, locations, rawInput, `_meta.claudeCode.toolName` on the bridge),
  `tool_call_update`, `usage_update`, `available_commands_update`; the
  request resolves with `{stopReason: "end_turn" | …}` (the bridge adds token
  `usage`, no dollars).
- `session/request_permission` is an agent→CLIENT REQUEST carrying
  `toolCall` + `options: [{optionId, name, kind: allow_once | allow_always |
  reject_once | reject_always}]`; the client responds
  `{outcome: {outcome: "selected", optionId}}` or `{outcome: {outcome:
  "cancelled"}}`.
- The Claude bridge refuses to start when `CLAUDECODE` / `CLAUDE_CODE_*` env
  vars are present (nested-session guard) — spawn environments must strip
  them.

## Models.swift — AppConfig

```swift
var harnessKind: String       // "claude" (default) | "acp" — option-validated
var acpAgent: String          // "opencode" (default) | "claudeBridge" | "custom"
var acpCustomCommand: String  // space-split command line for "custom"
// + harnessKindOptions, acpAgentOptions, acpAgentDisplayName(_:)
```

## Harness.swift — contract additions

- `HarnessConfiguration` gains `agentCommand: [String]? = nil` (the spawn
  command for ACP adapters; nil for the Claude adapter).
- `HarnessAdapter` gains capability flags `supportsEffort` / `reportsCostUSD`
  (protocol-extension defaults false; ClaudeService overrides both true) and
  `respondToPermission(id:allow:)` (default no-op).

## New file: ACPAdapter.swift

`@MainActor final class ACPAdapter: ObservableObject, HarnessAdapter`.
- Pure, tested statics: `agentCommand(for:)` (opencode candidates →
  `[bin, "acp"]`; claudeBridge → `[npx, "-y",
  "@agentclientprotocol/claude-agent-acp"]`; custom → space-split; nil when
  unresolvable), `agentEnvironment(from:)` (strips `CLAUDECODE`,
  `CLAUDE_PID`, `CLAUDE_CODE_*`; appends install dirs to PATH),
  `permissionChoice(options:allow:)` (matches direction, PREFERS the
  `*_once` variant — a controller press never silently grants "always";
  nil → cancelled outcome).
- start: spawn → `initialize` → `session/new` (cwd = projectDir) →
  `.sessionReady(sessionId, currentModelId)`, state `.ready`; 30 s startup
  deadline → runtimeError + stop. No resume (ACP sessions start fresh;
  `lastSessionID` is never overwritten by ACP ids).
- send: prompts queue while `.starting`/`.working`, FIFO-flushed after each
  completion. Updates: message chunks → `replyDelta` + accumulate; thought
  chunks dropped; `tool_call` → `toolUse` (bridge toolName or title;
  detail = location basename or best rawInput string). Prompt resolution →
  `reply(accumulated)` + `turnCompleted(resultText:, costUSD: nil, isError:
  error || stopReason == "refusal", detail: stopReason)`.
- interrupt: `session/cancel` notification (+ optimistic ok controlResult);
  setModel/setPermissionMode: `session/set_model` / `session/set_mode`,
  success/error → `controlResult` (AppState's existing revert logic applies —
  aliases that the agent doesn't know are rejected and rolled back).
- `session/request_permission` → store pending rpc id, emit
  `permissionRequest(id: String(rpcID), name: toolCall.title, detail:)`;
  `respondToPermission` answers it; unanswered requests are cancelled on
  stop/interrupt so the agent never hangs. Unknown agent requests (fs/*,
  terminal/*) get a method-not-found error — we declared no such
  capabilities. All parsing defensive; unknown update kinds ignored.

## AppState

- `harness` now switches on `config.harnessKind` between `claude` and a
  lazily created, event-wired `ACPAdapter`. `harnessReportedModel` exposes
  the active adapter's model for the chip (ModelChip reads it instead of
  `claude.modelName`).
- `syncHarnessSelection()` (in the derived-update pass, keyed on
  kind|agent|customCommand) stops the outgoing session once per change; the
  new harness starts lazily on next send. `startSession` resolves
  `agentCommand` for ACP (friendly error when the binary is missing) and
  passes `resumeSessionID: nil` for ACP.
- Permission flow (issue #10): `.permissionRequest` stores
  `pendingPermissionID`, transcript entry "The agent wants to: … Press ✕ to
  allow or ○ to deny.", haptic + announce "Approval needed". While one is
  pending (built-in mode), Approve/Reject answer IT via
  `respondToPermission` instead of sending Yes/No. Cleared on turn
  completion, session end, and harness switches.
- `cycleEffort` refuses (transcript note + error haptic) when
  `!harness.supportsEffort`.

## SettingsView (General tab)

New "Harness" section above Model: segmented Claude Code (built-in) / ACP
agent; for ACP an agent picker (opencode / Claude Code (ACP bridge) /
Custom command + TextField) and a caption covering model-id requirements,
no effort, no cost reporting, and switch-on-next-message semantics.

Tests: pure statics + an integration suite driving the real adapter against
a scripted python mock agent over stdio (handshake, streamed updates,
thought-chunk filtering, the permission round-trip choosing `allow_once`,
set_model accept/reject). The mock is not a real harness — the live wire
shapes above were captured by probes, and changes there must update this
addendum and the adapter together.

---

# v2.2 addendum — M3 batch two: heartbeat, focus, destructive confirm, tokens, Codex

Supersedes anything above where it conflicts. Five changes.

## A. PostToolUse heartbeat (#61)

`HookInstaller.hookEvents` gains `PostToolUse` (fires per tool call; older
installs report `.outOfDate` → Settings prompts reinstall).
`RemoteHookEvent.Kind` gains `.postToolUse` (`tool_name` as text). AppState:
a PostToolUse refreshes — or CREATES — the session's `remoteActiveTurns`
entry, so a long tool-using turn never expires mid-flight and a turn already
running when PowerUp launches shows amber. The 15-minute expiry now only
bites turns with no tool activity at all.

## B. Remote session focus (#5)

- `knownRemoteSessions: [id: (cwd, lastSeen)]` — every hook is a sighting
  (SessionEnd removes; entries older than 30 min are pruned at cycle time).
  In-memory only, never persisted.
- `@Published remoteFocusSessionID: String?` — nil = everything (default).
  With a focus set: only the focused session's Stop speaks/haptics/sets
  `lastAssistantReply`, only its Notification announces, and only its turn
  drives `remoteTurnActive`; everything still logs (cwd-prefixed).
- New `ControllerAction`/`Intent`/wire-name `cycleFocus` ("Cycle Session
  Focus"; not in the default mapping): All → each session (ordered by cwd
  basename) → All, announcing "Focus: <folder>" / "Focus: everything".
  Built-in mode → explanatory note + error haptic. Focus clears on
  control-mode switch and when the focused session ends.
- `FocusChip` (amber, `scope`) appears in the top bar while focused.

## C. Destructive-action confirmation (#47)

New file `DestructiveActionClassifier.swift` (pure, tested):
`isDestructive(kind:title:detail:)` — true for tool kind "delete" or any
pinned pattern (`rm -rf`, `git reset --hard`, force-push, `drop table`,
`terraform destroy`, …). Deliberately substring-conservative: a false
positive costs one extra press.

`HarnessEvent.permissionRequest` gains `kind: String` (ACPAdapter passes the
toolCall kind). `AppState.pendingPermission` becomes a published struct
`PendingPermission {id, name, detail, isDestructive, armed}`. Approve on a
destructive request first ARMS it (transcript ⚠️ + "Destructive. Press again
to confirm" + error haptic); the second ✕ approves; ○ denies at any point.
`PermissionRequestBanner` (MainView) shows every pending request under the
top bar — amber normally, red for destructive, with the ✕/○ legend.

## D. Cost/usage normalization step (#12)

`HarnessAdapter` gains `totalTokens: Int` (extension default 0). ACPAdapter
accumulates per-turn `usage.inputTokens + outputTokens` from prompt results
(the Claude bridge reports them; opencode doesn't) and resets on start.
`CostChip`: dollars when `reportsCostUSD`, else "N.Nk tok" when tokens are
known, else hidden — never a false $0.00. The protocol `session` message
gains optional `tokens` (present when > 0); broadcast change-key includes it.

## E. Codex bridge preset (#9, partial)

`acpAgentOptions` gains `codexBridge` ("Codex (ACP bridge)") →
`npx -y @agentclientprotocol/codex-acp`. Handshake verified live 2026-08-27
(bridge 1.7.0 responds to initialize; session/new requires the user's Codex
login, surfaced by the existing friendly error). ModeChip shows the harness
in built-in mode ("Built-in · opencode").

---

# v2.1 addendum — Ultra effort (dynamic workflows) + multiple conversations

Supersedes anything above where it conflicts. Two built-in-mode features.

## A. Ultra effort ("max")

Verified live: the installed claude CLI accepts `--effort max`. There is no
CLI flag for workflow orchestration — the documented opt-in is the
`ultracode` prompt keyword.

- `AppConfig.effortOptions` gains `"max"`; `effortCycle` becomes
  `low → medium → high → xhigh → max`. New
  `AppConfig.effortDisplayName(_:)` renders `"max"` as **Ultra** everywhere
  (Settings picker "Ultra (dynamic workflows)", cycle transcript entries and
  announcements, the effort chip shows "ultra").
- **Wire behavior**: when `effort == "max"` AND the harness kind is
  `"claude"`, `AppState.outgoingText(for:)` prefixes every outgoing built-in
  prompt with `"ultracode\n\n"` — the harness's documented multi-agent
  opt-in. The transcript keeps the user's own words. ACP harnesses and
  remote mode are NEVER prefixed (the keyword is Claude-Code-specific, and
  remote text belongs to someone else's session verbatim).
- Effort restart semantics are unchanged (`--effort max` + `--resume`).

## B. Multiple conversations (several folders)

Every project folder is its own conversation: its own resumable session id
and its own transcript history (v1.6).

- `AppConfig` gains `recentProjectDirs: [String]` (most-recent-first, capped
  at 8) and `sessionIDsByProject: [String: String]`; both tolerant-decoded.
  `AppState.seedProjectBookkeeping()` migrates old configs on launch (current
  folder joins recents; `lastSessionID` seeds its map entry).
- `ControllerAction`/`Intent` gain `cycleProject` ("Cycle Project"; NOT in
  the default mapping), wired through IntentMapper, the protocol vocabulary
  (`"cycleProject"`, additive in v0), MappingView's Session group, and a
  `folder.badge.gearshape` glyph.
- `adoptProject(_:movingToFrontOfRecents:)` is the single switch path
  (folder panel → front-of-recents; cycle/Settings switch → in place, so
  cycling can't ping-pong): sets `projectDir`, points `lastSessionID` at THE
  TARGET folder's saved id (no cross-folder resume), swaps transcript
  history, and (built-in mode) restarts the session resuming that folder's
  conversation. `sessionReady` records ids into `sessionIDsByProject`
  (claude kind only); `newSession` clears the current folder's entry.
- `cycleProject` steps through recents IN LIST ORDER, skipping folders that
  no longer exist; <2 usable folders → transcript note + error haptic.
  `switchProject(to:)` (also used by the Settings recents list) stops
  TTS/summaries/pending permissions before adopting and announces
  "Project: <folder>".
- SettingsView Project section lists the recents with Switch buttons and a
  "current" marker.

---

# v2.3 addendum — low-battery warning + haptics capability note

Supersedes anything above where it conflicts.

## A. Low-battery warning (#56)

- `ControllerService` gains `var onLowBattery: ((Float) -> Void)?` and an
  internal pure `BatteryWarningLatch` (threshold `0.2`). The battery poll
  fires the callback at most once per connection, only while the pack is
  `.discharging` (charging/full/unknown never warn), and treats a `0.0`
  level as "not populated yet" — GameController reports zeros briefly
  around connect. The latch resets on every (re)connect, including a
  fallback swap to another pad, and on full disconnect.
- `AppState` surfaces it as a `.system` transcript entry ("🔋 Controller
  battery is low (N%) — plug it in soon.") plus the error haptic. No new
  config; the existing `hapticsEnabled` gate applies to the buzz as usual.
- Pinned by `BatteryWarningLatchTests` (once per connection, discharging
  only — charging/full/unknown never warn, reset-on-reconnect, zero/nil
  ignored, threshold boundary, and non-firing readings never consume the
  latch). The latch takes the raw `GCDeviceBattery.State`, so the state
  mapping itself is test-pinned.
- The transcript percent is truncated, not rounded, so a sub-threshold
  reading can never display as the contradictory "20%".

## B. Haptics capability note (#18)

Clarifies the base spec's "light/haptics/touchpad become no-ops" line for
non-DualSense pads: haptics and the light bar are capability-gated, not
DualSense-gated — `rumble(...)` is gated on `controller.haptics` (not
`isDualSense`; haptics stay best-effort, engine failures swallowed), and
`setLight(...)` is likewise a no-op only when `controller.light == nil`.
Any pad exposing `GCDeviceHaptics` (e.g. Xbox pads on macOS 11+) rumbles.
Only the touchpad button remains genuinely DualSense-only.

---

# v2.4 addendum — device profiles: the (profile, control) → action keystone

Supersedes anything above where it conflicts. Implements the
storage/resolution keystone of ADR 0006 (#63, #62, and #14's first half —
string-typed event emission from input services lands with the second input
source, #67/#70, per the ADR's amendments); zero visible behavior change.

## A. Model types (Models.swift)

- `struct ControlDescriptor: Codable, Equatable, Hashable, Identifiable`
  — `{ id: String, kind: Kind (button|hold|axis|key), displayName: String,
  symbolName: String }`. String ids are the stable identity; never Swift
  enum cases in serialized form.
- `struct DeviceProfile: Codable, Equatable, Identifiable`
  — `{ id: String, displayName: String, controls: [ControlDescriptor] }`,
  plus `static let dualSenseID = "dualsense"` and `static let dualSense`,
  the built-in profile whose descriptors mirror `ControllerButton`'s
  display metadata (ids are the enum raw values), so the serialized profile
  and the enum can never disagree.
- `typealias DeviceMapping = [String: ControllerAction]` (controlId →
  action).

## B. AppConfig storage

- The stored mapping truth is now
  `var deviceMappings: [String: DeviceMapping]` (profileId → controlId →
  action); the on-disk key is `deviceMappings`, keyed objects all the way
  down. `mapping` remains as a **computed** compatibility view of the
  DualSense profile (get/set bridges to `deviceMappings`), so every
  existing call site (`MappingView`, legend, hints,
  `resetMappingToDefault`) keeps working against one source of truth.
- `static func defaultDeviceMappings()` wraps the pinned
  `defaultMapping()` under the dualsense profile id.
- Resolution goes through
  `func action(onProfile: String, control: String) -> ControllerAction`
  (`.none` when unmapped) — the single point every input surface routes
  through; `AppState.handleButtonDown` now resolves via it with
  `(DeviceProfile.dualSenseID, button.rawValue)`.

## C. Migration (tolerant decoder + ConfigStore)

- Decoding: a `deviceMappings` key wins outright when present, and is read
  **per-entry tolerantly** — an unrecognized action (a newer build's case,
  a hand-edit) drops that one binding, a malformed profile value drops that
  one profile, never the whole tree. Otherwise a legacy `mapping` key
  (`[ControllerButton: ControllerAction]`, read via a separate
  `LegacyCodingKeys`) migrates losslessly into the dualsense profile;
  neither key → defaults. Encoding writes only the new shape.
- `ConfigStore.backupConfigBeforeLossyLoadIfNeeded(at:data:)` (internal,
  URL-injected for tests) copies `config.json` once to
  `config.pre-profiles.json` before the first save can rewrite it lossily —
  triggered by the legacy shape (migration) or by a `deviceMappings` whose
  strict decode fails (entries would be dropped) — so a botched migration
  or app downgrade can always recover the user's bindings.
- The `mapping` bridge setter merges over the stored dualsense entry:
  button-keyed writes keep full button semantics (an absent button is
  unmapped), while non-button control ids under the profile survive bridge
  edits untouched.
- Pinned by `DeviceProfileTests` (profile↔enum agreement, lossless
  migration incl. parameterized `sendPrompt`, new-key-wins, encode shape,
  foreign-profile round-trip, per-entry tolerance, bridge write-through and
  foreign-id preservation, backup triggers incl. once-only) and the updated
  `AppConfigTests.testMappingEncodesAsKeyedObject`.

## D. Hold semantics (unchanged, recorded)

One hold at a time, owned by the control that started it: a second hold
press while one is active is ignored, and only the recorded control's
release ends the capture (`pttHoldButton` logic is unchanged). Cross-device
arbitration (several devices asserting holds) is deliberately deferred to
the virtual-device work (#67), which introduces the second input source.

---

# v2.5 addendum — audio device selection and routed speech output

Supersedes anything above where it conflicts. Implements #64, #65, #66
(Track A Phase 3, minus the mic level check which ships with the first-run
wizard, #30). Mechanisms verified by the 2026-08-30 spikes recorded on #65.

## A. AudioDeviceStore.swift (new module in the documented layout)

- `struct AudioDevice { id: AudioDeviceID, uid: String, name: String,
  inputChannels: Int, outputChannels: Int }` — `uid` is the persisted,
  stable identity; `id` is transient.
- `@MainActor final class AudioDeviceStore: ObservableObject` —
  `@Published inputDevices/outputDevices: [AudioDevice]`,
  `var onDevicesChanged: (() -> Void)?`, `func start()` (enumerate + a
  `kAudioHardwarePropertyDevices` listener block that hops to the main
  actor), `inputDeviceID(forUID:)` / `outputDeviceID(forUID:)` /
  `inputDevice(forUID:)` / `outputDevice(forUID:)`, and
  `nonisolated static func systemDefaultInputDeviceID()`.
- `struct AudioAvailabilityTracker` — pure came/went transition logic
  behind the transcript announcements; changing the configured UID
  rebaselines silently. Pinned by `AudioDeviceTests`.

## B. AppConfig

`audioInputUID: String?` and `audioOutputUID: String?` (nil = system
default), tolerant optional-string decode like every other optional field.

## C. SpeechService — chosen microphone

`var preferredInputDeviceID: (() -> AudioDeviceID?)?` (set by AppState).
`startListening()` resolves it and points the engine's input unit at the
device via `kAudioOutputUnitProperty_CurrentDevice` BEFORE reading the tap
format (the format follows the device); nil or an unplugged pick resolves
to the system default (queried explicitly, so a previous override never
sticks). Best-effort: a failed set leaves the current device, and the
existing 0 Hz format guard still protects. Resolution happens per press —
that is what makes unplug-fallback and auto-restore automatic.

## D. TTSService — routed speech output

`var preferredOutputDeviceID: (() -> AudioDeviceID?)?` (set by AppState).
When it resolves, `speak(...)` takes the routed path; otherwise the plain
system-route path is byte-for-byte unchanged.

Routed path (all spike-verified): a DEDICATED `renderSynthesizer` renders
via `write(_:toBufferCallback:)` (a shared instance cannot distinguish
renders from speech — `write` fires the same delegate callbacks and leaves
`isSpeaking` false); a locked `RenderCollector` gathers PCM buffers off the
callback's undocumented thread and completes idempotently at the FIRST
zero-length end marker (it arrives twice); buffers in any format other than
float32/deinterleaved (untested premium/personal voices) are normalized via
`AVAudioConverter` BEFORE the engine sees them — `connect(...)` raises an
uncatchable NSException on refused formats, so do/catch cannot be that
guard; playback goes collect-then-play through a fresh `AVAudioEngine` +
`AVAudioPlayerNode` connected with the normalized format (the mixer
resamples) and bound to the device via `kAudioOutputUnitProperty_CurrentDevice`
before `engine.start()`; the last buffer's `.dataPlayedBack` completion
ends the utterance. Failures (device vanished at start, conversion failure)
fall back to a default-route engine or resolve `isSpeaking`/`onFinished`
honestly. A device unplugged MID-playback is covered by
`recoverIfEngineDied()` — AppState calls it on every device-list change and
it resolves the utterance when the routed engine halted on its own (whether
the self-halt fires pending completions is undocumented; the hook makes
wedging impossible either way — physical-unplug verification pending).
`stop()` bumps the render generation (stale callbacks no-op), cancels the
render with an UNCONDITIONAL `stopSpeaking` (`isSpeaking` stays false
during renders, so guarding on it would orphan the render), and tears the
engine down. `isSpeaking`/`onFinished` semantics are unchanged for callers.

## E. AppState + Settings

- `let audioDevices = AudioDeviceStore()`, started with the other services
  and observed for derived updates; closures wire the two services'
  preferred-device resolution to config + store.
- Transcript announcements on a chosen device's unplug/return (via
  `AudioAvailabilityTracker`; selection changes are silent). The trackers
  are baselined at init and re-baselined by `syncAudioAvailabilityBaseline`
  (keyed on the two UIDs, run from the derived-update path) whenever the
  selection changes — without that, the first transition after launch or
  after a pick would be swallowed as a rebaseline.
- Settings → Voice gains an **Audio Devices** section: Microphone and
  Speech Output pickers ("System Default" + live device lists, with a
  "(Disconnected device)" placeholder entry so an unplugged pick stays
  visible instead of snapping back).

Premium/enhanced-voice render formats remain unverified (none installed on
the dev machine); the fallback chain covers a format the engine refuses.
