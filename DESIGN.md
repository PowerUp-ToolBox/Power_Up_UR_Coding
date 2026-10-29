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
    case idle              // light: green  (0.0, 1.0, 0.2)
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
  *Amended by #118:* every sign of life that refreshes an entry (a
  `userPromptSubmit`, a v2.2 `postToolUse` heartbeat, or a `notification`
  for a turn already tracked) also re-arms the expiry check, so an entry
  clears 15 minutes after its LAST sign of life whatever that sign was. A
  notification used to refresh the timestamp without re-arming, which left
  a turn that went silent after a notification amber until an unrelated
  hook pruned it. Pinned by the `remote-*` scenarios in
  `Tests/Fixtures/session/`.
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
  *Amended by #119:* an ACP launch is never a resume, so the resume retry
  never fires for it and an agent's exit never clears the stored Claude
  session id. Events from an adapter that is no longer the active harness
  are ignored: a stopped claude process can flush output and exit up to 2 s
  after a switch, and none of that may touch the new session.
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
*Amended by #116:* the two presses must be consecutive. Any other intent
between them disarms the request (it stays pending, unanswered), so the next
✕ arms again instead of approving. Interrupt (built-in mode) clears
`pendingPermission` at once, without a `respondToPermission`: the adapter
already cancels the agent's side of it on interrupt.
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
- **Chosen microphone lost mid-capture (#123).** When a capture is
  recording from the chosen microphone (snapshotted as `captureInputUID`
  when the recognizer starts — nil when it records from the system
  default) and a device-list change shows that UID gone, AppState ends the
  capture at once, whoever started it: `isPTTActive`/`isDraftDictation`
  cleared, the hold tracker is reset (v2.7 §C; the still-held trigger's
  release is a no-op), a local draft hold restores the prompt box, the recognizer is
  stopped with its result discarded (nothing is sent or typed), one error
  transcript entry, the error haptic. The came/went announcement still
  follows, and the next capture falls back to the system default through
  the usual per-press resolution. A capture on the system default is left
  alone. The persisted `audioInputUID` is never touched.
- Settings → Voice gains an **Audio Devices** section: Microphone and
  Speech Output pickers ("System Default" + live device lists, with a
  "(Disconnected device)" placeholder entry so an unplugged pick stays
  visible instead of snapping back).

Premium/enhanced-voice render formats remain unverified (none installed on
the dev machine); the fallback chain covers a format the engine refuses.

---

# v2.6 addendum — keyboard & mouse voice control (the controller is optional)

Supersedes anything above where it conflicts. Motivation: the composer's mic
circle *looked* like a button (it even had "Push to talk" help text) but had
no action, and every voice path required a controller. The controller is now
an accessory, not a requirement: the full loop — record, review, send — works
from the keyboard and the mouse alone.

## A. AppState — toggle-style capture

```swift
func toggleVoiceCapture(_ mode: VoiceCaptureMode)  // mic button + keyboard
var canAcceptInput: Bool   // projectDir chosen, or remote mode
func answerPendingPermission(allow: Bool)  // banner Allow/Deny buttons
```

- `toggleVoiceCapture` is the entry point for input sources that have no
  press/release pair. Idle → `handle(.beginVoiceCapture(mode))`; active →
  clear `pttHoldButton`, then `handle(.endVoiceCapture)` — ending whatever
  capture is active, whichever source and mode started it.
- Clearing `pttHoldButton` on a toggle-stop is deliberate: a controller
  trigger still physically held after a keyboard stop must not end the
  *next* capture when it is finally released (`handleButtonUp` guards on
  `pttHoldButton == button` and then finds nothing to match).
- The reverse direction is already covered by v2.4's "one hold at a time":
  a hold press while a toggle-started capture is active is ignored
  (`guard pttHoldButton == nil, !isPTTActive`).
- `canAcceptInput` mirrors the composer's `canCompose` rule and gates the
  mic button and the Voice menu items. `toggleVoiceCapture` also refuses to
  *start* a capture while `!canAcceptInput` (stopping is always allowed) —
  a command menu's disabled state can lag the config, so the model-level
  guard is the one that holds. The UI gates make the same start/stop
  distinction: the mic button and the menu items disable on
  `!gate && !isPTTActive`, so the stop half of the toggle stays reachable
  when a capture is active while the gate is false (a controller hold with
  no project folder; a control-mode flip mid-recording).
- `forceReleaseHold()` (the controller-disconnect safety net) is narrowed
  to `guard pttHoldButton != nil`: it releases CONTROLLER-owned holds only.
  A toggle-started capture has nothing to do with the pad, keeps its
  working stop affordances, and must survive a pad powering off
  mid-dictation — force-ending a `.send` capture there would fire the
  half-finished transcript at the harness uninvited.
- `answerPendingPermission(allow:)` is the mouse path for a pending harness
  permission request: it routes through the same `.approve`/`.reject`
  intents as ✕/○ (destructive two-press arming included) and no-ops when
  nothing is pending, so a click racing the request's resolution can never
  fall through to approve()'s "send Yes/No as text" branch.
- `applyLight`'s memo key is `"\(controller.isConnected)|r,g,b"`: with
  activity outranking `.noController`, a pad that (re)connects mid-activity
  sees no status change, so color alone would memo-match and leave the
  fresh pad's light bar at its firmware default. Keying on `isConnected`
  forces the re-push (setLight while disconnected is a harmless no-op).

## B. Status derivation — activity outranks the missing controller

```swift
nonisolated static func derivedStatus(controllerConnected:isPTTActive:isSpeaking:isWorking:) -> AppStatus
```

`updateStatus()` now routes through this pure function. NEW precedence:
listening > speaking > thinking > (noController | idle). The v1 order put
`.noController` first, which would freeze the pill on "No Controller" while
a keyboard-started capture was recording. `.noController` is only the
resting state. `isWorking` folds in remote turns
(`harness.state == .working || (isRemoteMode && remoteTurnActive)`), as
before. Pinned by `StatusDerivationTests`.

## C. UI

- **ComposerBar (MainView.swift)**: the `PTTIndicator` is wrapped in a
  plain-style `Button` calling `appState.toggleVoiceCapture(.draft)`;
  disabled (0.6 opacity) when `!canCompose`. Click to start dictating into
  the prompt box, click again to stop — same review-then-send contract as
  the L2 hold.
- **PowerUpApp.swift**: a `CommandMenu("Voice")` with two items, both
  calling `toggleVoiceCapture`: "Dictate to Prompt Box" — retitled "Dictate
  to Remote Session" in remote mode, where that is where the words go —
  (⌘D, `.draft`) and "Talk to Claude (Sends on Stop)" (⇧⌘D, `.send`), each
  disabled when `!canAcceptInput && !isPTTActive`. Titles never swap
  Start/Stop (a closed menu could show it stale); only the dictation target
  varies.
- **Keyboard delivery (normative)**: every app shortcut — ⌘D, ⇧⌘D, ⌘N,
  ⌘↩, ⌘, — is performed by a local `NSEvent` keyDown monitor in AppState
  (`KeyboardCommand` + the pure `keyboardCommand(forKey:modifiers:)`,
  pinned by `KeyboardCommandTests`), which consumes the event. The
  `.keyboardShortcut` modifiers on menu items exist ONLY so the menu shows
  the glyphs: on macOS 26, AppKit's key-equivalent routing into a SwiftUI
  commands Button traps in `MainActor.assumeIsolated` inside
  `ButtonAction.callAsFunction` (verified crash, 2026-08-31, macOS 26.3
  25D5087f, macOS 14 SDK build) — the monitor runs first, so that path is
  never reached. Clicking the menu items still works normally. ⌘↩ through
  the monitor mirrors the composer's gate (`canAcceptInput`).
- **Opening Settings (normative)**: `AppState.openSettingsWindow()` is the
  ONLY route — the gear button and the monitor's ⌘, both call it. It fires
  the app menu's own "Settings…" item (found by its "," key equivalent)
  via `sendAction(action, to: item.target, from: item)`. Probe-verified on
  macOS 26.3 (2026-08-31): `SettingsLink` silently does nothing in
  macOS 14 SDK builds, `showSettingsWindow:` is accepted (returns true)
  but never presents the window, and `openSettings` does not exist in the
  14.2 SDK — while firing the menu item's own action/target does open the
  Settings scene. The legacy selector remains only as the no-item fallback.
- **PermissionRequestBanner (MainView.swift)**: gains clickable **Allow**
  (retitled **Confirm** once a destructive request is armed) and **Deny**
  buttons calling `answerPendingPermission(allow:)`, so tool approvals
  never require a controller. The ✕/○ hint text stays.
- **PTTIndicator (ComponentViews.swift)**: new `isRemoteMode: Bool = false`
  parameter so the *idle* tooltip can say "dictate into the remote session"
  in remote mode (`isRemoteDraft` only exists once a capture runs).
- **Sidebar (MainView.swift)**: a small `KeyboardHintsCard` (⌘D, ⇧⌘D, ⌘↩,
  ⌘N) under the Controls card, always visible.
- Copy: `PTTIndicator` help/accessibility now describes click-to-dictate
  (and "click again to stop" while active); `EmptyTranscriptCard` and
  `PairingHintCard` mention the mic button and ⌘D so a controller-less
  launch never reads as a dead end.

## D. Semantics notes

- A `.send`-mode toggle capture sends the transcript when stopped — same as
  releasing an R2 hold. The `.draft` mode is the one wired to the mic
  button precisely so a *click* can never send anything by itself.
- Draft captures keep all v1.8 behavior: in remote mode the text is typed
  into the remote target (no Enter); locally it lands in the prompt box.
- No protocol change: voice-capture intents remain local-only
  (IntentMapper's protocol vocabulary is unchanged).

---

# v2.7 addendum — vocabulary, device slots, and hold semantics

Supersedes anything above where it conflicts. Recorded on 2026-09-17 from a
design session; the vocabulary is fixed in `CONTEXT.md`, the decisions in
ADR 0012 (core library, per-OS UI) and ADR 0013 (three device slots). This
addendum is implemented by #130–#132 (step 5 of plan stage 1), with tests,
before any logic migrates into the Rust core.

## A. Renames (Models.swift, Intent.swift)

- `enum ControllerAction` → `enum Action`. Every case, its `displayName`,
  its Codable shape (`{"approve":{}}`, `{"sendPrompt":{"_0":"…"}}`) and
  `isHoldAction` are unchanged, so on-disk `config.json` is byte-identical.
  Keep `typealias ControllerAction = Action` marked `@available(*,
  deprecated)` for one release so out-of-tree callers get a warning, not a
  break; delete it in the release after.
- `typealias DeviceMapping = [String: Action]`;
  `IntentMapper.intent(for action: Action, phase: ControlPhase)`;
  `AppConfig.action(onProfile:control:) -> Action`.
- `ControlDescriptor.Kind` loses `hold`: `enum Kind: String, Codable { case
  button, axis, key }`. Whether an action holds is a property of the
  **action** (`isHoldAction`), never of the control. Decoding tolerates a
  legacy `"hold"` value by mapping it to `.button`; encoding never writes
  it. No shipped profile used it.
- `ControllerButton` stays as the DualSense profile's display-metadata
  source; nothing else is renamed in this addendum.

## B. Device slots (AppConfig, ControllerService, AudioDeviceStore)

Three slots, each holding at most one device (ADR 0013). Anything not in a
slot is ignored, never merged.

```swift
// AppConfig (Codable, defaults shown)
var controllerDeviceID: String?   // nil = Automatic; else a ControllerService instance id
var audioInputUID: String?        // unchanged from v2.5 — the Input slot
var audioOutputUID: String?       // unchanged from v2.5 — the Output slot

// ControllerService
struct ConnectedController: Identifiable, Equatable {
    let id: String            // stable per connection: vendor/product + GCController identity
    let profileID: String     // "dualsense" today; "xbox" / "generic-gamepad" in plan stage 4
    let displayName: String
}
@Published private(set) var connected: [ConnectedController]
@Published private(set) var active: ConnectedController?   // the Controller slot
```

- **Automatic** (`controllerDeviceID == nil`): the most recently connected
  controller fills the slot; when it disconnects, the next most recent
  takes over. An explicit id pins the slot to that device; if it is not
  connected the slot is empty (nothing responds) until it returns, and the
  Settings picker shows it greyed as "not connected". Input and Output keep
  v2.5's rule: chosen UID, else the system default, hot-plug safe.
- `ControllerService` delivers button events, light and haptic writes, and
  battery for the **active** controller only. Other connected pads are
  enumerated for the picker and otherwise inert: no events, no light, no
  low-battery warning.
- `AppState` continues to resolve through
  `config.action(onProfile: active.profileID, control: id)`; no new
  dispatch path.
- Implemented (#130). GameController exposes no serial number, so the id
  is `"<productCategory>/<vendorName>"`, with `#2`, `#3`, … when an
  identical pad is already connected. It is assigned at connect and never
  renumbered. A pad that reconnects alone gets its old id back, so a pin
  finds it again. Two identical pads are told apart only by connection
  order. `AppState` copies `controllerDeviceID` into the service's
  internal `pinnedControllerID`. When the slot changes, the outgoing pad's
  held buttons are released, then `onDisconnect` fires, and that drives
  `forceReleaseHold()` (§C). A connected pad outside the slot gets its
  light switched off. The low-battery latch resets whenever the slot
  changes (v2.3 A's "fallback swap").
- Settings, implemented (#132). A new **Devices** tab, placed after General,
  holds one "Devices" section with three pickers in the order Controller,
  Input, Output. Input and Output are v2.5's Microphone and Speech Output
  pickers, moved here from Settings → Voice unchanged apart from their
  labels and caption, which now use the slot words; a new intro caption
  explains the three slots. The Controller picker binds `controllerDeviceID`. Its rows come
  from the pure, internal `ControllerPicker.rows(connected:active:pinnedID:)`
  (ControllerPicker.swift): first Automatic (nil), then every entry of
  `connected` by `displayName`, with the active one suffixed "— in use",
  then, when the pin is not connected, a "<name> — not connected" row so
  the selection stays visible. The name comes from the internal
  `ControllerService.displayName(forID:)`, which inverts
  `connectionIdentity`. `ControllerPicker.note(...)` is the caption under
  the picker. Neither the picker nor the tab adds a menu key equivalent.
- The host keyboard and mouse are outside the slot model: the v2.6 local
  NSEvent monitor and mic button keep working regardless of the slot's
  contents.

## C. Hold semantics (replaces v2.4 §D and the v2.6 "reverse direction" note)

- **No cross-device arbitration.** Only the active controller can start a
  hold, so ownership is the control that started it, recorded as the
  owner in `AppState`'s `HoldTracker` (#131; it replaced `pttHoldButton`).
- **Two holds on the active controller cancel both.** If a second
  hold-mapped control is pressed while a hold capture is active, the
  capture ends **without sending or drafting** (partial transcript
  discarded), the owner clears, and the pad gets the error haptic
  (`0.9/60 ms`). Neither control's later release does anything. The
  existing trigger press threshold is unchanged so a brushed L2/R2 does not
  cancel a dictation.
- A hold press while a **toggle-started** capture (keyboard, mic button)
  is active is still ignored (v2.6), not a cancel: the pad never owned that
  capture.
- `forceReleaseHold()` keeps its v2.6 narrowing (controller-owned holds
  only) and also fires when the active controller changes slot.
- Pinned by new tests: cancel-both discards and pulses; toggle-started
  capture survives a hold press; slot change releases a controller hold.
- Implemented (#131). `AppState`'s private `holdTracker: HoldTracker`
  replaces `pttHoldButton`. Both button handlers pass every press and
  release to the tracker, with `toggleCaptureActive = isPTTActive &&
  owner == nil`, and apply the effect it returns. `beginCapture` and
  `endCapture` go through `handle(.beginVoiceCapture)` and
  `handle(.endVoiceCapture)`. `deliver` goes through `handle(intent)`.
  `cancelCapture` goes to a private discard path: it clears the capture
  state, restores the prompt box for a local draft hold, calls
  `speech.stopListening { _ in }` (the transcript is never read), plays the
  error haptic and adds no transcript entry. `forceReleaseHold()` is
  `releaseAll()` applied. The tracker is replaced with a fresh
  `HoldTracker()` on a toggle stop, a denied speech permission and a
  vanished microphone (v2.5 E).

## D. Profiles (ADR 0006, amended)

- Profiles describe **controllers** only. The Input and Output slots are
  plain audio-device picks with no profile.
- The profile JSON reserves two optional objects that this version neither
  writes nor interprets: `match` (how to recognise the hardware: vendor id,
  product id, product category, name pattern) and `report` (raw HID report
  layout, format to be defined by us later). Codable ignores unknown keys
  already; this note is so nobody claims those names for something else.

## E. Protocol v0 (docs/protocol.md)

Unchanged. Its role is the **local plugin API** for scripts and plugins on
the same machine; remote clients (phones) are deferred with ADR 0010. The
`intent` vocabulary, the loopback bind, the token and the Origin policy are
not touched by this addendum.

## F. Pure view rules (ViewLogic.swift)

- `enum ViewLogic` (#126) holds the product rules the main window shows as
  pure, Foundation-only functions (state in, text out): the push-to-talk
  hint, the empty-transcript prompt, the controller chip name and help, the
  permission banner labels and the cost chip. Internal to the module, like
  `AppState.derivedStatus` (v2.6); colors, symbols and layout stay in the
  views.
- `ViewLogic.pinnedControllerAwayNote(connected:active:pinnedID:)`: when
  the Controller slot is empty only because it is pinned to a controller
  that is away while another controller is connected, the controller chip's
  help and the sidebar say "<pinned name> isn't connected — choose
  Automatic in Settings → Devices to use another controller" instead of
  the pairing steps. With nothing connected at all, the pairing steps stay.

---

# v2.8 addendum — remote read-back is scoped to the project folder

Supersedes anything above where it conflicts (v1.4 "events from every claude
session", v1.10 per-session tracking, the Cycle Session Focus note that the
unfocused sessions "still log"). Recorded on 2026-10-26 after running
several agents in other repositories flooded PowerUp's transcript and
read-back.

## A. AppState — which hooks remote mode hears

- `handleRemoteEvent` drops a hook, before any other handling (no
  transcript line, no turn, no session-registry entry, no status change),
  unless `isInProjectFolder(event.cwd)`:
  - no project folder chosen (`projectDir` nil or empty): every hook counts,
    as before;
  - otherwise the hook's `cwd` must be the project folder or a folder below
    it, compared by whole path components after standardizing and resolving
    symlinks (`/work/app-old` is not inside `/work/app`);
  - a hook without a `cwd` cannot be placed, so it is dropped while a folder
    is chosen.
- The existing echo guard (our own `harness.sessionID`) still runs first.
- `adoptProject` in remote mode, when the folder actually changes, clears
  the remote turns, the known-session registry and the session focus: the
  old folder's hooks, including the Stop that would end its turns, are
  filtered out from then on.
- Labels are unchanged: the folder itself reads back unprefixed, a subfolder
  as `[<name>] `.
- Pinned by `Tests/Fixtures/session/remote-hooks-outside-the-project-folder-are-ignored.json`
  and `remote-project-switch-clears-the-old-folders-turns.json`.

# v2.9 addendum — the idle light is green

Supersedes the `AppStatus.idle` light color above. Recorded on 2026-10-28 at
the maintainer's request: a green bar reads as "ready, nothing running".

- `.idle` lights the bar `(0.0, 1.0, 0.2)`; the sidebar status dot for idle
  uses `Theme.success` so it still matches the bar.
- Every other status color is unchanged: listening red, thinking amber,
  speaking purple, no controller off.

# v2.10 addendum — the Rust core bridge (stage 2.1)

Recorded 2026-10-28 for #139 (ADR 0012, plan stage 2 step 1).

## A. Swift-side surface

- Module `PowerUpCore` (generated by uniffi from `rust/powerup-core-ffi`),
  linked only when the package is built with `POWERUP_CORE=1`; the app target
  then compiles with `POWERUP_CORE` defined. Until slice 2.2 the app builds
  and runs without it.
- Every bridge function is synchronous, called on the main actor, and
  `throws` `CoreBridgeError`:
  - `.Failed(message: String)`: the core reported a failure;
  - `.Panicked(message: String)`: the core panicked and the bridge caught it.
    A core panic never unwinds into or aborts the app.
- Stage 2.1 exports only the bridge probes: `probeEcho(text:) -> String`,
  `probeFail(message:) -> String` (always throws `.Failed`),
  `probePanic(message:) -> String` (always throws `.Panicked`).

## B. App behavior

- `CoreBridge.check()` calls `probeEcho` once at launch and logs the outcome
  (subsystem `com.powerup.claudepad`, category `core`): "Rust core linked and
  answering", "not linked", or "linked but failed". Nothing is shown to the
  person; the log is the stage 2 kill rule's evidence that the bridge runs
  inside the signed bundle.

# v2.11 addendum — the device layer moves into the Rust core (stage 2.2)

Recorded 2026-10-29 for spec #97 (tickets #143–#147, ADR 0012, plan stage 2
step 2). Supersedes v2.10 A/B on linking, and v2.4 B/C and v2.7 A/C on where
the rules live; the rules themselves are unchanged.

## A. The core is mandatory

- `Package.swift` always links `PowerUpCoreFFI` (the xcframework) and
  `PowerUpCore` (the generated Swift) from `rust/build/`. There is no
  `POWERUP_CORE` switch or compile define any more. When
  `rust/build/PowerUpCoreFFI.xcframework` or `rust/build/swift/PowerUpCore.swift`
  is missing, the manifest stops with a message telling the developer to run
  `./scripts/build-core.sh` first. (SwiftPM caches a passing evaluation, so a
  bridge deleted after a good build shows SwiftPM's own missing-artifact
  error instead; the fix is the same.)
- Rust (rustup) and a full Xcode install (`xcodebuild`) are build
  requirements. `scripts/build.sh` always builds the core (release) and
  fails with a clear message when either is missing; there is no build
  without the core and no `POWERUP_REQUIRE_CORE`.
- CI's macOS job builds the core, then runs `swift build` and `swift test`,
  then the bundle pipeline; the bundle check greps the app binary for the
  bridge's symbols.
- `CoreBridge.Status` is `answering | failed(String)`. The launch check and
  its log line are unchanged ("Rust core linked and answering", or "linked
  but failed: …", subsystem `com.powerup.claudepad`, category `core`); the
  "not linked" line is gone.
- `Sources/PowerUp/CoreBridge.swift` is the only app file that imports
  `PowerUpCore`.

## B. Bridge surface

Generated by uniffi into module `PowerUpCore` from
`rust/powerup-core-ffi/src/mapping.rs` and `src/device.rs`, which convert
to and from the `powerup-core` types (the core itself carries no uniffi).
Every generated type has a `Core` prefix so it never collides with the app's `Action` or
`Intent`, and uniffi spells names its own way (`toggleTts`, `profileId`,
`Json`), which the rename table cannot change.

| Generated Swift | Shape |
| --- | --- |
| `enum CoreAction` | `none, pushToTalk, sendPrompt(prompt: String), approve, reject, interrupt, stopSpeaking, replayLastReply, toggleTts, newSession, showWindow, cycleModel, cycleEffort, cyclePermissionMode, cycleProject, cycleFocus, pushToTalkDraft, sendDraft, toggleControlMode` |
| `enum CoreVoiceCaptureMode` | `send, draft` |
| `enum CoreControlPhase` | `began, ended` |
| `enum CoreIntent` | `beginVoiceCapture(mode: CoreVoiceCaptureMode), endVoiceCapture, sendPrompt(prompt: String), sendDraft, approve, reject, interrupt, stopSpeaking, replayLastReply, toggleTts, newSession, showWindow, cycleModel, cycleEffort, cyclePermissionMode, cycleProject, cycleFocus, toggleControlMode` |
| `enum CoreControlKind` | `button, axis, key` |
| `struct CoreControlDescriptor` | `id, kind: CoreControlKind, displayName, symbolName` |
| `struct CoreDeviceProfile` | `id, displayName, controls: [CoreControlDescriptor]` |
| `struct CoreMappingLoad` | `deviceMappings: [String: [String: CoreAction]], backupBeforeSave: Bool` |

### The mapping layer

Functions, each `throws CoreBridgeError`:

- `intentForAction(action:phase:) -> CoreIntent?`
- `actionIsHold(action:) -> Bool`
- `actionWireJson(action:) -> String` — compact JSON byte-identical to
  `JSONEncoder` with `.sortedKeys` (`/` written as `\/`).
- `resolveAction(deviceMappings:profileId:controlId:) -> CoreAction`
- `defaultDeviceMappings() -> [String: [String: CoreAction]]`
- `loadDeviceMappings(configJson:) -> CoreMappingLoad` — takes a config.json
  object as text; `.Failed` when the text is not a JSON object or nests
  deeper than 512 levels. That is JSONDecoder's own limit, so any file the
  app can decode loads; serde_json's default limit of 128 is lifted.
- `controlKindFromWire(name:) -> CoreControlKind?`
- `dualsenseProfile() -> CoreDeviceProfile`

Every call is synchronous, pure and stateless, so it is safe from any thread;
the app calls it from wherever it already runs. This relaxes v2.10 A's "called
on the main actor". There are no uniffi objects or callback interfaces: their
generated Swift needs Swift 5.10.

The app reaches these only through `enum CoreBridge`
(`Sources/PowerUp/CoreBridge.swift`), whose static wrappers take and return
the app's own types:

```swift
static func intent(for action: Action, phase: ControlPhase) -> Intent?
static func isHold(_ action: Action) -> Bool
static func wireJSON(of action: Action) -> String?
static func action(in deviceMappings: [String: DeviceMapping], profileID: String, controlID: String) -> Action
static func defaultDeviceMappings() -> [String: DeviceMapping]
struct MappingLoad: Equatable { let deviceMappings: [String: DeviceMapping]; let backupBeforeSave: Bool }
static func loadDeviceMappings(configJSON: String) -> MappingLoad?
static func controlKind(wireName: String) -> ControlDescriptor.Kind?
static func dualSenseProfile() -> DeviceProfile?
```

Config text crosses the bridge as `JSONValue` (an internal Codable JSON
value in CoreBridge.swift) written out with `.sortedKeys`. Its outermost
object is written by hand and only the members by JSONEncoder, which refuses
512 levels of nesting that JSONDecoder reads, so every config the app can
decode reaches the core whole.

**Failure policy.** A bridge error is a core bug: the core never fails or
panics on these inputs. Each wrapper logs it (subsystem
`com.powerup.claudepad`, category `core`, `.error`) and returns the inert
answer: intent → nil, isHold → false, resolve → `.none`, defaults → `[:]`,
loadDeviceMappings → nil (AppConfig then uses the defaults, so ConfigStore
first takes the `config.pre-profiles.json` copy as for any lossy load), controlKind → nil (the control fails to decode),
dualSenseProfile → nil (`DeviceProfile.dualSense` becomes a profile with no
controls, which `DeviceProfileTests.testDualSenseIDMatchesTheCore` catches).

### The device layer

| Generated Swift | Shape |
| --- | --- |
| `struct CoreConnectedController` | `id, profileId, displayName` |
| `struct CoreHoldState` | `owner: String?` — the hold rule's whole state |
| `enum CoreHoldEffect` | `beginCapture(mode: CoreVoiceCaptureMode), endCapture, cancelCapture, deliver(intent: CoreIntent), ignore` |
| `struct CoreHoldStep` | `state: CoreHoldState, effect: CoreHoldEffect` |

Functions, each `throws CoreBridgeError`:

- `selectActiveController(mostRecentlyConnectedFirst:pinnedId:) -> CoreConnectedController?`
  — the Controller slot rule (v2.7 B): Automatic (`nil`) takes the head of
  the caller's list; a pin takes the first entry with exactly that id, or
  nothing, and never falls back to Automatic.
- `holdTrackerStep(state:action:controlId:phase:toggleCaptureActive:) -> CoreHoldStep`
  — the hold rule (v2.7 C) for one input.
- `holdTrackerReleaseAll(state:) -> CoreHoldStep` — ends a hold the
  controller owns (never cancels it); ignored when it owns none.

The hold state is a value: the bridge keeps nothing between calls. Swift
passes the owner in and keeps the owner that comes back. When a capture ends
anywhere but through these two calls (a toggle stop, a denied permission, a
vanished microphone), the caller must reset it to no owner, as AppState
already does by replacing its `HoldTracker` (HK-032).

`CoreBridge` wrappers:

```swift
static func activeController(mostRecentlyConnectedFirst: [ConnectedController], pinnedID: String?) -> ConnectedController?
static func holdStep(owner: String?, action: Action, control: String, phase: ControlPhase,
                     toggleCaptureActive: Bool) -> (owner: String?, effect: HoldEffect)
static func holdReleaseAll(owner: String?) -> (owner: String?, effect: HoldEffect)
```

Failure policy, as for the mapping layer: activeController → nil (the slot
is empty); holdStep and holdReleaseAll → the owner unchanged and `.ignore`.

## C. What moved and what stayed

Moved into `powerup-core`, unchanged in behaviour: the intent rule
(`intent::intent_for`), `isHoldAction` (`Action::is_hold`), action
resolution (`mapping::resolve_action`), the default mapping
(`mapping::default_mapping`), the mapping subtree decode — per-entry
tolerance, legacy migration, the new key winning — and the backup decision
(`mapping::load_device_mappings`), the control-kind rule
(`ControlKind::from_wire`), the DualSense profile
(`profile::dualsense_profile`), the Controller slot rule
(`slots::select_active_controller`) and the hold rule (`hold::HoldState`).

Kept as thin Swift wrappers, so call sites and tests are unchanged:
`IntentMapper.intent(for:phase:)`, `Action.isHoldAction`,
`AppConfig.action(onProfile:control:)`, `AppConfig.defaultDeviceMappings()`
and `defaultMapping()`, `ControlDescriptor.Kind.init(from:)`,
`DeviceProfile.dualSense`, `ControllerSlotSelector.active`, and
`HoldTracker.effect(for:control:phase:toggleCaptureActive:)` and
`releaseAll()` (the tracker keeps only `owner`, the core's state). Each body
is one bridge call; the Swift rule bodies are deleted. They are not inlined
into their call sites and views never see generated types, because uniffi's
spelling (`toggleTts`, `profileId`) cannot match the app's (`toggleTTS`,
`profileID`) and the existing tests spell the app's.

Stayed in Swift:

- the protocol name table `IntentMapper.intent(forProtocolName:text:)`
  (until slice 2.6);
- `Action`'s synthesized `Encodable` and the config writer (until slice
  2.5). `Action` is no longer `Decodable`: only the core decodes actions. The
  shared `mapping/action-shape.json` table pins the two writers to the same
  bytes;
- the button-keyed `AppConfig.mapping` compatibility view;
- the backup copy itself (`config.pre-profiles.json`, once, never
  overwritten) in ConfigStore;
- ControllerService (GameController, connection order, id assignment,
  held-button release on a slot change), ViewLogic and ControllerPicker;
- capture orchestration around the hold effects: AppState applies each
  `HoldEffect` to SpeechService, the prompt box and the haptics.

`ControllerButton`'s `CodingKeyRepresentable` conformance is gone: nothing
encodes or decodes a button-keyed dictionary any more.

## D. Recorded rules

These are Swift's behaviour, pinned by the shared fixtures and now the
core's:

- Action decoding is Swift's synthesized enum `Codable`: the value must be an
  object; keys that are not case names are invisible; exactly one case key
  may remain; its payload must be an object; `sendPrompt` needs a string
  `_0`; extra payload keys are ignored (`mapping/action-decode.json`).
- A `deviceMappings` that is present but not an object (null, a string, an
  array) does not win, and still triggers the backup; `"deviceMappings": {}`
  means no bindings, not the defaults, and is not backed up; a legacy mapping
  with a key that is not a DualSense control id resets to the defaults; a
  legacy `{}` migrates to an empty DualSense profile. A known action with an
  unknown sibling key loads and is not backed up, so the sibling is lost on
  the next save — kept knowingly (`mapping/config-load.json`, ledger
  HK-385..389).
- `match` and `report` in a profile are read past and never written or
  claimed (v2.7 D); Swift's behaviour wins over "unknown-key preservation"
  (`device/profile-decode.json`, HK-391).

# v2.12 addendum — the Claude parser and the session state machine move into the Rust core (stage 2.3)

Recorded 2026-10-29 for spec #98 (tickets #148–#152, ADR 0012, plan stage 2
step 3). Supersedes v2.11 A on which files import `PowerUpCore`, and v2.11 B
on "no uniffi objects". The protocol rules themselves (v1.1 A and the
addenda after it) are unchanged.

The core gains `harness::claude` (the Claude adapter's rules: the stream-json
line reader and parser, the stdout line buffer, the stdin lines, the launch
argv and the process rules), `harness::destructive`, `status`, and a
top-level `session` module (AppState's session rules, remote mode included;
it is top-level because remote mode is not a harness). Sections A and B
describe the bridge surface (#151); C to E the effect executor, what moved
and the recorded rules (#152).

## A. Bridge surface

Generated by uniffi into module `PowerUpCore` from
`rust/powerup-core-ffi/src/harness.rs` and `src/session.rs`. As in v2.11 B
every type carries a `Core` prefix and uniffi's spelling (`sessionId`,
`costUsd`, `isPttActive`); `Vec<u8>` is `Data`, `u64` is `UInt64`, `i32` is
`Int32`, `f32` is `Float`. Every function, constructor and method `throws
CoreBridgeError`.

### The Claude harness

| Generated Swift | Shape |
| --- | --- |
| `enum CoreClaudeEvent` | `ready(sessionId:model:)`, `textDelta(text:)`, `assistantMessage(text:)`, `toolUse(name:detail:)`, `turnCompleted(resultText: String?, costUsd: Double?, isError: Bool, subtype: String)`, `controlResult(action:ok:detail:value: String?)`, `processError(message:)`, `terminated(exitCode: Int32)` |
| `enum CoreHarnessEvent` | `sessionReady(sessionId:model:)`, `replyDelta(text:)`, `reply(text:)`, `toolUse(name:detail:)`, `turnCompleted(resultText:costUsd:isError:detail:)`, `controlResult(action:ok:detail:value:)`, `permissionRequest(id:name:kind:detail:)`, `notification(message:)`, `runtimeError(message:)`, `ended(exitCode: Int32)` |
| `enum CoreHarnessState` | `stopped, starting, ready, working` |
| `struct CoreHarnessConfiguration` | `projectDir: String` (a path), `model`, `permissionMode`, `effort`, `resumeSessionId: String?`, `binaryPathOverride: String?`, `agentCommand: [String]?` |
| `struct CoreClaudeSnapshot` | `state: CoreHarnessState, sessionId: String?, modelName: String?, totalCostUsd: Double` |
| `enum CoreClaudeEffect` | `publish(snapshot:)`, `resolveBinary(generation: UInt64, binaryPathOverride: String?)`, `spawn(generation:executable:arguments:projectDir:)`, `writeStdin(line: Data)`, `closeStdin`, `terminateAfterGrace(seconds: Double)`, `emit(event: CoreHarnessEvent)` |
| `class CoreLineBuffer` | `init() throws`; `ingest(chunk: Data) -> [Data]` (the lines the chunk finishes; empty lines dropped, `\r` kept, a tail past 16 MiB dropped); `flushRemainder() -> Data?` (the tail at end of stream, emptying the buffer) |
| `class CoreClaudeAdapter` | `init(requestIdPrefix: String) throws`; `generation() -> UInt64`; `snapshot() -> CoreClaudeSnapshot`; `start(configuration:)`, `binaryResolved(generation:path:)`, `spawned(generation:)`, `spawnFailed(generation:executable:description:)`, `send(text:processRunning:)`, `interrupt(processRunning:)`, `setModel(model:processRunning:)`, `setPermissionMode(mode:processRunning:)`, `stop()`, `stdoutEvent(generation:event:)`, `terminated(generation:exitCode:clean:stderrTail:)`, `stdinWriteFailed(description:)`, each `-> [CoreClaudeEffect]` |

Functions:

- `claudeEventsFromLine(line: Data) -> [CoreClaudeEvent]` — one stdout line
  without its newline; anything unrecognized gives `[]`. The reader accepts
  exactly what Foundation's `JSONSerialization` accepts (ledger HK-393,
  HK-394) and never recurses, so a deeply nested line cannot overflow a
  pipe reader thread's stack.
- `harnessEventFromClaude(event:) -> CoreHarnessEvent` (HK-090).
- `claudeLaunchArguments(model:permissionMode:effort:resumeSessionId:) -> [String]`.
- `claudeUserTurnLine(text:) -> Data?` and
  `claudeControlRequestLine(requestId:subtype:value:) -> Data?` — newline
  included, keys in a fixed order (HK-395), control requests always in the
  nested envelope of v1.1 A. `subtype` is `interrupt`, `set_model` or
  `set_permission_mode`; a value that trims to nothing gives nil, any other
  subtype throws `.Failed` (the adapter builds its own requests, so only
  tests call it).

### The session

| Generated Swift | Shape |
| --- | --- |
| `enum CoreHarnessKind` | `claude, acp` |
| `struct CoreSessionSettings` | `harnessKind, acpAgent, acpCustomCommand, controlMode, model, modelCycle: [String], effort, permissionMode, projectDir: String?, lastSessionId: String?, sessionIdsByProject: [String: String], recentProjectDirs: [String], claudePath: String?, remoteAutoSubmit: Bool` |
| `struct CoreHarnessSnapshot` | `state, sessionId: String?, modelName: String?, supportsEffort: Bool` |
| `struct CoreSessionContext` | `settings, claude: CoreHarnessSnapshot, acp: CoreHarnessSnapshot?, acpAgentCommand: [String]?, now: Double` (seconds since the reference date) |
| `struct CorePlacedPath` | `components: [String]` (standardized, symlinks resolved, root first), `standardized: String`, `name: String` |
| `enum CoreHookKind` | `userPromptSubmit, postToolUse, notification, stop, sessionEnd` |
| `struct CoreHookEvent` | `kind, text: String?, sessionId: String?, cwd: String?, cwdPlace: CorePlacedPath?` |
| `enum CoreTranscriptKind` | `user, assistant, tool, system, error` |
| `enum CoreRemoteKey` | `enter, escape, shiftTab` |
| `struct CorePendingPermission` | `id, name, detail, isDestructive: Bool, armed: Bool` |
| `enum CoreConfigChange` | `model(value:)`, `effort(value:)`, `permissionMode(value:)`, `controlMode(value:)`, `projectDir(path:)`, `lastSessionId(sessionId: String?)`, `projectSessionId(projectDir:sessionId: String?)` (nil removes the entry), `recentProjectDirs(paths:)` |
| `enum CoreSessionEffect` | `startHarness(harness:configuration:)`, `sendToHarness(harness:text:)`, `interruptHarness(harness:)`, `setHarnessModel(harness:model:)`, `setHarnessPermissionMode(harness:mode:)`, `answerPermission(harness:id:allow:)`, `stopHarness(harness:)`, `changeConfig(change:)`, `appendTranscript(kind:text:)`, `showProjectTranscript(projectDir:restoreHistory:)`, `appendLiveReply(text:)`, `clearLiveReply`, `setLastReply(text:)`, `pendingPermissionChanged(permission:)`, `remoteTurnActiveChanged(active:)`, `remoteFocusChanged(sessionId:)`, `haptic(intensity: Float, duration: Double)`, `errorHaptic`, `announce(phrase:)`, `speakReply(text:)`, `cancelSummary`, `stopSpeaking`, `injectText(text:submit:)`, `injectKey(key:)`, `refreshRemoteStatus`, `scheduleRemoteTurnCheck(afterSeconds:)`, `deferEffortRestart`, `updateStatus` |
| `enum CoreAppStatus` | `noController, idle, listening, thinking, speaking` |
| `class CoreSession` | `init(initial: CoreSessionSettings) throws` (adopts the stored control mode and harness selection without acting, HK-166); `startSessionIfNeeded(context:)`, `newSession(context:)`, `sendUserText(context:text:)`, `interrupt(context:)`, `answerPendingPermission(context:allow:)`, `adoptProject(context:path:moveToFront:)`, `switchProject(context:path:)`, `cycleProject(context:existingRecents:)`, `handleIntent(context:intent: CoreIntent)`, `harnessEvent(context:from:event:)`, `hookEvent(context:hook:projectPlace:)`, `remoteTurnCheck(context:)`, `deferredEffortRestart(context:)`, `syncSettings(context:)`, `sendRefused(context:)`, `shutdown(context:)`, each `-> [CoreSessionEffect]`; queries `pendingPermission() -> CorePendingPermission?`, `remoteTurnActive() -> Bool`, `remoteFocus() -> String?`, `remoteFocusLabel() -> String?` |

Functions: `derivedStatus(controllerConnected:isPttActive:isSpeaking:isWorking:)
-> CoreAppStatus`, `derivedIsWorking(harnessState:isRemoteMode:remoteTurnActive:)
-> Bool`, `liveRemoteTurns(turns: [String: Double], now:expiry:) -> [String:
Double]`, `remoteTurnIsActive(turns:focus:) -> Bool`, `remoteTurnExpirySeconds()
-> Double`, `modelChipLabel(configured:reported:) -> String`,
`isDestructive(kind:title:detail:) -> Bool`, `destructivePatterns() ->
[String]` (the classifier's list, so the Swift suite can count its table
against it), `effortCycle()`,
`permissionModeCycle()`, `defaultModelCycle()` (each `-> [String]`),
`effortDisplayName(effort:)`, `acpAgentDisplayName(agent:)` (each `-> String`),
`isRemoteMode(controlMode:) -> Bool`, `harnessKindFromSetting(raw:) ->
CoreHarnessKind`. `CoreIntent` is v2.11's.

### The Swift wrappers

`Sources/PowerUp/CoreBridgeHarness.swift` and
`Sources/PowerUp/CoreBridgeSession.swift` extend `enum CoreBridge`; with
`CoreBridge.swift` they are the only app files that import `PowerUpCore`.
They take and return the app's own types (`ClaudeEvent`, `HarnessEvent`,
`ClaudeState`, `HarnessConfiguration` with `projectDir` as a directory URL,
`TranscriptEntry.Kind`, `RemoteControlService.RemoteKey`,
`AppState.PendingPermission`, `AppStatus`, `Intent`, `RemoteHookEvent`):

```swift
static func claudeEvents(fromLine line: Data) -> [ClaudeEvent]
static func harnessEvent(from event: ClaudeEvent) -> HarnessEvent
static func claudeLaunchArguments(model: String, permissionMode: String, effort: String, resumeSessionID: String?) -> [String]
static func claudeUserTurnLine(_ text: String) -> Data?
static func claudeControlRequestLine(requestID: String, subtype: String, value: String?) -> Data?
final class LineBuffer: @unchecked Sendable { init(); func ingest(_ chunk: Data) -> [Data]; func flushRemainder() -> Data? }
struct ClaudeSnapshot: Equatable { var state: ClaudeState; var sessionID: String?; var modelName: String?; var totalCostUSD: Double }
enum ClaudeAdapterEffect: Equatable {
    case publish(ClaudeSnapshot), resolveBinary(generation: UInt64, binaryPathOverride: String?)
    case spawn(generation: UInt64, executable: String, arguments: [String], projectDir: String)
    case writeStdin(Data), closeStdin, terminateAfterGrace(seconds: TimeInterval), emit(HarnessEvent)
}
final class ClaudeAdapter { init(requestIDPrefix: String); var generation: UInt64; var snapshot: ClaudeSnapshot
    /* one method per core method, `send(_:processRunning:)` etc., each -> [ClaudeAdapterEffect] */ }

enum HarnessKind: Equatable { case claude, acp }
struct HarnessSnapshot: Equatable { var state; var sessionID; var modelName; var supportsEffort; init(of adapter:) /* main actor */ }
struct PlacedPath: Equatable { let components: [String]; let standardized: String; let name: String
    static func place(_ path: String) -> PlacedPath }
struct SessionContext { var config: AppConfig; var claude: HarnessSnapshot; var acp: HarnessSnapshot?; var acpAgentCommand: [String]?; var now: Date }
enum ConfigChange: Equatable { case model, effort, permissionMode, controlMode, projectDir, lastSessionID, projectSessionID(projectDir:sessionID:), recentProjectDirs }
enum SessionEffect: Equatable { /* the CoreSessionEffect cases in the app's types; scheduleRemoteTurnCheck(after:) */ }
final class Session { init(initial config: AppConfig)
    /* one method per core call with (context:…), each -> [SessionEffect];
       hookEvent(context:hook: RemoteHookEvent, place:) places the hook's cwd and the project folder */
    var pendingPermission: AppState.PendingPermission?; var remoteTurnActive: Bool; var remoteFocus: String?; var remoteFocusLabel: String? }
static func derivedStatus(controllerConnected:isPTTActive:isSpeaking:isWorking:) -> AppStatus
static func derivedIsWorking(harnessState:isRemoteMode:remoteTurnActive:) -> Bool
static func liveRemoteTurns(_ turns: [String: Date], now: Date, expiry: TimeInterval) -> [String: Date]
static func remoteTurnIsActive(_ turns: [String: Date], focus: String?) -> Bool
static var remoteTurnExpiry: TimeInterval
static func modelChipLabel(configured: String, reported: String?) -> String
static func isDestructive(kind: String, title: String, detail: String) -> Bool
static func destructivePatterns() -> [String]
static func effortCycle() / permissionModeCycle() / defaultModelCycle() -> [String]
static func effortDisplayName(_:) / acpAgentDisplayName(_:) -> String
static func isRemoteMode(controlMode:) -> Bool; static func harnessKind(fromSetting:) -> HarnessKind
```

`PlacedPath.place` is the filesystem half of the folder rules (ledger
HK-398): `URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL`
gives `standardized` and, after `resolvingSymlinksInPath()`, `components`;
`name` is the standardized path's last component. The core applies the
whole-component membership test and builds the `[name] ` label from these.

**Failure policy** (ledger HK-399), as in v2.11 B: a bridge error is a core
bug, so each wrapper logs it (subsystem `com.powerup.claudepad`, category
`core`, `.error`) and answers inertly. The line parser gives no events and
the line buffer no lines (or no tail); the adapter and session calls give no
effects; a snapshot reads as stopped and the generation as 0; the queries
read as nothing pending, no remote turn, no focus; an object whose
constructor failed answers every call that way. `harnessEvent(from:)` gives
`.runtimeError("PowerUp's core could not read an event.")`, so a lost event
is never silent; the stdin and argv functions give nil and `[]`, so nothing
is sent or spawned; the status gives `.noController`, `derivedIsWorking`
false, `liveRemoteTurns` the table unchanged, the expiry 15 minutes, the chip
the configured alias; `isDestructive` gives **true**, the safe side (one
extra press); the cycles and the pattern list give `[]` and the display
names their input.

## B. Objects

- **No callbacks.** Nothing in the core calls into Swift. uniffi callback
  interfaces and foreign traits generate Swift that needs 5.10, so they stay
  forbidden. Every call returns its lines, events or effects, and Swift
  acts on them in order.
- **Objects are allowed.** uniffi Objects (`#[derive(uniffi::Object)]`, an
  `Arc` with an inner `Mutex`) generate an `open class … @unchecked
  Sendable` whose Swift, fallible constructors included, compiles and runs
  under Swift 5.9.2 / Xcode 15.2. They replace v2.11's "no objects".
- **Lifetime is Swift's.** One `CoreLineBuffer` per launch, owned by that
  launch's `IOChannel`; one `CoreClaudeAdapter` per `ClaudeService`, alive
  across launches (the launch generation lives inside); one `CoreSession`
  per `AppState`, created in its initializer from the stored config. (It is
  made just before the launch bookkeeping is seeded, because Swift needs
  every stored property before the first method call; the seeding touches
  neither setting the session adopts.) The core object goes when its Swift
  owner does.
- **Threads.** `CoreLineBuffer` is the only object called off the main
  actor: the stdout readability handler and the termination drain feed it
  from GCD threads. Each launch has its own buffer, so its lock is never
  contended in the app. The adapter and the session are called on the main
  actor only, because their effects must run in the order the calls were
  made; their lock only keeps the object sound. A call that re-enters (an
  effect that makes an adapter report an event at once) cannot deadlock,
  because each call returns before its effects run.
- **Panics.** Every constructor and method runs inside `contain()`. A panic
  while an object's lock is held poisons it; the bridge takes the state
  anyway, so one caught core bug costs at most the call that hit it, never
  the object for the rest of the run.

## C. The effects and the executor

The core decides; the platform carries out what it decides, in order
(CONTEXT.md, **Effect**). Two machines, each one object:

- **The Claude adapter** (`CoreBridge.ClaudeAdapter`, one per
  `ClaudeService`). Its effects, in the glossary's words: *publish* the
  adapter's state; *resolve the binary* off the main thread, then report it;
  *spawn* the CLI with the core's argv in the project folder, then report
  `spawned` or `spawnFailed`; *write a line* on stdin or *close stdin*; *arm
  the kill* (terminate the process current now if it still runs after the
  grace, HK-078); *emit* a `HarnessEvent` to the session.
- **The session** (`CoreBridge.Session`, one per `AppState`). Its effects:
  the **Harness** — start it (fresh or resuming a session id), send a
  prompt, interrupt the turn, switch its model or permission mode live,
  answer a permission request, stop it, each addressed to the Claude or the
  ACP adapter; the **config** — each setting the rules write, in the order
  the Swift rules wrote them (the stored and per-project session ids
  included); the **transcript** — append an entry, switch to a project
  folder's history, the live reply text, the reply Replay speaks;
  **published state** — the pending permission request, the remote turn
  flag and the remote focus, each sent only when it changes, which AppState
  mirrors into its `@Published` properties; **feedback** — a haptic, the
  error buzz, a spoken confirmation, a spoken reply, cancelling a summary,
  stopping speech; **remote mode** — type text or press a key in the remote
  session, refresh what the remote target offers; **timing** — a remote-turn
  check after some seconds, the effort restart deferred past the current
  event delivery, a status update.

Every session call takes a `SessionContext` built at that moment: the config
as it is now (settings are read live, HK-165), each adapter's state (the ACP
adapter only once it exists, or is selected) and the injected clock's time.
Within one call the session models what its own harness commands do at once
(a start makes the adapter starting with the resumed id and no model, a send
makes it working, a stop makes it stopped and an ACP adapter drops its id),
exactly as both real adapters do synchronously.

**The executor contract** (ledger HK-400):

1. Effects run in order, each before the next, and before the next call into
   the same object.
2. A harness command that makes an adapter report an event at once (a fake
   in the tests, an ACP agent whose launch throws) re-enters the session with
   a fresh context from inside `execute`; that call's effects run before the
   rest of the outer list.
3. `sendToHarness` is checked again when it runs: if the adapter is stopped
   by then (its start failed at once), AppState calls `sendRefused(context:)`
   instead, which gives the same "No Claude session is running…" entry and
   error buzz as before.
4. The Claude adapter publishes its state at each point `ClaudeService`
   assigned its `@Published` fields, before the event that follows, so the
   session reads the same harness state while handling that event as it did
   before; `ClaudeService` assigns only the fields that changed. Parsed stdout
   events are fed one per call, in order; the core drops a retired launch's.
5. On an exit `ClaudeService` drains the launch's last events, releases the
   process, stdin and channel if they are still that launch's, and only then
   reports `terminated`: a resume retry started from the `ended` it emits
   installs a new process that must not be cleared afterwards.
6. `deferEffortRestart` becomes a fresh main-actor `Task` that calls
   `deferredEffortRestart(context:)` (HK-082);
   `scheduleRemoteTurnCheck(after:)` goes through the injected clock and calls
   `remoteTurnCheck(context:)`.
7. The derived-update pass calls `syncSettings(context:)`, which syncs the
   control mode and then the harness selection, each once per real change.

Hooks reach the session as `hookEvent(context:hook:)`; harness events as
`harnessEvent(context:from:event:)`, where `from` is the adapter that
reported it (the selected kind when it is the active harness). An event from
an adapter that is not the selected harness is dropped without even a status
update (HK-124).

## D. What moved and what stayed

Moved into `powerup-core`, unchanged in behaviour (every message byte for
byte):

- from `ClaudeService`: the launch generation, the queue of lines sent
  before the spawn (HK-269), the in-flight control requests and their acks,
  the assistant de-dupe, the init/turn state machine, the cost total, the
  "not found", "couldn't start", "can't send", "exited unexpectedly" and
  "couldn't reach" messages, the stdin lines and the argv;
- from `AppState`: the resume retry and expected exits, the effort restart,
  the destructive confirmation and the pending request, the model and
  permission cycles with rollback, `ultracode`, the harness and control-mode
  switches, project adoption, switching and cycling with the recents, the
  remote read-back (turn table, registry, focus, folder filter and label),
  and every transcript entry, announcement and haptic of those rules;
- the status derivation, the working input, the remote-turn helpers and
  expiry, the model chip, the destructive-action classifier and its
  patterns, the cycles and the effort and ACP agent display names.

Kept as thin Swift wrappers, so views and tests are unchanged:
`ClaudeService.events(fromLine:)`, `HarnessEvent.from(_:)`,
`DestructiveActionClassifier.isDestructive` and `.patterns`,
`AppConfig.defaultModelCycle`, `effortCycle`, `permissionModeCycle`,
`effortDisplayName` and `acpAgentDisplayName`, and AppState's
`derivedStatus`, `derivedIsWorking`, `liveRemoteTurns`,
`remoteTurnIsActive`, `remoteTurnExpiry`, `modelChipLabel` and
`remoteFocusLabel`. `ClaudeEvent` stays as the parse-level conversion type.

Stayed in Swift: the process, the pipes, the binary lookup (override, login
shell, install paths) and the child environment, SIGPIPE, the stderr ring
and its tail, the event FIFO and the thread hop, the kill timer, what counts
as a clean exit (code 0 and reason `.exit`); in AppState, capture, the
prompt box, speech and summaries, audio devices, the listener and protocol,
keyboard, light, haptics hardware and the transcript store; and two
one-line readings of the settings, `isRemoteMode` and the adapter selection,
pinned to the core's reading by
`AppStateSeamTests.testRuntimeNormalizationAgreesWithTheCore`.

Removed: `ClaudeService.onEvent`, the wire-level callback nothing read;
consumers use `onHarnessEvent`. Changed on the wire, recorded and harmless
(the CLI parses JSON and takes any unique id, v1.1 A): control request ids
are `"<UUID>-<n>"` per `ClaudeService` instead of one UUID per request
(HK-396), and stdin lines have a fixed key order (HK-395).

## E. Recorded rules

- The stream-json line is read exactly as `JSONSerialization` reads it:
  first of two equal keys wins, one leading BOM, one trailing comma, the
  512-container depth rule, overflow rejects the line and underflow reads
  as 0, one U+FEFF at the start of any string is dropped, and a stray 0xA9
  byte inside a string reads as U+FFFD where every other invalid byte
  rejects the line (HK-393); fields are read through Swift's NSNumber
  bridging (HK-394).
- Text rules copy Swift's `String`: trimming is Foundation's
  `whitespacesAndNewlines`, which is Unicode whitespace plus U+200B ZERO
  WIDTH SPACE; counts and cuts are extended grapheme clusters
  (`unicode-segmentation` pinned to match macOS's rules), and `condense`
  keeps a line break that a combining mark extends (HK-062, HK-063).
- The destructive classifier matches its patterns as whole Characters, as
  Swift's `String.contains` did: a combining mark right after a pattern
  hides it (HK-096).
- Strings are compared by scalar value in the core where Swift compares
  canonical equivalence; every compared value is an ASCII id, alias or
  mode, a standardized path, or a folder name that only orders the focus
  cycle (HK-397).
- The platform places paths (standardize, resolve symlinks) and lists the
  recents that exist; the core applies the folder rules (HK-398).
- Request ids are `<prefix>-<n>` from 1 per adapter (HK-396); stdin key
  order is fixed and `/` is written `\/` (HK-395).
- Session scenarios gained the `lastAssistantReply` expectation key (the
  reply Replay speaks, or null), and both runners — `SessionScenarioTests`
  through AppState and `rust/powerup-core/tests/session.rs` on the machine —
  play every scenario.
- `Tests/PowerUpTests/ClaudeFakeCLITests.swift` drives AppState and a real
  `ClaudeService` against a `/bin/sh` stand-in for `claude` that the test
  writes and points `claudePath` at (the override wins before any
  login-shell lookup, so no real claude can run): a turn through the real
  pipe, a live model change in the nested envelope, and an effort restart
  that resumes the same session id.

# v2.13 addendum — the ACP adapter state machine moves into the Rust core (stage 2.4)

Recorded 2026-10-29 for spec #99 (tickets #153–#155, ADR 0012, plan stage 2
step 4). The ACP protocol itself (v2.0, v2.2 E) is unchanged: its
verified-live facts stay ground truth, and they now live in the doc comments
of `harness::acp` (HK-126). v2.12 B (objects, no callbacks) and its failure
policy apply as written.

The core gains `harness::acp`: the adapter's JSON-RPC rules
(`acp::adapter::AcpAdapter`), the lines it writes (`rpc`), the update and
tool-detail rules (`update`), the permission choice (`permission`), the
agent presets (`agents`) and the environment scrub list (`environment`). The
slice 2.3 JSON reader moved from `harness::claude::json` to `harness::json`,
shared by both harnesses, and gained a writer. Sections A and B describe the
bridge surface; C the effect executor; D what moved; E the recorded rules.

## A. Bridge surface

Generated by uniffi into module `PowerUpCore` from
`rust/powerup-core-ffi/src/acp.rs`, with v2.12's conventions (a `Core`
prefix, uniffi's spelling, every call `throws CoreBridgeError`).
`CoreHarnessConfiguration`, `CoreHarnessEvent` and `CoreHarnessState` are
v2.12's.

| Generated Swift | Shape |
| --- | --- |
| `struct CoreAcpSnapshot` | `state: CoreHarnessState, sessionId: String?, modelName: String?, totalTokens: Int64` |
| `enum CoreAcpEffect` | `publish(snapshot:)`, `spawn(generation: UInt64, executable:, arguments: [String], projectDir:)`, `writeStdin(line: Data)`, `closeStdin`, `terminateAfterGrace(seconds: Double)`, `armStartWatchdog(generation: UInt64, seconds: Double)`, `emit(event: CoreHarnessEvent)` |
| `class CoreAcpAdapter` | `init() throws`; `generation() -> UInt64`; `snapshot() -> CoreAcpSnapshot`; `start(configuration:)`, `spawned(generation:)`, `spawnFailed(generation:executable:description:)`, `send(text:)`, `interrupt()`, `setModel(model:)`, `setPermissionMode(mode:)`, `respondToPermission(id:allow:)`, `stop()`, `stdoutLine(generation:line: Data)` (one raw line, newline removed), `terminated(generation:exitCode: Int32, stderrTail:)`, `startWatchdogFired(generation:)`, each `-> [CoreAcpEffect]` |
| `struct CoreAcpPermissionOption` | `optionId: String, kind: String` |
| `enum CoreAcpProgram` | `opencode`, `npx`, `command(executable:)` |
| `struct CoreAcpAgentLaunch` | `program: CoreAcpProgram, arguments: [String]` |
| `struct CoreAcpEnvironmentScrub` | `names: [String], prefixes: [String]` |

Functions: `acpPermissionChoice(options:allow:) -> String?` (nil: answer
cancelled), `acpAgentLaunch(agent:customCommand:) -> CoreAcpAgentLaunch?`
(the preset before the install-path lookup; nil for an unknown agent or an
empty custom command), `acpEnvironmentScrub() -> CoreAcpEnvironmentScrub`.

`Sources/PowerUp/CoreBridgeACP.swift` extends `enum CoreBridge` (with the
other `CoreBridge*.swift` files, the only app files that import
`PowerUpCore`) and speaks the app's types:

```swift
struct ACPSnapshot: Equatable { var state: HarnessState; var sessionID: String?; var modelName: String?; var totalTokens: Int
    static let stopped }
enum ACPEffect: Equatable {
    case publish(ACPSnapshot)
    case spawn(generation: UInt64, executable: String, arguments: [String], projectDir: String)
    case writeStdin(Data), closeStdin, terminateAfterGrace(seconds: TimeInterval)
    case armStartWatchdog(generation: UInt64, seconds: TimeInterval)
    case emit(HarnessEvent)
}
final class ACPStateMachine { init(); var generation: UInt64; var snapshot: ACPSnapshot
    /* one method per core method: start(_:), spawned(generation:), spawnFailed(generation:executable:description:),
       send(_:), interrupt(), setModel(_:), setPermissionMode(_:), respondToPermission(id:allow:), stop(),
       stdoutLine(generation:line:), terminated(generation:exitCode:stderrTail:), startWatchdogFired(generation:),
       each -> [ACPEffect] */ }
static func acpPermissionChoice(options: [(id: String, kind: String)], allow: Bool) -> String?
enum ACPAgentProgram: Equatable { case opencode, npx, command(String) }
struct ACPAgentLaunch: Equatable { let program: ACPAgentProgram; let arguments: [String] }
static func acpAgentLaunch(agent: String, customCommand: String) -> ACPAgentLaunch?
struct ACPEnvironmentScrub: Equatable { let names: [String]; let prefixes: [String]; func scrubs(_ key: String) -> Bool }
static var acpEnvironmentScrub: ACPEnvironmentScrub
```

The state machine wrapper is never named `ACPAdapter`: inside `extension
CoreBridge` that name would shadow the app's class. `totalTokens` converts
with `Int(clamping:)`.

**Failure policy** (ledger HK-409), as v2.12 A: a failed constructor or call
gives no effects, the snapshot reads stopped and the generation 0; a failed
permission choice answers the request cancelled, never a grant; a failed
agent launch gives no command, so the start reports "No ACP agent command is
configured"; a failed scrub list scrubs nothing (logged), and the Claude
bridge then refuses with its own visible nested-session error.

## B. Objects

One `CoreAcpAdapter` per `ACPAdapter`, alive across launches: the launch
generation and the JSON-RPC ids live inside, and the ids are never reset by
a start (HK-401). It is called on the main actor only. Each launch's
`LineQueue` splits stdout with its own `CoreLineBuffer` (v2.12 B) on the
pipe reader thread. Nothing calls back.

## C. The effects and the executor

The adapter's effects, in the glossary's words: *publish* the adapter's
state; *spawn* the agent in the project folder with the platform's agent
environment, then report `spawned` or `spawnFailed`; *write a line* on stdin
or *close stdin*; *arm the kill* (terminate the process current now if it
still runs after 2 s, HK-154); *arm the start watchdog* (a one-shot 30 s
timer that asks the core, HK-134); *emit* a `HarnessEvent` to the session.

**Publish rule** (HK-405): the adapter keeps the snapshot it last published
and pushes `publish` before any other effect whenever the state changed, and
at the end of every call. That reproduces what an observer of the old
`@Published` fields saw at each moment: the reply and `turnCompleted` are
emitted while the adapter still reads working, and ready is published after
them; a start publishes starting before its spawn, so a spawn failure
carried out inside it publishes stopped last.

**The executor contract** (ledger HK-410):

1. Effects run in order, each before the next and before the next call.
2. A spawn runs at once; `spawned` or `spawnFailed` is called before
   anything else, and its effects run nested, before the rest of the list.
3. A write goes to the stdin handle current when it runs, on the serial
   stdin queue, and is skipped once stdin is closed; the kill grace captures
   the process current when it is armed; the watchdog is a main-actor timer
   that calls `startWatchdogFired(generation:)` and is never cancelled (the
   core decides).
4. `publish` assigns only the fields that changed.
5. Stdout lines are fed one per call, in order (HK-408).
6. On an exit `ACPAdapter` releases the process, stdin and line queue if
   they are still that process's, then reports `terminated`. The stdout
   tail is not flushed and the late pipe is not drained, as before.

The core has finished its whole call when Swift runs an `emit`; the old
adapter emitted mid-function. That is unobservable, because no ACP event
makes the session call the ACP adapter synchronously (the resume retry and
the effort restart are Claude-only, and the restart is deferred anyway).

## D. What moved and what stayed

Moved into `powerup-core`, unchanged in behaviour (every message the same
JSON as before; only the key order, which JSONSerialization never kept
stable, is now fixed, see E and HK-404): the handshake, the JSON-RPC ids and pending requests, the dispatch of
every agent line, session updates and tool details, the permission requests,
their answers and their cancels, the prompt queue and the reply buffer, the
usage total, stop and exit bookkeeping, the watchdog's decision, the lines
written; and, as data, the agent presets (the bridge package names and their
last verification, HK-129, HK-130) and the environment scrub list (HK-127).

Kept as thin Swift wrappers, so call sites are unchanged:
`ACPAdapter.agentCommand(for:isExecutable:)`,
`agentEnvironment(from:)` and `permissionChoice(options:allow:)`.

Stayed in Swift: the process and its pipes, the stdin queue, the timers, the
stderr ring and its 500-character tail (HK-287), the install-path probe for
opencode and npx (HK-286), the PATH augmentation (HK-128, re-owned: it is
environment construction on macOS paths), and applying the scrub list to
`ProcessInfo`. `ACPAdapter` still never ignores SIGPIPE (only
`ClaudeService.spawn` does), so a run that only ever spawns an ACP agent
keeps SIGPIPE's default action: a pre-existing gap, left unchanged here
because this slice changes no behaviour. Ledger row HK-411 tracks it until
a maintainer files and fixes it as its own issue.

## E. Recorded rules

- Agent lines are read with the shared Foundation-matching reader; fields
  are read as Swift cast them (HK-403): ids with `as? Int` (1.0 and `true`
  match 1; `"1"` and 1.5 never do), token counts with NSNumber's `intValue`
  (truncated, saturated, a bool as 0 or 1, a string as 0), arrays of objects
  all or nothing (`options`, `locations`), and `error`, `result`, `params`,
  `usage` only as objects, so a string `error` reads as success. Numbers are
  kept as `f64`, so integers past 2^53 can differ (no agent sends them).
- Dispatch (HK-402): an int id that is pending is that request's response
  even when the message also has a method (an agent request reusing our id
  is swallowed); any other message with a method and an `id` key, `null`
  included, is an agent request, so `session/update` sent with an id gets
  -32601; an update's `sessionId` is never compared.
- Lines written (HK-404): compact JSON with a fixed key order (`jsonrpc`,
  `id`, `method`, `params`; or `result`/`error`), Swift's escaping (`/` as
  `\/`), one line plus `\n`; JSONSerialization wrote hash order, so the
  fixtures compare them as JSON. An agent's id is echoed as read, written
  without recursion.
- The start watchdog fires only while the launch is still starting, so a
  prompt queued during start keeps it from firing (kept, HK-406).
- Pending permission requests are cancelled in arrival order; Swift used
  dictionary order (HK-407).
- The launch-generation and stopped guard runs per stdout line, not per
  drained batch, and a retired exit releases the process references only
  when they still point at that process (HK-408).
- The scripted agent is the shared fixture
  `Tests/Fixtures/harness/acp-mock-agent.py`. `ACPAdapterIntegrationTests`
  runs it through the app, and `rust/powerup-core/tests/acp_mock_agent.rs`
  runs it through the core (Python 3 required; skipped locally without it,
  required on CI). Both check its record against the "mock agent:" cases of
  `acp-adapter.json`. Only the Swift test runs the real executor: the Rust
  one carries out spawn, write, close and emit in order, but only notes
  publish, the kill grace and the watchdog, and fails on a write after
  stdin closed rather than skipping it (HK-410).

## F. Left for the maintainer

Ticket #155's manual check, that opencode and Codex sessions behave as
before, needs a run with the real agents. Agents working on the slice may
not start real ACP agents or npx bridges (CLAUDE.md), so it is not recorded
here and stays open until a maintainer runs it before #155 closes.

# v2.14 addendum — config, transcript, hooks merge, text safety and speech text move into the Rust core (stage 2.5)

Recorded 2026-10-29 for spec #100 (tickets #156–#160, ADR 0011, ADR 0012,
plan stage 2 step 5), built up ticket by ticket; this text covers #156,
the configuration schema, #157, the transcript's JSON Lines, #158, the
hooks merge, #159, the remote text safety rules, and #160, the speech
text rules, the stage's last ticket: with it stage 2.5 is complete, and
no ledger row the slice owns is pending. It supersedes
v2.11 C's "`Action`'s synthesized
`Encodable` and the config writer (until slice 2.5)": the core reads and
writes config.json since this slice and `Action` is a plain value. The
on-disk format, every default and every tolerance rule of the config
sections of this document (v1.4, v2.4 B and C, v2.5, v2.7 B) are unchanged.
v2.12 B (plain functions and objects, no callbacks) applies as written.
For #157 it supersedes v1.6's "`TranscriptEntry` gains `Codable`" and
`fileURL(forProjectDir:) -> URL`: the core writes and reads each line and
names each project's file, `TranscriptEntry` is a plain value with an
`init(id:kind:text:date:)` for an entry read back, and `fileURL` returns
`URL?`. The transcripts folder, the file names and the line format of v1.6
are unchanged, except that a line's members now come in a fixed order
(HK-416).
For #158 the `HookInstaller` API of v1.4, v1.10 and v2.2 keeps its shape:
`hookCommand()` and `hookScriptBody(port:token:)` now return an optional
(nil only when the core fails), `hookEvents` is a computed property, and
`settingsBytes(fromCoreJSON:path:)` is new. What install and uninstall do
to `~/.claude/settings.json`, the hook script and the install state are
unchanged, apart from the recorded differences of D (HK-417).
For #159 the `RemoteControlService` API of v1.4 keeps its shape
(`refreshStatus`, `sendText`, `sendKey`, `cmuxWorkspaces` of
`CmuxWorkspace` rows with `ref`, `title` and `selected`; `CommandResult`
stays the process runner's type). Its private text helpers
(`flattenLineBreaks(in:)`, `escapeSafeSegments(_:)`, `parseWorkspaces(_:)`,
`stripStatusGlyph(_:)`, `condense(_:maxChars:)`,
`failureMessage(action:result:)`) are deleted for the `CoreBridge`
wrappers of B, and the injector's own rules become internal so they can be
tested: `Route`, `route(for:)`, `trimmedOrNil(_:)`,
`autoTargetWorkspace(in:)` and `targetArguments(workspace:surface:)`. What
reaches the target and every message are unchanged, apart from what a
failed core call does (B).
For #160 it supersedes the TTSService contract's `speechText(fromMarkdown:
maxChars:)` with its rules, v1.2 A's `dominantLanguageCode(of:)`, its
localized phrases and step 1 of its resolution order, v1.12's
`SummaryService.prompt(for:)` with its rejection rule, the
`summaryMinimumReplyLength` and `TTSService.spokenReply` of v1.12's
AppState behavior, and the `TTSService.speechText` call in the first
behavior spec's `turnCompleted`: these and
`TTSService.spokenReply(fromMarkdown:maxChars:)` are deleted for the
`CoreBridge` wrappers of B, as are the internal
`TTSService.voiceLanguage(for:language:)`,
`SummaryService.usableSummary(_:for:)` and
`AppState.wantsSummary(of:speakSummaries:)` that the ticket's first commit
extracted so the tables could play them. `TTSService.speak(_:voiceID:rate:
language:)`, `rankedVoices`, `isExcludedVoiceIdentifier`,
`availableVoices` and SummaryService's `arguments(model:)`, `summarize`
and `cancel` keep their shape. What a reply sounds like, when it is
summarized and which voice reads it are unchanged, apart from the accepted
language differences of D (HK-420 to HK-424) and what a failed core call
does (B).

The core gains `config` (`AppConfig`, `load_config`, `encode_config`,
`seed_project_bookkeeping`, the defaults and the fixed vocabularies) and,
beside the slice 2.3 reader that moved from `harness::json` to a neutral
`json` module, `json::decoder` (config.json read as Swift's `JSONDecoder`
reads it) and `json::encoder` (written as `JSONEncoder` writes it).
With #157 it gains `transcript` (`TranscriptEntry`, `TranscriptKind`,
which the session machine now shares, `entry_line`, `decode_line`,
`load_tail`, `file_name` and the two limits), a private `sha256`, the text
helpers `lowercase_scalars` and `is_letter_or_number`, and the compact
writer `json::encoder::to_swift_compact`.
With #158 it gains `hooks` (`HOOK_EVENTS`, `hook_command`,
`hook_script_body`, `is_installed`, `install_state`, `install_edit`,
`uninstall_edit`, `InstallState`, `SettingsEdit`, `SettingsRefusal`); the
slice 2.3 reader's numbers keep their literal beside their value
(`json::JsonNumber`), `json::write_verbatim` writes a value back for
Foundation to read, and `text::replace_unless_extended` is Foundation's
`replacingOccurrences` for one character.
With #159 it gains `text_safety` (`flatten_line_breaks`,
`escape_safe_segments` with `MAX_SEND_SPLITS`, `parse_workspaces` into
`CmuxWorkspace` rows, `strip_status_glyph`, `condense` with an `i64` limit,
and `failure_message` for a `CommandResult`), and `text` gains
`trim_whitespaces` (Foundation's narrower `whitespaces` set),
`ends_with_clusters` (`hasSuffix`) and `split_once_on_space` (`split`
with one split). The slice 2.3 `text::condense` is the cut for limits of 0
or more.
With #160 it gains `speech` (`spoken_reply` with its `SpokenReply`,
`speech_text`, `dominant_language` and `cjk_script_language` with their
gates `MINIMUM_LETTERS`, `CJK_SHARE` and `CONFIDENCE_GATE`,
`voice_language`, the phrases and `SENTENCE_ENDERS`, and the summary rules
`wants_summary`, `usable_summary`, `summary_prompt` and
`SUMMARY_MINIMUM_REPLY_LENGTH`), whose private `markdown` module holds one
hand-written pass per NSRegularExpression the app ran, and the core's
first dependency beyond serde and unicode-segmentation: whatlang
`=0.18.0`, a pure-Rust trigram language detector (MIT, with no threads
and no I/O; its dependencies are permissive, `rust/deny.toml` admits
them, and `rust/THIRD-PARTY-LICENSES.md` lists them).

## A. Bridge surface

Generated by uniffi into module `PowerUpCore` from
`rust/powerup-core-ffi/src/config.rs`, with v2.12's conventions (a `Core`
prefix, uniffi's spelling, every call `throws CoreBridgeError`).

| Generated Swift | Shape |
| --- | --- |
| `struct CoreAppConfig` | the 35 settings of `AppConfig`, same order, uniffi's spelling (`lastSessionId`, `ttsVoiceId`, `localeId`, `audioInputUid`, `audioOutputUid`, `controllerDeviceId`, `remoteAppBundleId`, `sessionIdsByProject`); `ttsRate: Float`, `maxSpokenChars: Int64`, `listenerPort: Int64`, `deviceMappings: [String: [String: CoreAction]]` |
| `enum CoreConfigLoad` | `loaded(config: CoreAppConfig, backupBeforeSave: Bool)`, `corrupt` |
| `struct CoreConfigVocabulary` | `harnessKinds, acpAgents, controlModes, remoteTargetKinds: [String]`, in Settings order |

Functions: `defaultConfig() -> CoreAppConfig`, `loadConfig(bytes: Data) ->
CoreConfigLoad`, `encodeConfig(config:) -> Data` (UTF-8, no trailing
newline), `seedProjectBookkeeping(config:) -> CoreAppConfig`,
`configVocabulary() -> CoreConfigVocabulary`. The mapping-only export of
slice 2.2, `loadDeviceMappings(configJson:)` and `CoreMappingLoad`, is
deleted: the mapping subtree now crosses inside the whole config
(`mapping::load_device_mappings` stays in the core for
`mapping/config-load.json`).

From `rust/powerup-core-ffi/src/transcript.rs` (#157):

| Generated Swift | Shape |
| --- | --- |
| `enum CoreTranscriptKind` | `user`, `assistant`, `tool`, `system`, `error` (moved here from the session bridge, which uses the same type) |
| `struct CoreTranscriptEntry` | `id: String` (a `uuidString`), `kind: CoreTranscriptKind`, `text: String`, `dateSeconds: Double` (seconds since 1970) |
| `struct CoreTranscriptLoad` | `entries: [CoreTranscriptEntry]` (oldest first), `rewrite: Data?` (the file's new bytes when it outgrew the limit) |
| `struct CoreTranscriptLimits` | `maxStoredEntries: UInt32` (2000), `defaultRestoreCount: UInt32` (200) |

Functions: `transcriptLine(entry:) -> Data` (one line, LF included),
`transcriptLoad(bytes: Data, maxEntries: UInt32) -> CoreTranscriptLoad`,
`transcriptFileName(standardizedPath:) -> String` (`<slug>-<hash>.jsonl`)
and `transcriptLimits() -> CoreTranscriptLimits`.

From `rust/powerup-core-ffi/src/hooks.rs` (#158):

| Generated Swift | Shape |
| --- | --- |
| `enum CoreHookInstallState` | `notInstalled`, `installed`, `outOfDate` |
| `enum CoreSettingsRefusal` | `invalidJson`, `hooksNotAnObject`, `eventNotAnArray(event: String)` |
| `enum CoreSettingsEdit` | `unchanged`, `write(json: Data)` (the whole new file as compact UTF-8 JSON, every number spelled as the file spelled it), `refused(refusal: CoreSettingsRefusal)` |

Functions: `hookEvents() -> [String]`, `hookCommand(scriptPath:) -> String`,
`hookScriptBody(port: Int64, token:) -> String`,
`hooksInstalled(settings: Data?, scriptPath:) -> Bool`,
`hookInstallState(settings: Data?, scriptPath:, scriptOnDisk: Data?,
port: Int64, token:) -> CoreHookInstallState`,
`hookInstallEdit(settings: Data?, scriptPath:) -> CoreSettingsEdit` and
`hookUninstallEdit(settings: Data?, scriptPath:) -> CoreSettingsEdit`. A nil
`settings` or `scriptOnDisk` means there is no such file.

From `rust/powerup-core-ffi/src/text_safety.rs` (#159):

| Generated Swift | Shape |
| --- | --- |
| `struct CoreCmuxWorkspace` | `reference: String` (the `ref`: `workspace:N` or a bare UUID; `ref` is a Rust keyword), `title: String` (without its activity glyph), `selected: Bool` |
| `struct CoreCommandResult` | `status: Int64`, `standardOutput: String`, `standardError: String`, `timedOut: Bool`, `spawnFailed: Bool` |

Functions: `flattenLineBreaks(text:) -> String`,
`escapeSafeSegments(text:) -> [String]` (empty text: no segment),
`parseWorkspaces(output:) -> [CoreCmuxWorkspace]`,
`stripStatusGlyph(title:) -> String`,
`condense(text:maxChars: Int64) -> String` and
`failureMessage(action:result: CoreCommandResult) -> String`. They take and
return strings and values only: none runs cmux or posts a keystroke.

From `rust/powerup-core-ffi/src/speech.rs` (#160):

| Generated Swift | Shape |
| --- | --- |
| `struct CoreSpokenReply` | `text: String` (empty when nothing speakable is left), `language: String` (the lowercased primary subtag the phrases were chosen for, `"en"` when undecided) |

Functions: `spokenReply(markdown:maxChars: Int64) -> CoreSpokenReply`,
`speechText(markdown:maxChars: Int64) -> String`,
`dominantLanguage(text:) -> String?` (nil: undecided),
`voiceLanguage(text:language: String?) -> String`,
`wantsSummary(reply:speakSummaries: Bool) -> Bool`,
`usableSummary(summary: String?, reply:) -> String?` (a nil summary: the
summarizer gave none) and `summaryPrompt(reply:) -> String`. A `maxChars`
of 0 or less never cuts. They take and return strings and decisions only:
none picks a voice, speaks or runs the summarizer.

## B. Swift wrappers and the failure policy

`Sources/PowerUp/CoreBridgeConfig.swift` extends `enum CoreBridge` and
speaks the app's `AppConfig`, converting field by field (`Int(clamping:)`
for the two Int64s):

```swift
enum ConfigLoad: Equatable { case loaded(AppConfig, backupBeforeSave: Bool), corrupt }
struct ConfigVocabulary: Equatable { let harnessKinds, acpAgents, controlModes, remoteTargetKinds: [String] }
static func defaultConfig() -> AppConfig?
static func loadConfig(_ data: Data) -> ConfigLoad?
static func encodeConfig(_ config: AppConfig) -> Data?
static func seedProjectBookkeeping(_ config: AppConfig) -> AppConfig?
static func configVocabulary() -> ConfigVocabulary?
```

`AppConfig` keeps its stored properties, memberwise initializer, the
`mapping` view and its helpers, but is no longer `Codable`. New:
`AppConfig.decoded(from: Data) throws -> AppConfig` (the core's reading;
throws `ConfigFileError.corrupt` or `.coreUnavailable`), and
`ConfigStore.encode(_:) throws -> Data` now returns the core's bytes.
`AppConfig.defaultConfig()` and the four vocabulary lists
(`harnessKindOptions`, `acpAgentOptions`, `controlModeOptions`,
`remoteTargetKinds`) come from the core.

**Failure policy.** A bridge error is a core bug (the core never fails on
these inputs) and is logged under category `core`. A failed `defaultConfig`
or `configVocabulary` falls back to `AppConfig.coreUnavailableDefaults` and
literal lists, which `AppConfigTests.testCoreUnavailableDefaultsMatchTheCore`
pins equal to the core's. A failed `loadConfig` is never taken for a corrupt
file: ConfigStore keeps the file, copies it once to config.pre-profiles.json
and runs on the defaults. A failed `encodeConfig` throws, and `save()`
swallows it as it swallows every write failure, so nothing is written. A
failed `seedProjectBookkeeping` leaves the config as it is.

`Sources/PowerUp/CoreBridgeTranscript.swift` (#157) speaks the app's
`TranscriptEntry` (`id.uuidString` and `date.timeIntervalSince1970` one
way, `UUID(uuidString:)` and `Date(timeIntervalSince1970:)` the other):

```swift
struct TranscriptLoad: Equatable { let entries: [TranscriptEntry]; let rewrite: Data? }
static func transcriptLine(_ entry: TranscriptEntry) -> Data?
static func transcriptLoad(_ data: Data, maxEntries: Int) -> TranscriptLoad?
static func transcriptFileName(standardizedPath: String) -> String?
static var transcriptLimits: (maxStored: Int, restoreCount: Int)
```

Failure policy for the transcript: persistence is best-effort (HK-178), so
a failed call persists or restores nothing and never fails the session. No
line means nothing is appended; no file name means `fileURL` is nil and the
store neither appends nor loads; no load means an empty restore, and the
file is never rewritten. A failed `transcriptLimits` falls back to 2000 and
200, which `TranscriptStoreTests.testLimitsAreTheCores` pins equal to the
core's.

`Sources/PowerUp/CoreBridgeHooks.swift` (#158) speaks
`HookInstaller.InstallState` and two value types of its own:

```swift
enum SettingsRefusal: Equatable { case invalidJSON, hooksNotAnObject, eventNotAnArray(String) }
enum SettingsEdit: Equatable { case unchanged, write(Data), refused(SettingsRefusal) }
static var hookEvents: [String]
static func hookCommand(scriptPath: String) -> String?
static func hookScriptBody(port: Int, token: String) -> String?
static func hooksInstalled(settings: Data?, scriptPath: String) -> Bool
static func hookInstallState(settings: Data?, scriptPath: String, scriptOnDisk: Data?,
                             port: Int, token: String) -> HookInstaller.InstallState
static func hookInstallEdit(settings: Data?, scriptPath: String) -> SettingsEdit?
static func hookUninstallEdit(settings: Data?, scriptPath: String) -> SettingsEdit?
```

`HookInstaller` passes `hookScriptURL().path` as the script path, reads the
settings (nil for no file; a read failure still throws `fileError`) and
the script, and carries out the edit: `.unchanged` writes nothing and takes
no backup, `.write` goes through `settingsBytes(fromCoreJSON:path:)` (the
formatting half of the writer, no I/O) and the numbered backup and atomic
write, and each refusal throws the error text the installer always threw.

Failure policy for the hooks: a failed call never touches a file the
person owns. No edit throws "couldn't rewrite … safely" and leaves
settings.json alone; no script body throws `fileError` before anything is
written, so an empty script is never installed; a failed state reads as
`notInstalled` and a failed `hooksInstalled` as false, so Settings offers
an install; a failed `hookEvents` is empty and a failed `hookCommand` nil
(only tests read them: the app registers through the edits).

`Sources/PowerUp/CoreBridgeTextSafety.swift` (#159) speaks the service's
`CmuxWorkspace` and `RemoteControlService.CommandResult` (`Int64(status)`
one way, `reference` as `ref` the other):

```swift
static func flattenLineBreaks(_ text: String) -> String?
static func escapeSafeSegments(_ text: String) -> [String]?
static func parseWorkspaces(_ output: String) -> [CmuxWorkspace]?
static func stripStatusGlyph(_ title: String) -> String?
static func condense(_ text: String, maxChars: Int) -> String?
static func failureMessage(action: String, result: RemoteControlService.CommandResult) -> String
```

`sendText` flattens the text before any route, the injector seam included;
the cmux route asks for the segments before it resolves the target and
sends one `cmux send -- <segment>` per segment; `refreshStatus` and the
send-time target choice read `list-workspaces` through `parseWorkspaces`;
every failed cmux command is reported through `failureMessage`.
`parseWorkspaces` already strips the glyph and `failureMessage` already
condenses, so only the tests call those two wrappers directly.
`flattenLineBreaks` runs on the main actor, inside `sendText`; the other
calls run on the service's background queue; `CoreBridge` is safe from
either.

Failure policy for remote text: a failed call never lets raw text through,
since a line break typed into a terminal is Enter. No flattened text or no
segments means nothing is typed or sent, on any route, and the completion
reads "PowerUp couldn't make that text safe to type, so it didn't send
anything. Try again." (`textNotPreparedMessage`). A workspace list the
core could not read is never taken for "no workspaces" and nothing in it
is chosen as the target: at send time the send stops with "PowerUp
couldn't read cmux's workspace list — pick a workspace in Settings →
Remote.", and the status refresh shows no workspaces. A failed
`failureMessage` reads "<action> failed.", so the failure is still
reported; a failed `stripStatusGlyph` or `condense` is nil.

`Sources/PowerUp/CoreBridgeSpeech.swift` (#160) speaks the services' own
shapes (a tuple for the spoken reply, `Int` limits):

```swift
static func spokenReply(fromMarkdown markdown: String, maxChars: Int) -> (text: String, language: String)?
static func speechText(fromMarkdown markdown: String, maxChars: Int) -> String?
static func dominantLanguage(of text: String) -> String?
static func voiceLanguage(for text: String, language: String?) -> String
static func wantsSummary(of reply: String, speakSummaries: Bool) -> Bool
static func usableSummary(_ summary: String?, for reply: String) -> String?
static func summaryPrompt(for reply: String) -> String?
```

AppState's `speakReply` asks `wantsSummary` whether a completed reply goes
to the summarizer, and speaks the full reply (`speakFullReply`), the
summary (with a `maxChars` of 0) and Replay (`speakLastReply`) through
`spokenReply`, handing its language to `TTSService.speak`; announcements
keep passing `"en"`. `TTSService.resolveVoice` takes its language from
`voiceLanguage` and keeps everything after it. SummaryService's detached
task writes the stdin through `summaryPrompt`, runs the process and checks
the answer with `usableSummary`. `speechText` and `dominantLanguage` serve
the tests and the fixture runner. The reply rules run on the main actor,
the prompt and the check on the detached task; `CoreBridge` is safe from
either.

Failure policy for speech: a failed call never speaks raw markdown or
fenced code. A spoken reply the core could not make, for the full reply or
Replay, speaks "Sorry, I couldn't read that reply aloud." in English
(`AppState.unreadableReplyPhrase`, private) instead; a reply that is only
markup still speaks nothing, and its Replay still buzzes. A summary whose
spoken text fails falls back to the full reply, like an empty one; a
failed `summaryPrompt` runs no process and the completion comes with nil;
a failed `usableSummary` is nil and a failed `wantsSummary` false, so the
full reply is spoken (with no model call for the latter); a failed
`dominantLanguage` reads as undecided (English); a failed `voiceLanguage`
is the caller's language, else `"en"`. No test can make the core fail, so
these paths are pinned by their doc comments.

## C. What moved and what stayed

Moved into `powerup-core`, unchanged in behaviour: the schema and its
defaults (the 0.5 speech rate as a literal, so the core never links
AVFoundation; HK-159), every key's tolerance (HK-155 to HK-158, HK-018), the
corrupt-file decision (HK-160), the pre-profiles backup decision (HK-014,
now returned with the whole config), the exact save bytes (HK-162) and the
pre-multi-project migration (HK-164), which AppState applies once at
launch and writes only when it changes something.

Stayed in Swift: the file, its path and the `ConfigStore(fileURL:)` test
seam (HK-163), reading the bytes, the 0.5 s debounce and the atomic write
with failures swallowed (HK-161), moving a corrupt file to
config.json.bak, the once-only copy to config.pre-profiles.json, and
minting the listener token (HK-168). `JSONValue` moved to the test target,
its only user.

Transcript (#157). Moved, unchanged in behaviour: how a line is written and
read (HK-175), how a file loads, compacts past 2000 entries and returns the
newest 200 (HK-176), and the file name: slug and SHA-256 prefix (HK-174).
Stayed in Swift: the transcripts folder and the support-directory seam
(HK-179), standardizing the project path with `URL.standardizedFileURL`
(which on macOS also decomposes accents, voiced kana and Hangul; the core
hashes the bytes it is given), the append handle, the atomic rewrite with
the core's bytes, swallowing every I/O failure (HK-178), and AppState's
800-entry window with the restore marker that is never persisted (HK-177).

Hooks (#158). Moved, unchanged in behaviour: the five events and their
order (HK-180), the quoted command (HK-181), the legacy upgrade
(HK-182), what counts as ours (HK-183), the script's text, the token's
escaping and the port clamp (HK-184 to HK-186), the install state
(HK-187 to HK-189), the merge with its skip-write, pass-through and
refusals (HK-190 to HK-192) and the uninstall with its pruning (HK-195).
Stayed in Swift: the settings path and the support directory with their
test seams (HK-196), reading both files, the numbered backup (HK-193),
the settings writer (HK-194, HK-417: Foundation's `JSONSerialization`
with sorted keys, whose collation and number spelling the core would need
ICU to reproduce; it formats the core's JSON, whose number literals are
the person's, so the bytes are the ones it wrote before), and the atomic
0755 script write (HK-197). Ticket #158 asks that an install missing an
event report not installed; today such an install reads `outOfDate`,
which is what Settings turns into its reinstall prompt, and behaviour must
not change, so the core keeps `outOfDate` and the tables prove that a
missing event never reads `installed` (without Stop, `notInstalled`;
HK-188).

Remote text (#159). Moved, unchanged in behaviour: flattening every line
break before any delivery route (HK-198), the escape-safe `cmux send`
segments with their cap of 12 splits, which always join to the flattened
text (HK-199 to HK-201, HK-419), parsing `cmux list-workspaces` with its
selection markers and ref check (HK-202, HK-203; the legacy-notice guard of
HK-299 moved with the parser), stripping a title's activity glyph
(HK-205), condensing cmux output (HK-206, the cmux part of HK-173) and the
failure message (HK-207). Stayed in Swift, the injector: the route for a
target kind with its cmux fallback and the bundle id (HK-208, HK-209), the
target choice and its `--workspace`/`--surface` arguments, which run
`list-workspaces` (HK-204), running cmux (the `--` separator, the pauses,
CMUX_QUIET, the socket password, binary resolution, the pipes and
deadlines; HK-296 to HK-306), the exactly-once completion and the injector
seam (HK-307, HK-308), and Accessibility typing (HK-309 to HK-314). Each
OS has its own injector (CONTEXT.md), so these stay with the platform;
HK-204, HK-208 and HK-209 had no test and `RemoteRoutingTests` now pins
them. The one change in order: the cmux route asks for the segments before
it lists the workspaces, so no `list-workspaces` runs for text that would
not be sent; segmentation being pure, a working core sends exactly as
before.

Speech (#160). Moved, unchanged in behaviour: the code placeholder before
the language decision (HK-214), the decision made once with only Chinese
getting localized phrases (HK-211), the fixed stripping order (HK-215),
the cut at the last sentence ender with its localized note (HK-216, the
speech part of HK-173), the language decision's gates (HK-212, HK-213,
with whatlang in place of NLLanguageRecognizer, CJK decided by its script
alone and the accepted differences of D), the caller's language winning
over detection (HK-210), and the summary rules: the 350-Character
threshold, the prompt and which answer is spoken (HK-169, HK-170,
HK-172). Stayed in Swift: voice
resolution and ranking with the explicit voice, the exclusions and the
fallback chain (HK-336, HK-337), the simplified or traditional Chinese
region, which a recognizer constrained to the two scripts picks within the
best quality tier (HK-335: it chooses a voice, not a language, so
`TTSService` keeps it and `import NaturalLanguage`), the voice list
(HK-338), the synthesizer, the routed render and audio routing (HK-329 to
HK-334, HK-340), the recorder (HK-339), the summarizer process with its
arguments, timeout and latest-wins (HK-280 to HK-285), and in AppState the
English announcements (HK-210), the generation counter that drops a
summary arriving after its moment, the "Summary: …" entry and the
fallbacks to the full reply (HK-169, HK-171). The engines and voices are
each OS's own (ADR 0011); the text rules are shared, so every OS reads a
reply the same and routes it to the same language.

## D. Recorded rules

- config.json is read as `JSONDecoder` reads it, not as `JSONSerialization`
  (HK-412). A scan of the structure can fail the whole file (encoding,
  whitespace, nesting past 512 containers, a stray token, a non-object
  root, a root key that does not convert); a value is converted only when a
  field reads it, so a bad number or string costs that one field its
  default. A nested object's keys convert only when a field reads that
  object, so a bad key inside an unknown key's value is ignored while one
  inside `sessionIDsByProject` fails that field. Found by the differential
  below; the plan had assumed every key converted at scan time.
- Numbers convert as measured (HK-413): an Int through its double below
  2^53 (so `1e-400` reads as 0) and through Decimal from 2^53 to 2^63 (cut
  toward zero); a Float rounded once from the decimal; Foundation's
  true-zero check reads four bytes at a time, so `0.0e5` is zero but `0e5`
  fails its field. A literal of more than 38 significant digits above 2^53
  is cut where Decimal's own rounding was not measured.
- The save is `JSONEncoder` with `[.prettyPrinted, .sortedKeys]`, byte for
  byte (HK-414): keys in Unicode scalar order, `"key" : value`, empty
  containers around a blank line, `\/`, Float in Swift's shortest digits
  and layout. `config/round-trip.json` compares every case byte for byte,
  the first being a config.json the macOS app wrote.
- Canonically equivalent keys (`/é` precomposed and decomposed) are kept
  apart; Swift's dictionaries merged them (HK-415).
- Before the Swift path was deleted, a scratch differential compared it
  with the core on 40,000 generated config.json files (four seeds: wrong
  types, lazily invalid tokens, duplicates, trailing commas, BOM and
  UTF-16/32, deep mapping payloads, structural damage): saved bytes,
  corrupt or not, and the backup decision. After the nested-key fix it
  found no disagreement.
- Transcript lines (#157, HK-416, HK-175): the core writes a line's
  members as id, kind, text, date. Swift's `JSONEncoder` without
  `.sortedKeys` wrote them in a hash order that changed from launch to
  launch, so no line was ever byte-stable, and lines read by key: every
  line an older build wrote loads
  (`TranscriptStoreTests.testPersistedLinesFromBeforeTheSwapLoad`). A line reads through the same
  `json::decoder` as config.json; the id reads as `UUID(uuidString:)` reads
  it, as a C string, so an id followed by a NUL and anything reads as that
  id. A compaction writes each kept date as a `Date` holds it, through the
  2001 reference date and back (0.1 becomes 0.10000002384185791), as
  Swift's rewrite of its `Date` values did.
- The file name (HK-174) follows Swift's `String` and `URL`: lowercasing
  scalar by scalar (no final sigma), `Character.isLetter`/`isNumber` on
  the first scalar (macOS also calls 35 scalars of Apple's private-use area
  letters), each step re-reading the clusters, the cut at 40 Characters,
  and one leading U+FEFF dropped as `URL.lastPathComponent` drops it.
- Of two equally short spellings of a Float or Double, Swift's
  `description` writes the one ending in an even digit, where Rust's
  formatter rounds the tie up (HK-414). `json::encoder` breaks ties to even
  since #157, which also corrects config.json's writer of #156 for a value
  such as a `ttsRate` of 62117.3125.
- Before the Swift transcript code was deleted, a scratch differential
  compared it with the core over six seeds: every Unicode scalar as a
  folder name, 60,000 generated folder names, 60,000 generated lines,
  12,000 written entries, 360 loaded files (compactions included) and some
  700,000 dates and rates chosen to land on rounding ties. It found the
  NUL-terminated id, the dropped U+FEFF, the private-use letters and the
  float ties; after the fixes, no disagreement.
- The hooks merge (#158, HK-417): settings.json is read with the slice 2.3
  `JSONSerialization` reader, and the edit comes back as compact JSON that
  keeps every number's literal, writes only the first of two equal keys
  (an edit never uncovers a later duplicate it removed) and doubles a
  leading U+FEFF, because Foundation drops one when it reads the text
  back. Recorded differences: a UTF-16 or UTF-32 settings.json is refused
  as invalid JSON where Foundation read it (Claude Code reads UTF-8 only;
  `hooks/install.json` "a UTF-16 file is refused", synthetic); a number
  Foundation cannot read (more than 17 digits with an exponent Decimal
  cannot hold) no longer fails the whole file in the core, so such a file
  can read as installed or need no change, while any write still goes
  through Foundation, which refuses it as invalid JSON as before; and
  canonically equivalent keys spelled differently are both kept, where
  Swift's dictionary merged them.
- The command and the script are compared byte for byte (HK-418), where
  Swift compared Strings by canonical equivalence; the app's own path and
  token never tell the two apart.
- Foundation's `replacingOccurrences` skips a single quote only when a
  Grapheme_Cluster_Break=Extend scalar follows it; a spacing mark or ZWJ
  after it, or a prepended scalar before it, does not stop the match,
  though each joins the quote's Character (measured against every scalar;
  HK-181). The token is escaped per Character as Swift walked it, so a
  joined backslash, dollar or backtick stays as it is, and U+1FEF counts as
  a backtick (HK-185).
- Before the Swift installer code was deleted, a scratch differential
  compared it, copied pure, with the core and the new writer over 90,000
  generated settings files (nine seeds) for install, uninstall,
  isInstalled and the state against random ports, tokens and scripts, and
  over 60,000 random paths and tokens for the command and the script. It
  found the quote rule above, which the core first had as a cluster rule;
  after the fix only the three recorded classes remained, each counted.
- Remote text follows Swift's `String` as the macOS app used it (#159):
  flattening works on scalars, so a break that a combining mark follows is
  flattened too; everything else works on Characters, and the trims are
  Foundation's `whitespacesAndNewlines` for a list line and `whitespaces`
  after a marker or a glyph. Segmentation compares whole Characters: a
  backslash-n whose n a combining mark extends, or whose backslash a
  prepended scalar (U+0600) joins, is not split, though its bytes still
  hold backslash-n, which cmux may read as Enter (not verified live). Kept
  for parity, so every implementation agrees (HK-419).
- `cmux list-workspaces` lines are split on the LF Character only, so CRLF
  output, which cmux on macOS never prints, is one row; any text after
  `workspace:` is a ref, and a bare UUID is read as `UUID(uuidString:)`
  reads it: the canonical 8-4-4-4-12 hex form, as a C string, so a valid
  UUID that a NUL follows is accepted (measured on macOS 27.2; HK-203). The
  activity glyphs are Braille and Dingbats less the 15 Dingbats with
  Emoji_Presentation, a table measured with `Unicode.Scalar.Properties` on
  macOS 27.2 (HK-205). A negative `condense` limit always cuts, to the
  first Character and `…` (only `…` for empty text), as Swift's `Int` did;
  the app passes 160 and 200.
- Before the Swift helpers were deleted, `Tests/Fixtures/text-safety/`
  gained the 48 Swift behaviours no case pinned, each captured from the
  Swift code (196 cases in the six tables). A scratch differential then
  compared the Swift functions, copied pure, with the core over 300,000
  generated inputs in five seeds and found no difference.
- Speech text follows NSRegularExpression (ICU) as the app used it (#160,
  HK-215): `\s` is the White_Space property, line breaks included, so a
  heading or quote marker swallows the blank lines after it; `(?m)^`
  matches at the start and after U+000A to U+000D, U+0085, U+2028 and
  U+2029, but not between a CR and its LF (measured with
  NSRegularExpression on macOS 27.2), and is looked up in the text each
  pass was given; no regex crate matches those line starts, so each
  pattern is a hand-written pass. Star bullets pair as italic markers
  before the bullet rule runs (`* a\n* b\n* c` reads "a b c"), as in
  Swift. The placeholder becomes the phrase wherever a U+FFFC stands, the
  input's own ones too, except one a combining scalar extends
  (`replacingOccurrences`; HK-214); U+200B survives the whitespace
  collapse but not the final trim; the cut counts Characters and compares
  each ender as a whole Character, so an ender a combining mark extends
  is no ender (HK-216, HK-173).
- The language decision keeps Swift's gates (HK-212, HK-213): empty text
  is undecided; CJK script decides from a 20% share of the Alphabetic
  scalars (any kana ja, else any hangul ko, else zh, with the ranges of
  `language.json`); else a statistical answer needs 25 Alphabetic scalars
  and a confidence above the gate, and undecided reads as English. Swift
  trusted the recognizer's zh, ja or ko before the script rule; whatlang's
  zh, ja or ko is no statistical answer but a count of scripts, which takes
  the whole Halfwidth and Fullwidth Forms block (U+FF00..U+FFEF) for hangul
  (so "完成！！！" and "はい！！！" came out Korean) and weighs kana against
  Han by a 5% share of its own, so the core decides CJK by the script rule
  alone, and a zh, ja or ko the script does not back is undecided (HK-423).
  The fence placeholder is a space to whatlang, which reads every scalar
  outside ASCII punctuation and digits as part of a word, so a code block
  adds no confidence to the reply around it (HK-214). The statistical
  answer is whatlang's, restricted to the 47 languages it shares with
  NLLanguageRecognizer (listed from the recognizer's hypotheses for every
  script on macOS 27.2), so the core never names a language the app could
  not have chosen. whatlang's confidence is its margin over the runner-up,
  not a probability, so its gate is above 0.59 where the recognizer's was
  above 0.7: on the agreement corpus 0.59 lies between the most confident
  wrong answer (a German sentence read as French at 0.58) and the least
  confident right one (English code prose at 0.60) (HK-421). whatlang's
  confidence grows with the length of text at the same lean, so that
  sentence written twice passes the gate as French: the one corpus case
  where the core names a language outside CJK that the app did not
  (HK-424).
- Accepted differences, each a case of
  `Tests/Fixtures/speech/language-agreement.json` with `expected.core`
  (144 sentences, 29 of them differences), and of three kinds, which both
  runners enforce: the core undecided, CJK decided by its script where the
  recognizer named another CJK language, and German read as French.
  Han-only text with no kana is zh in the core, where the recognizer knew
  Japanese words written in kanji (東京駅, 日本語, 新幹線 and
  合計：１，２３４，５６７円 read ja in the app; 大丈夫 agrees; HK-420); a
  Japanese reply holds kana, and any kana decides ja in the core, however
  much Han is around it (株式会社日本経済新聞社代表取締役社長の挨拶 agrees,
  where whatlang alone said Chinese). The script rule also decides where
  the recognizer read the words around a quoted script (HK-423): Chinese
  or Korean quoting a katakana word (「ログイン」) is ja in the core and was
  zh or ko in the app, Korean with Han (大韓民國 헌법 제１조) is ko and was
  zh, and Korean with full-width exclamation marks is ko and was ja. Text
  whose only CJK-looking scalars are full-width forms is undecided in the
  core where the recognizer said ja (（１２／１２）, ｶﾀｶﾅ; HK-423). Eleven
  sentences are undecided in the core where whatlang is less sure than
  the recognizer was (HK-421): five the app read as English anyway, and six
  German (one of them with a code block), Spanish, Dutch and Russian ones
  that now read in English instead of their language. Five languages only
  the recognizer names (Icelandic, Kazakh, Lao, Tibetan, Cherokee) are
  undecided in the core, and Amharic, which only whatlang names, is
  undecided in both (HK-422). The German sentence written twice reads as
  French (HK-424).
- The summary rules count Characters (HK-169, HK-170, HK-173): a reply is
  summarized from 350 Characters, untrimmed; an answer is spoken when,
  trimmed of `whitespacesAndNewlines`, it is not empty and shorter than
  max(200, reply Characters / 2, rounding down), the reply counted
  untrimmed; the prompt is fixed English text with the reply appended as
  it is (`summary-prompt.json` pins it whole, where the Swift test checked
  four substrings).
- Before the Swift speech code was deleted, `Tests/Fixtures/speech/` was
  captured from it (eight tables), and a scratch differential compared the
  Swift code, copied pure into an optimized binary, with the core: each of
  the 13 markdown passes on 70,000 random markdown inputs (it found the
  CR-LF line-start rule; after the fix no difference), the whole spoken
  text on 120,000 inputs wherever both chose the same zh or other phrases
  (no difference), and a debug build of the core on 80,000 inputs (same
  output, no panic). On 20,000 natural single-language replies built from
  corpus sentences, a quarter of them with a code block, the decisions
  differ 451 times: 445 times undecided in the core, all from the accepted
  sentences, and 6 times German read as French, each the one sentence
  ("Bitte prüfe…") repeated (HK-424); until the placeholder weighed
  nothing, that sentence with a code block read as French too. On 20,000
  random strings mixing kana, Han, hangul, full-width forms and CJK
  punctuation they differ 3,924 times (8,143 while the core trusted
  whatlang's CJK answer, 5,495 of them Japanese read as Korean), and with
  the full-width comma the only full-width form, 3,412 times (3,836): the
  differences of HK-423 at random, where the recognizer weighs words and
  the core scripts (Chinese or Korean holding kana is ja in the core,
  Chinese holding hangul ko), and text holding only CJK punctuation is
  undecided where the recognizer said ja.

## E. Left for the maintainer

Ticket #156's acceptance criterion that a macOS-written configuration loads
unchanged is pinned by the first case of `config/round-trip.json`; a
maintainer's own config.json loading and saving unchanged on a real launch
(`open build/PowerUp.app`) is the manual check, and no agent runs it.

Ticket #157's acceptance criterion that transcripts persisted before the
swap load unchanged is pinned by
`TranscriptStoreTests.testPersistedLinesFromBeforeTheSwapLoad` (lines the
old encoder wrote) and
`transcript/lines.json`; opening a project with a real history from an
earlier build and seeing it restored is the manual check, and no agent
runs it.

Ticket #158's acceptance criteria are met by the tables and suites above:
the installer tests run through the bridge against temporary files and
never touch the real settings file (`HermeticStorageTests`), and a missing
event never reads as installed. Installing and removing the hooks from
Settings on a real machine, and seeing a real Claude Code session read
back, is the manual check; agents may not touch `~/.claude/settings.json`
(CLAUDE.md), so no agent runs it.

Ticket #159's first acceptance criterion, the 1.3 fixtures passing in both
languages, is met: `rust/powerup-core/tests/text_safety.rs` and
`TextSafetyFixtureTests` / `CmuxReportingFixtureTests`, through the
bridge, play all six tables. The second, that dictated multi-line text
injects as one line in remote mode, is the manual check on a real machine
(cmux and a terminal target); agents may not run `cmux send` or
`send-key` against real workspaces (CLAUDE.md), so no agent runs it.

Ticket #160's first acceptance criterion, the speech text fixtures passing
in Rust (and in Swift), is met: `rust/powerup-core/tests/speech.rs` and
`SpeechFixtureTests`, through the bridge, play all eight tables. The
second, that the agreement fixture lists any accepted differences, is met
by `language-agreement.json`'s `expected.core` cases with HK-420 to
HK-424. The third, that a mixed-language reply reads in the expected
voices, is the manual check with the app launched as a bundle and speech
on: a Chinese reply with English identifiers and a fenced code block reads
in a Chinese voice and says 代码已省略 for the code, an English reply quoting
a Chinese character or two stays in an English voice, and a Japanese reply
with kana reads in a Japanese voice. Agents do not play audio (their tests
record speech instead of speaking, AGENTS.md), so no agent runs it. With
#160 every ticket of stage 2.5 has landed.
