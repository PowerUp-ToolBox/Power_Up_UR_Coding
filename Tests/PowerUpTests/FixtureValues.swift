import Foundation
@testable import PowerUp

/// Any JSON value, as a shared fixture writes it. The `mapping/` tables hand
/// arbitrary JSON to the config decoder (an action stored for one control may
/// be a string, null, an array…), so the input cannot be a typed struct.
/// Integers and doubles stay apart so a value written back re-encodes as it
/// was read.
enum FixtureJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([FixtureJSON])
    case object([String: FixtureJSON])

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Int64.self) { self = .integer(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([FixtureJSON].self) { self = .array(value); return }
            if let value = try? container.decode([String: FixtureJSON].self) { self = .object(value); return }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Not a JSON value"))
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

    subscript(key: String) -> FixtureJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// A descriptor the fixture cannot be read with: the test fails naming it
/// instead of guessing.
struct FixtureValueError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Value descriptors (Tests/Fixtures/README.md, `mapping/`)

extension Action {
    /// One value of every case, in declaration order. `fixtureName` is an
    /// exhaustive switch, so a new case fails to compile there; the coverage
    /// checks in `MappingFixtureTests` then catch a case missing here.
    static let fixtureCases: [Action] = [
        .none, .pushToTalk, .sendPrompt("Continue"), .approve, .reject, .interrupt,
        .stopSpeaking, .replayLastReply, .toggleTTS, .newSession, .showWindow,
        .cycleModel, .cycleEffort, .cyclePermissionMode, .cycleProject, .cycleFocus,
        .pushToTalkDraft, .sendDraft, .toggleControlMode,
    ]

    /// The Swift case name, which is also the key the config writer stores.
    var fixtureName: String {
        switch self {
        case .none: return "none"
        case .pushToTalk: return "pushToTalk"
        case .sendPrompt: return "sendPrompt"
        case .approve: return "approve"
        case .reject: return "reject"
        case .interrupt: return "interrupt"
        case .stopSpeaking: return "stopSpeaking"
        case .replayLastReply: return "replayLastReply"
        case .toggleTTS: return "toggleTTS"
        case .newSession: return "newSession"
        case .showWindow: return "showWindow"
        case .cycleModel: return "cycleModel"
        case .cycleEffort: return "cycleEffort"
        case .cyclePermissionMode: return "cyclePermissionMode"
        case .cycleProject: return "cycleProject"
        case .cycleFocus: return "cycleFocus"
        case .pushToTalkDraft: return "pushToTalkDraft"
        case .sendDraft: return "sendDraft"
        case .toggleControlMode: return "toggleControlMode"
        }
    }

    /// `{"case": <name>}`, plus `"prompt"` for sendPrompt.
    init(fixture descriptor: FixtureJSON) throws {
        guard let name = descriptor["case"]?.stringValue else {
            throw FixtureValueError(description: "not an action descriptor: \(descriptor)")
        }
        if name == "sendPrompt" {
            guard let prompt = descriptor["prompt"]?.stringValue else {
                throw FixtureValueError(description: "sendPrompt descriptor without a prompt: \(descriptor)")
            }
            self = .sendPrompt(prompt)
            return
        }
        guard let action = Action.fixtureCases.first(where: { $0.fixtureName == name }) else {
            throw FixtureValueError(description: "unknown action case \(name)")
        }
        self = action
    }

    var fixtureDescriptor: FixtureJSON {
        if case .sendPrompt(let prompt) = self {
            return .object(["case": .string("sendPrompt"), "prompt": .string(prompt)])
        }
        return .object(["case": .string(fixtureName)])
    }
}

extension Intent {
    /// `{"intent": <Swift case name>}`, plus `"mode"` for beginVoiceCapture
    /// and `"prompt"` for sendPrompt. Exhaustive, so a new case is a compile
    /// error here rather than a silently unnamed value.
    var fixtureDescriptor: FixtureJSON {
        let name: String
        switch self {
        case .beginVoiceCapture(let mode):
            return .object(["intent": .string("beginVoiceCapture"), "mode": .string(mode.rawValue)])
        case .sendPrompt(let prompt):
            return .object(["intent": .string("sendPrompt"), "prompt": .string(prompt)])
        case .endVoiceCapture: name = "endVoiceCapture"
        case .sendDraft: name = "sendDraft"
        case .approve: name = "approve"
        case .reject: name = "reject"
        case .interrupt: name = "interrupt"
        case .stopSpeaking: name = "stopSpeaking"
        case .replayLastReply: name = "replayLastReply"
        case .toggleTTS: name = "toggleTTS"
        case .newSession: name = "newSession"
        case .showWindow: name = "showWindow"
        case .cycleModel: name = "cycleModel"
        case .cycleEffort: name = "cycleEffort"
        case .cyclePermissionMode: name = "cyclePermissionMode"
        case .cycleProject: name = "cycleProject"
        case .cycleFocus: name = "cycleFocus"
        case .toggleControlMode: name = "toggleControlMode"
        }
        return .object(["intent": .string(name)])
    }
}

extension ControlPhase {
    init(fixture name: String) throws {
        switch name {
        case "began": self = .began
        case "ended": self = .ended
        default: throw FixtureValueError(description: "unknown phase \(name)")
        }
    }
}

extension FixtureJSON {
    /// The JSON an `Encodable` value writes, read back as a fixture value so
    /// it compares with a table's expected object regardless of key order.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(FixtureJSON.self, from: JSONEncoder().encode(value))
    }
}

/// Mappings descriptors: `{profileID: {controlID: <action descriptor>}}`, or
/// the string `"defaults"` for the shipped default mappings.
enum FixtureMappings {
    static func deviceMappings(_ descriptor: FixtureJSON) throws -> [String: DeviceMapping] {
        if descriptor == .string("defaults") { return AppConfig.defaultDeviceMappings() }
        guard case .object(let profiles) = descriptor else {
            throw FixtureValueError(description: "not a mappings descriptor: \(descriptor)")
        }
        return try profiles.mapValues { profile in
            guard case .object(let controls) = profile else {
                throw FixtureValueError(description: "not a profile mapping: \(profile)")
            }
            return try controls.mapValues { try Action(fixture: $0) }
        }
    }

    static func descriptor(_ mappings: [String: DeviceMapping]) -> FixtureJSON {
        .object(mappings.mapValues { .object($0.mapValues(\.fixtureDescriptor)) })
    }
}
