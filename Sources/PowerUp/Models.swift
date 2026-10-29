import Foundation
import AVFAudio

// MARK: - ControllerButton

enum ControllerButton: String, Codable, CaseIterable, Identifiable, Hashable {
    case cross, circle, square, triangle
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l1, r1, l2, r2, l3, r3
    case create      // left small button (GCExtendedGamepad.buttonOptions)
    case options     // right small button (GCExtendedGamepad.buttonMenu)
    case touchpad    // touchpad click (GCDualSenseGamepad.touchpadButton)
    case ps          // PS/home button (buttonHome) — mappable but default .none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cross: return "Cross (✕)"
        case .circle: return "Circle (○)"
        case .square: return "Square (□)"
        case .triangle: return "Triangle (△)"
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .l1: return "L1 Bumper"
        case .r1: return "R1 Bumper"
        case .l2: return "L2 Trigger"
        case .r2: return "R2 Trigger"
        case .l3: return "L3 (Left Stick Click)"
        case .r3: return "R3 (Right Stick Click)"
        case .create: return "Create"
        case .options: return "Options"
        case .touchpad: return "Touchpad"
        case .ps: return "PS Button"
        }
    }

    var symbolName: String {
        switch self {
        case .cross: return "xmark.circle"
        case .circle: return "circle.circle"
        case .square: return "square.circle"
        case .triangle: return "triangle.circle"
        case .dpadUp: return "dpad.up.filled"
        case .dpadDown: return "dpad.down.filled"
        case .dpadLeft: return "dpad.left.filled"
        case .dpadRight: return "dpad.right.filled"
        case .l1: return "l1.button.roundedbottom.horizontal"
        case .r1: return "r1.button.roundedbottom.horizontal"
        case .l2: return "l2.button.roundedtop.horizontal"
        case .r2: return "r2.button.roundedtop.horizontal"
        case .l3: return "l3.button.horizontal"
        case .r3: return "r3.button.horizontal"
        case .create: return "plus.rectangle"
        case .options: return "line.3.horizontal"
        case .touchpad: return "rectangle.and.hand.point.up.left"
        case .ps: return "playstation.logo"
        }
    }
}

// MARK: - Action

/// Encodable only: the Rust core decodes actions (slice 2.2). This
/// synthesized encoder is still the config writer until slice 2.5, and the
/// shared `mapping/action-shape.json` table pins it to the core's bytes.
enum Action: Encodable, Hashable {
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
    case cycleModel               // step config.model through config.modelCycle (live via set_model)
    case cycleEffort              // step config.effort through the fixed effort cycle (restart + resume)
    case cyclePermissionMode      // step config.permissionMode through the fixed cycle (live)
    case cycleProject             // step config.projectDir through recentProjectDirs (own session each)
    case cycleFocus               // remote mode: step read-back focus through active sessions
    case pushToTalkDraft          // hold to dictate into the prompt box; nothing is sent
    case sendDraft                // send whatever the prompt box currently holds
    case toggleControlMode        // flip config.controlMode between "builtin" and "remote"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .pushToTalk: return "Push to Talk"
        case .sendPrompt: return "Send Prompt…"
        case .approve: return "Approve (Yes)"
        case .reject: return "Reject (No)"
        case .interrupt: return "Interrupt"
        case .stopSpeaking: return "Stop Speaking"
        case .replayLastReply: return "Replay Last Reply"
        case .toggleTTS: return "Toggle Speech"
        case .newSession: return "New Session"
        case .showWindow: return "Show Window"
        case .cycleModel: return "Cycle Model"
        case .cycleEffort: return "Cycle Effort"
        case .cyclePermissionMode: return "Cycle Permission Mode"
        case .cycleProject: return "Cycle Project"
        case .cycleFocus: return "Cycle Session Focus"
        case .pushToTalkDraft: return "Dictate to Prompt Box"
        case .sendDraft: return "Send Prompt Box"
        case .toggleControlMode: return "Toggle Built-in / Remote"
        }
    }

    /// Actions that record while the button is held and finish on release.
    /// Everything else fires once, on the way down. The rule lives in the
    /// Rust core (`powerup-core` `Action::is_hold`).
    var isHoldAction: Bool { CoreBridge.isHold(self) }
}

/// The pre-v2.7 spelling of `Action`. Kept for one release so an out-of-tree
/// caller (a fork, a plugin) gets a warning instead of a source break; the
/// vocabulary is `Action` everywhere (DESIGN.md v2.7 addendum, §A). Deleted in
/// the release after this one.
@available(*, deprecated, message: "Renamed to Action in DESIGN v2.7; this alias is deleted in the release after.")
typealias ControllerAction = Action

// MARK: - Device profiles (ADR 0006)

/// One control on a device, described as data. String ids are the stable
/// identity, so profiles can cross the wire (protocol device registration),
/// live in bundled JSON files (HID profiles), and be consumed by non-Swift
/// cores — never Swift enum cases.
struct ControlDescriptor: Codable, Equatable, Hashable, Identifiable {
    /// The kinds a control can have. v2.7 dropped `hold`: whether an action
    /// holds is a property of the action (`Action.isHoldAction`), never of the
    /// control.
    enum Kind: String, Codable {
        case button, axis, key

        /// A profile written before v2.7 may carry the obsolete `"hold"`
        /// value; it reads as a button rather than failing the profile, and
        /// encoding goes through the raw value, which no longer has `hold`.
        /// The rule lives in the Rust core (`ControlKind::from_wire`).
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let kind = CoreBridge.controlKind(wireName: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown control kind \"\(raw)\"")
            }
            self = kind
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let id: String
    var kind: Kind
    var displayName: String
    var symbolName: String
}

/// A device described as data: identity plus its controls. The DualSense
/// ships as the first built-in profile; HID and virtual devices add theirs
/// as data later.
struct DeviceProfile: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var controls: [ControlDescriptor]

    static let dualSenseID = "dualsense"

    /// The built-in profile carrying today's DualSense controls, from the
    /// Rust core (`profile::dualsense_profile`). Its descriptors mirror
    /// `ControllerButton`'s display metadata, which DeviceProfileTests pins,
    /// so the serialized profile and the Swift enum can never disagree. A
    /// failed core call leaves a profile with no controls, which
    /// `testDualSenseIDMatchesTheCore` catches.
    static let dualSense = CoreBridge.dualSenseProfile()
        ?? DeviceProfile(id: dualSenseID, displayName: "DualSense", controls: [])
}

/// controlId → action; stored per profile id in `AppConfig.deviceMappings`.
typealias DeviceMapping = [String: Action]

// MARK: - AppConfig

struct AppConfig: Codable, Equatable {
    var projectDir: String?               // absolute path of the coding project; nil = not chosen
    var model: String                     // "default" | "sonnet" | "opus" | "haiku" | "fable"
    var permissionMode: String            // "acceptEdits" (default) | "default" | "plan" | "bypassPermissions"
    var claudePath: String?               // manual override of the claude binary path
    var lastSessionID: String?            // for --resume across app launches
    var ttsEnabled: Bool
    var ttsRate: Float                    // AVSpeechUtterance rate; default AVSpeechUtteranceDefaultSpeechRate
    var ttsVoiceID: String?               // AVSpeechSynthesisVoice identifier; nil = best available en voice
    var maxSpokenChars: Int               // cap spoken reply length; 0 = no limit; default 1500
    var speakSummaries: Bool              // long replies: speak a model-written 1-2 sentence conclusion; default false
    var summaryModel: String              // alias for the summary model; default "haiku"
    var localeID: String                  // STT locale; default "en-US"
    var onDeviceRecognition: Bool         // default false
    var audioInputUID: String?            // STT microphone device UID; nil = system default
    var audioOutputUID: String?           // TTS output device UID; nil = system default
    var controllerDeviceID: String?       // Controller slot pin; nil = Automatic (DESIGN v2.7 B)
    var hapticsEnabled: Bool              // default true
    var lightEnabled: Bool                // default true
    var effort: String                    // "default" (omit the flag) | "low" | "medium" | "high" | "xhigh"
    var modelCycle: [String]              // aliases the Cycle Model button steps through

    // MARK: Harness selection (M3)

    var harnessKind: String               // "claude" (built-in stream-json, default) | "acp"
    var acpAgent: String                  // "opencode" (default) | "claudeBridge" | "custom"
    var acpCustomCommand: String          // space-separated command line for acpAgent == "custom"

    // MARK: Remote control (v1.4)

    var controlMode: String               // "builtin" (PowerUp runs claude) | "remote" (drive an existing session)
    var remoteTargetKind: String          // "cmux" | "frontmost" | "app"
    var remoteCmuxWorkspace: String?      // e.g. "workspace:11"; nil = the currently selected workspace
    var remoteCmuxSurface: String?        // optional surface ref inside the workspace; nil = the default one
    var remoteAppBundleID: String?        // target application for remoteTargetKind "app"
    var remoteCmuxPassword: String?       // cmux socket password (Automation → Password mode); nil = none
    var remoteAutoSubmit: Bool            // press Enter after typing text into the target
    var listenerPort: Int                 // local read-back listener port (127.0.0.1 only)
    var listenerToken: String             // shared secret the Claude Code hook sends back; never empty in practice

    // MARK: Multiple conversations (several folders)

    var recentProjectDirs: [String]       // most-recent-first, capped; Cycle Project steps through it
    var sessionIDsByProject: [String: String]  // project path -> resumable session id

    /// The mapping truth: profile id → (control id → action). The DualSense
    /// lives under `DeviceProfile.dualSenseID`; future devices add their own
    /// entries without touching this shape (ADR 0006).
    var deviceMappings: [String: DeviceMapping]

    /// Compatibility view of the DualSense profile's mapping, keyed by the
    /// enum. Reads and writes route to `deviceMappings`, so there is exactly
    /// one source of truth and every existing call site keeps working.
    var mapping: [ControllerButton: Action] {
        get {
            var out: [ControllerButton: Action] = [:]
            for (controlID, action) in deviceMappings[DeviceProfile.dualSenseID] ?? [:] {
                if let button = ControllerButton(rawValue: controlID) { out[button] = action }
            }
            return out
        }
        set {
            // Merge, don't replace: enum-keyed writes carry full button
            // semantics (a button absent from newValue is unmapped), but
            // control ids that aren't buttons (a future axis, a hand-added
            // entry) must survive a bridge edit untouched.
            var merged = deviceMappings[DeviceProfile.dualSenseID] ?? [:]
            for key in merged.keys where ControllerButton(rawValue: key) != nil {
                merged.removeValue(forKey: key)
            }
            for (button, action) in newValue { merged[button.rawValue] = action }
            deviceMappings[DeviceProfile.dualSenseID] = merged
        }
    }

    /// The action mapped to (profile, control); `.none` when unmapped. The
    /// single resolution point every input surface routes through; the rule
    /// lives in the Rust core (`mapping::resolve_action`).
    func action(onProfile profileID: String, control controlID: String) -> Action {
        CoreBridge.action(in: deviceMappings, profileID: profileID, controlID: controlID)
    }

    // MARK: Fixed option sets

    /// Aliases a fresh config cycles through with the Cycle Model action.
    static let defaultModelCycle: [String] = ["sonnet", "opus", "haiku", "fable"]

    /// Every value the effort setting can take (`default` = don't pass `--effort`).
    /// "max" is surfaced as **Ultra**: maximum CLI effort plus dynamic
    /// multi-agent workflows (the `ultracode` prompt keyword) — verified live:
    /// `claude -p --effort max` is accepted by the CLI.
    static let effortOptions: [String] = ["default", "low", "medium", "high", "xhigh", "max"]

    /// Cycle order for the Cycle Effort action — "default" is not part of it.
    static let effortCycle: [String] = ["low", "medium", "high", "xhigh", "max"]

    /// Human name for an effort value ("max" reads as Ultra everywhere).
    static func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "default": return "Default"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Ultra"
        default: return effort
        }
    }

    /// Cycle order for the Cycle Permission Mode action. `bypassPermissions` is
    /// deliberately excluded: a stray button press must never turn on
    /// auto-approve-everything (it stays available in Settings).
    static let permissionModeCycle: [String] = ["acceptEdits", "plan", "default"]

    /// Where controller and voice input is delivered.
    static let controlModeOptions: [String] = ["builtin", "remote"]

    /// Which adapter runs the built-in session.
    static let harnessKindOptions: [String] = ["claude", "acp"]

    /// Preset agents the ACP adapter can spawn (plus a custom command).
    static let acpAgentOptions: [String] = ["opencode", "claudeBridge", "codexBridge", "custom"]

    static func acpAgentDisplayName(_ agent: String) -> String {
        switch agent {
        case "opencode": return "opencode"
        case "claudeBridge": return "Claude Code (ACP bridge)"
        case "codexBridge": return "Codex (ACP bridge)"
        case "custom": return "Custom command"
        default: return agent
        }
    }

    /// How remote mode reaches the session it drives. cmux (socket, no
    /// permission) comes first; the two keystroke-injection kinds follow.
    static let remoteTargetKinds: [String] = ["cmux", "app", "frontmost"]

    /// Human label for a `remoteTargetKind`, used by the Settings picker.
    static func remoteTargetKindDisplayName(_ kind: String) -> String {
        switch kind {
        case "cmux": return "cmux (no permission needed)"
        case "app": return "Terminal / specific app"
        case "frontmost": return "Frontmost app"
        default: return kind
        }
    }

    /// Common terminal / cmux app bundle ids, offered as quick-picks for the
    /// "app" injection target and used to name an app in friendly error text.
    /// cmux is listed for naming, but the "cmux" kind (socket, no permission)
    /// is the right way to target it — the Settings UI steers users there.
    static let knownTerminalApps: [(name: String, bundleID: String)] = [
        ("cmux", "com.cmuxterm.app"),
        ("Terminal", "com.apple.Terminal"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Alacritty", "org.alacritty"),
    ]

    /// Port the hook read-back listener binds on 127.0.0.1 by default.
    static let defaultListenerPort: Int = 48738

    static func defaultConfig() -> AppConfig {
        AppConfig(
            projectDir: nil,
            model: "default",
            permissionMode: "acceptEdits",
            claudePath: nil,
            lastSessionID: nil,
            ttsEnabled: true,
            ttsRate: AVSpeechUtteranceDefaultSpeechRate,
            ttsVoiceID: nil,
            maxSpokenChars: 1500,
            speakSummaries: false,
            summaryModel: "haiku",
            localeID: "en-US",
            onDeviceRecognition: false,
            audioInputUID: nil,
            audioOutputUID: nil,
            controllerDeviceID: nil,
            hapticsEnabled: true,
            lightEnabled: true,
            effort: "default",
            modelCycle: defaultModelCycle,
            harnessKind: "claude",
            acpAgent: "opencode",
            acpCustomCommand: "",
            controlMode: "builtin",
            remoteTargetKind: "cmux",
            remoteCmuxWorkspace: nil,
            remoteCmuxSurface: nil,
            remoteAppBundleID: nil,
            remoteCmuxPassword: nil,
            remoteAutoSubmit: true,
            listenerPort: defaultListenerPort,
            // Filled in by ConfigStore on first launch (it never leaves an empty
            // token behind), so the listener always has a secret to check.
            listenerToken: "",
            recentProjectDirs: [],
            sessionIDsByProject: [:],
            deviceMappings: defaultDeviceMappings()
        )
    }

    /// The stored default: the DualSense profile carrying the v1.3 layout
    /// keyed by control id. The table lives in the Rust core
    /// (`mapping::default_mapping`).
    static func defaultDeviceMappings() -> [String: DeviceMapping] {
        CoreBridge.defaultDeviceMappings()
    }

    /// The default DualSense layout, keyed by the enum for the Settings editor.
    static func defaultMapping() -> [ControllerButton: Action] {
        var out: [ControllerButton: Action] = [:]
        for (controlID, action) in defaultDeviceMappings()[DeviceProfile.dualSenseID] ?? [:] {
            if let button = ControllerButton(rawValue: controlID) { out[button] = action }
        }
        return out
    }

    /// Explicit keys so the tolerant decoder below and the synthesized encoder
    /// agree on the on-disk shape. `mapping`, the pre-ADR-0006 key, is not
    /// here: it is read only by the core and never written.
    private enum CodingKeys: String, CodingKey {
        case projectDir, model, permissionMode, claudePath, lastSessionID
        case ttsEnabled, ttsRate, ttsVoiceID, maxSpokenChars
        case speakSummaries, summaryModel
        case localeID, onDeviceRecognition, audioInputUID, audioOutputUID, controllerDeviceID
        case hapticsEnabled, lightEnabled
        case effort, modelCycle
        case harnessKind, acpAgent, acpCustomCommand
        case controlMode, remoteTargetKind, remoteCmuxWorkspace, remoteCmuxSurface
        case remoteAppBundleID, remoteCmuxPassword, remoteAutoSubmit, listenerPort, listenerToken
        case recentProjectDirs, sessionIDsByProject
        case deviceMappings
    }
}

// MARK: - Tolerant decoding
//
// Declared in an extension so the struct keeps its memberwise initializer.
// Every key is optional on the way in: a config.json written by an older build
// (no `effort` / `modelCycle`), or one a user hand-edited into a partial state,
// still loads with sensible defaults instead of being thrown away. Encoding
// stays synthesized, so saving always writes the complete, current shape.
extension AppConfig {

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppConfig.defaultConfig()

        func optionalString(_ key: CodingKeys) -> String? {
            ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? defaultValue
        }
        /// For the small fixed-vocabulary settings: an unrecognised value on disk
        /// (typo, or a setting from a newer build) reads back as the default
        /// rather than putting the app in a state no code path handles.
        func option(_ key: CodingKeys, _ allowed: [String], _ defaultValue: String) -> String {
            let raw = value(key, defaultValue)
            return allowed.contains(raw) ? raw : defaultValue
        }

        let port = value(.listenerPort, fallback.listenerPort)

        self.init(
            projectDir: optionalString(.projectDir),
            model: value(.model, fallback.model),
            permissionMode: value(.permissionMode, fallback.permissionMode),
            claudePath: optionalString(.claudePath),
            lastSessionID: optionalString(.lastSessionID),
            ttsEnabled: value(.ttsEnabled, fallback.ttsEnabled),
            ttsRate: value(.ttsRate, fallback.ttsRate),
            ttsVoiceID: optionalString(.ttsVoiceID),
            maxSpokenChars: value(.maxSpokenChars, fallback.maxSpokenChars),
            speakSummaries: value(.speakSummaries, fallback.speakSummaries),
            summaryModel: {
                let raw = value(.summaryModel, fallback.summaryModel)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? fallback.summaryModel : raw
            }(),
            localeID: value(.localeID, fallback.localeID),
            onDeviceRecognition: value(.onDeviceRecognition, fallback.onDeviceRecognition),
            audioInputUID: optionalString(.audioInputUID),
            audioOutputUID: optionalString(.audioOutputUID),
            controllerDeviceID: optionalString(.controllerDeviceID),
            hapticsEnabled: value(.hapticsEnabled, fallback.hapticsEnabled),
            lightEnabled: value(.lightEnabled, fallback.lightEnabled),
            effort: value(.effort, fallback.effort),
            modelCycle: value(.modelCycle, fallback.modelCycle),
            harnessKind: option(.harnessKind, AppConfig.harnessKindOptions, fallback.harnessKind),
            acpAgent: option(.acpAgent, AppConfig.acpAgentOptions, fallback.acpAgent),
            acpCustomCommand: value(.acpCustomCommand, fallback.acpCustomCommand),
            controlMode: option(.controlMode, AppConfig.controlModeOptions, fallback.controlMode),
            remoteTargetKind: option(.remoteTargetKind, AppConfig.remoteTargetKinds, fallback.remoteTargetKind),
            remoteCmuxWorkspace: optionalString(.remoteCmuxWorkspace),
            remoteCmuxSurface: optionalString(.remoteCmuxSurface),
            remoteAppBundleID: optionalString(.remoteAppBundleID),
            remoteCmuxPassword: optionalString(.remoteCmuxPassword),
            remoteAutoSubmit: value(.remoteAutoSubmit, fallback.remoteAutoSubmit),
            listenerPort: (1...65535).contains(port) ? port : fallback.listenerPort,
            listenerToken: value(.listenerToken, fallback.listenerToken),
            recentProjectDirs: value(.recentProjectDirs, fallback.recentProjectDirs),
            sessionIDsByProject: value(.sessionIDsByProject, fallback.sessionIDsByProject),
            deviceMappings: AppConfig.decodeDeviceMappings(from: decoder) ?? fallback.deviceMappings
        )
    }

    private enum MappingSubtreeKeys: String, CodingKey {
        case deviceMappings, mapping
    }

    /// The mapping subtree is the Rust core's (slice 2.2,
    /// `mapping::load_device_mappings`): the new shape wins outright when it
    /// is an object, decoded per entry tolerantly; otherwise the legacy
    /// button-keyed `mapping` migrates losslessly into the DualSense profile;
    /// neither gives the defaults. The two keys go across as written, a null
    /// kept distinct from an absent key. ConfigStore asks the core the same
    /// question to decide on its backup copy. nil only when the core fails.
    private static func decodeDeviceMappings(from decoder: Decoder) -> [String: DeviceMapping]? {
        guard let container = try? decoder.container(keyedBy: MappingSubtreeKeys.self) else { return nil }
        var subtree: [String: JSONValue] = [:]
        for key in [MappingSubtreeKeys.deviceMappings, .mapping] where container.contains(key) {
            subtree[key.stringValue] = (try? container.decode(JSONValue.self, forKey: key)) ?? .null
        }
        guard let text = JSONValue.object(subtree).jsonText else { return nil }
        return CoreBridge.loadDeviceMappings(configJSON: text)?.deviceMappings
    }
}

// MARK: - AppStatus

enum AppStatus: Equatable {
    case noController      // light: off (0,0,0) — or dim white
    case idle              // light: green  (0.0, 1.0, 0.2)
    case listening         // light: red    (1.0, 0.0, 0.0)
    case thinking          // light: amber  (1.0, 0.45, 0.0)
    case speaking          // light: purple (0.55, 0.0, 1.0)

    var label: String {
        switch self {
        case .noController: return "No Controller"
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .thinking: return "Claude is working…"
        case .speaking: return "Speaking"
        }
    }
}

// MARK: - TranscriptEntry

struct TranscriptEntry: Identifiable, Equatable, Codable {
    enum Kind: String, Equatable, Codable { case user, assistant, tool, system, error }

    let id: UUID
    let kind: Kind
    var text: String
    let date: Date

    init(kind: Kind, text: String) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.date = Date()
    }
}

// MARK: - ClaudeState

enum ClaudeState: Equatable { case stopped, starting, ready, working }

// MARK: - ClaudeEvent

enum ClaudeEvent: Equatable {
    case ready(sessionID: String, model: String)         // system/init parsed
    case textDelta(String)                               // stream_event text_delta
    case assistantMessage(String)                        // joined text blocks of an assistant message
    case toolUse(name: String, detail: String)           // e.g. ("Edit", "src/main.py")
    case turnCompleted(resultText: String?, costUSD: Double?, isError: Bool, subtype: String)
    /// Answer to a control_request we sent: action is the subtype
    /// ("interrupt" | "set_model" | "set_permission_mode"), `detail` carries the
    /// CLI's error text when `ok` is false and is empty otherwise. `value` is
    /// the value that request asked for (the model alias / permission mode;
    /// nil for interrupt), so an ack identifies exactly what was confirmed or
    /// rejected even with several requests in flight.
    case controlResult(action: String, ok: Bool, detail: String, value: String?)
    case processError(String)                            // stderr content / spawn failure
    case terminated(exitCode: Int32)
}
