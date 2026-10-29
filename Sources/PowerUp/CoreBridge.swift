import Foundation
import os
import PowerUpCore

/// The Rust core's bridge as the app sees it (ADR 0012, DESIGN v2.11,
/// v2.12). This file and the `CoreBridge*.swift` files beside it are the
/// only app files that import `PowerUpCore`: the generated types are
/// named `CoreAction`, `CoreIntent`, … and spelled the uniffi way
/// (`toggleTts`, `profileId`), so they stay behind these wrappers and the
/// app keeps its own `Action`, `Intent` and friends as thin conversions.
///
/// The functions here are synchronous, pure and safe from any thread; the
/// objects of slice 2.3 say where they may be called. A bridge error
/// is a core bug — the core never fails on these inputs — so each wrapper
/// logs it (subsystem `com.powerup.claudepad`, category `core`) and returns
/// the inert answer instead of throwing into the app.
enum CoreBridge {
    /// The launch check's outcome, as logged.
    enum Status: Equatable {
        case answering
        case failed(String)
    }

    static let log = Logger(subsystem: "com.powerup.claudepad", category: "core")

    static func check() -> Status {
        do {
            return try probeEcho(text: "ping") == "ping" ? .answering : .failed("echo mismatch")
        } catch {
            return .failed("\(error)")
        }
    }

    /// Logs the launch check under the app's subsystem, category `core`.
    static func logStatus() {
        switch check() {
        case .answering: log.notice("Rust core linked and answering")
        case .failed(let reason): log.error("Rust core linked but failed: \(reason, privacy: .public)")
        }
    }

    // MARK: - The mapping layer (slice 2.2)
    //
    // Generated functions share names with these wrappers, so every call is
    // written `PowerUpCore.…`: unqualified, it would resolve to the wrapper
    // and recurse.

    /// The intent `action` produces for a press or a release
    /// (`powerup-core` `intent::intent_for`); nil when the core fails.
    static func intent(for action: Action, phase: ControlPhase) -> Intent? {
        call("intentForAction", fallback: nil) {
            try PowerUpCore.intentForAction(action: action.core, phase: phase.core).map(Intent.init)
        }
    }

    /// Whether `action` records while held; false when the core fails.
    static func isHold(_ action: Action) -> Bool {
        call("actionIsHold", fallback: false) {
            try PowerUpCore.actionIsHold(action: action.core)
        }
    }

    /// The compact JSON the core writes for `action`, byte for byte what
    /// `JSONEncoder` with `.sortedKeys` writes; nil when the core fails.
    static func wireJSON(of action: Action) -> String? {
        call("actionWireJson", fallback: nil) {
            try PowerUpCore.actionWireJson(action: action.core)
        }
    }

    /// The action mapped to (profile, control); `.none` when unmapped or
    /// when the core fails.
    static func action(in deviceMappings: [String: DeviceMapping],
                       profileID: String, controlID: String) -> Action {
        call("resolveAction", fallback: Action.none) {
            Action(try PowerUpCore.resolveAction(deviceMappings: deviceMappings.core,
                                                 profileId: profileID, controlId: controlID))
        }
    }

    /// The shipped mappings; empty when the core fails.
    static func defaultDeviceMappings() -> [String: DeviceMapping] {
        call("defaultDeviceMappings", fallback: [:]) {
            [String: DeviceMapping](core: try PowerUpCore.defaultDeviceMappings())
        }
    }

    /// What the core decided about a config's mapping subtree.
    struct MappingLoad: Equatable {
        /// The mappings the app runs with.
        let deviceMappings: [String: DeviceMapping]
        /// Whether the file must be copied before the next save rewrites it.
        let backupBeforeSave: Bool
    }

    /// Resolves a config.json object's mapping subtree (tolerance, legacy
    /// migration, the new key winning, the backup decision). nil when the
    /// text is not a JSON object or the core fails.
    static func loadDeviceMappings(configJSON: String) -> MappingLoad? {
        call("loadDeviceMappings", fallback: nil) {
            let load = try PowerUpCore.loadDeviceMappings(configJson: configJSON)
            return MappingLoad(deviceMappings: [String: DeviceMapping](core: load.deviceMappings),
                               backupBeforeSave: load.backupBeforeSave)
        }
    }

    /// The kind a profile file's string reads as (the pre-v2.7 `hold` reads
    /// as a button); nil for anything else or when the core fails.
    static func controlKind(wireName: String) -> ControlDescriptor.Kind? {
        call("controlKindFromWire", fallback: nil) {
            try PowerUpCore.controlKindFromWire(name: wireName).map(ControlDescriptor.Kind.init)
        }
    }

    /// The built-in DualSense profile; nil when the core fails.
    static func dualSenseProfile() -> DeviceProfile? {
        call("dualsenseProfile", fallback: nil) {
            DeviceProfile(try PowerUpCore.dualsenseProfile())
        }
    }

    // MARK: - The device layer (slice 2.2)

    /// The controller that fills the Controller slot
    /// (`powerup-core` `slots::select_active_controller`); nil when the slot
    /// is empty or when the core fails.
    static func activeController(mostRecentlyConnectedFirst: [ConnectedController],
                                 pinnedID: String?) -> ConnectedController? {
        call("selectActiveController", fallback: nil) {
            try PowerUpCore.selectActiveController(
                mostRecentlyConnectedFirst: mostRecentlyConnectedFirst.map(\.core),
                pinnedId: pinnedID
            ).map(ConnectedController.init)
        }
    }

    /// One input through the hold rule (`powerup-core` `hold::HoldState::step`):
    /// the owner to keep and the effect to apply. When the core fails the
    /// owner is kept and the input is ignored.
    static func holdStep(owner: String?, action: Action, control: String, phase: ControlPhase,
                         toggleCaptureActive: Bool) -> (owner: String?, effect: HoldEffect) {
        call("holdTrackerStep", fallback: (owner, HoldEffect.ignore)) {
            let step = try PowerUpCore.holdTrackerStep(state: CoreHoldState(owner: owner),
                                                       action: action.core, controlId: control,
                                                       phase: phase.core,
                                                       toggleCaptureActive: toggleCaptureActive)
            return (step.state.owner, HoldEffect(step.effect))
        }
    }

    /// Ends a hold the active controller owns (`hold::HoldState::release_all`).
    /// When the core fails the owner is kept and nothing happens.
    static func holdReleaseAll(owner: String?) -> (owner: String?, effect: HoldEffect) {
        call("holdTrackerReleaseAll", fallback: (owner, HoldEffect.ignore)) {
            let step = try PowerUpCore.holdTrackerReleaseAll(state: CoreHoldState(owner: owner))
            return (step.state.owner, HoldEffect(step.effect))
        }
    }

    /// Runs one bridge call; a failure is logged and answered with `fallback`.
    static func call<T>(_ name: String, fallback: T, _ body: () throws -> T) -> T {
        do {
            return try body()
        } catch {
            log.error("Rust core call \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return fallback
        }
    }
}

// MARK: - JSON text across the bridge

/// Any JSON value. The core takes config text, so the app reads the parts it
/// hands over into this and writes them back out with `jsonText`. Integers
/// and doubles stay apart so a value re-encodes as it was read.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Never throws on valid JSON: a value none of the cases can hold (a
    /// number past Double's range) reads as null, which no mapping position
    /// accepts either.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            self = .null
            return
        }
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Compact JSON text, keys sorted; nil if it cannot be written. The
    /// outermost array or object is written here and only its members by
    /// JSONEncoder, which refuses 512 levels of nesting where JSONDecoder
    /// reads them: a config the app could load must reach the core whole.
    var jsonText: String? {
        switch self {
        case .object(let members):
            var parts: [String] = []
            for key in members.keys.sorted() {
                guard let name = JSONValue.string(key).encodedText,
                      let value = members[key]?.encodedText else { return nil }
                parts.append(name + ":" + value)
            }
            return "{" + parts.joined(separator: ",") + "}"
        case .array(let items):
            var parts: [String] = []
            for item in items {
                guard let value = item.encodedText else { return nil }
                parts.append(value)
            }
            return "[" + parts.joined(separator: ",") + "]"
        case .null, .bool, .integer, .number, .string:
            return encodedText
        }
    }

    private var encodedText: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Conversions
//
// Exhaustive switches with no `default:`, so a case added on either side is
// a compile error here instead of a silently wrong answer.

fileprivate extension Action {
    init(_ core: CoreAction) {
        switch core {
        case CoreAction.none: self = Action.none
        case .pushToTalk: self = .pushToTalk
        case .sendPrompt(let prompt): self = .sendPrompt(prompt)
        case .approve: self = .approve
        case .reject: self = .reject
        case .interrupt: self = .interrupt
        case .stopSpeaking: self = .stopSpeaking
        case .replayLastReply: self = .replayLastReply
        case .toggleTts: self = .toggleTTS
        case .newSession: self = .newSession
        case .showWindow: self = .showWindow
        case .cycleModel: self = .cycleModel
        case .cycleEffort: self = .cycleEffort
        case .cyclePermissionMode: self = .cyclePermissionMode
        case .cycleProject: self = .cycleProject
        case .cycleFocus: self = .cycleFocus
        case .pushToTalkDraft: self = .pushToTalkDraft
        case .sendDraft: self = .sendDraft
        case .toggleControlMode: self = .toggleControlMode
        }
    }

    var core: CoreAction {
        switch self {
        case Action.none: return CoreAction.none
        case .pushToTalk: return .pushToTalk
        case .sendPrompt(let prompt): return .sendPrompt(prompt: prompt)
        case .approve: return .approve
        case .reject: return .reject
        case .interrupt: return .interrupt
        case .stopSpeaking: return .stopSpeaking
        case .replayLastReply: return .replayLastReply
        case .toggleTTS: return .toggleTts
        case .newSession: return .newSession
        case .showWindow: return .showWindow
        case .cycleModel: return .cycleModel
        case .cycleEffort: return .cycleEffort
        case .cyclePermissionMode: return .cyclePermissionMode
        case .cycleProject: return .cycleProject
        case .cycleFocus: return .cycleFocus
        case .pushToTalkDraft: return .pushToTalkDraft
        case .sendDraft: return .sendDraft
        case .toggleControlMode: return .toggleControlMode
        }
    }
}

fileprivate extension VoiceCaptureMode {
    init(_ core: CoreVoiceCaptureMode) {
        switch core {
        case .send: self = .send
        case .draft: self = .draft
        }
    }
}

fileprivate extension ControlPhase {
    var core: CoreControlPhase {
        switch self {
        case .began: return .began
        case .ended: return .ended
        }
    }
}

fileprivate extension Intent {
    init(_ core: CoreIntent) {
        switch core {
        case .beginVoiceCapture(let mode): self = .beginVoiceCapture(VoiceCaptureMode(mode))
        case .endVoiceCapture: self = .endVoiceCapture
        case .sendPrompt(let prompt): self = .sendPrompt(prompt)
        case .sendDraft: self = .sendDraft
        case .approve: self = .approve
        case .reject: self = .reject
        case .interrupt: self = .interrupt
        case .stopSpeaking: self = .stopSpeaking
        case .replayLastReply: self = .replayLastReply
        case .toggleTts: self = .toggleTTS
        case .newSession: self = .newSession
        case .showWindow: self = .showWindow
        case .cycleModel: self = .cycleModel
        case .cycleEffort: self = .cycleEffort
        case .cyclePermissionMode: self = .cyclePermissionMode
        case .cycleProject: self = .cycleProject
        case .cycleFocus: self = .cycleFocus
        case .toggleControlMode: self = .toggleControlMode
        }
    }
}

fileprivate extension ControlDescriptor.Kind {
    init(_ core: CoreControlKind) {
        switch core {
        case .button: self = .button
        case .axis: self = .axis
        case .key: self = .key
        }
    }
}

fileprivate extension DeviceProfile {
    init(_ core: CoreDeviceProfile) {
        self.init(id: core.id, displayName: core.displayName, controls: core.controls.map {
            ControlDescriptor(id: $0.id, kind: ControlDescriptor.Kind($0.kind),
                              displayName: $0.displayName, symbolName: $0.symbolName)
        })
    }
}

fileprivate extension HoldEffect {
    init(_ core: CoreHoldEffect) {
        switch core {
        case .beginCapture(let mode): self = .beginCapture(VoiceCaptureMode(mode))
        case .endCapture: self = .endCapture
        case .cancelCapture: self = .cancelCapture
        case .deliver(let intent): self = .deliver(Intent(intent))
        case .ignore: self = .ignore
        }
    }
}

fileprivate extension ConnectedController {
    init(_ core: CoreConnectedController) {
        self.init(id: core.id, profileID: core.profileId, displayName: core.displayName)
    }

    var core: CoreConnectedController {
        CoreConnectedController(id: id, profileId: profileID, displayName: displayName)
    }
}

/// Internal rather than fileprivate: the config record carries mappings too
/// (CoreBridgeConfig.swift).
extension Dictionary where Key == String, Value == DeviceMapping {
    init(core: [String: [String: CoreAction]]) {
        self = core.mapValues { $0.mapValues(Action.init) }
    }

    var core: [String: [String: CoreAction]] {
        mapValues { $0.mapValues(\.core) }
    }
}
