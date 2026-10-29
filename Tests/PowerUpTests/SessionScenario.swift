import Foundation
@testable import PowerUp

// Session scenario fixtures (epic #92, ticket #115).
//
// A scenario is one JSON document in `Tests/Fixtures/session/`: a starting
// configuration, an ordered script of harness events, intents and public
// AppState calls, and the observable facts expected afterwards. The format is
// documented in `Tests/Fixtures/README.md`; the Rust core (stage 2.3) reads the
// same files, so the format stays plain JSON with no Swift-specific shapes.
//
// The parser is strict: an unknown key, a missing required key or a value of
// the wrong type is a load error naming the file and the JSON path, so a typo
// in a fixture can never silently skip a check.

// MARK: - JSON value

/// A parsed JSON value, comparable and printable in fixture terms.
enum ScenarioJSON: Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ScenarioJSON])
    case object([String: ScenarioJSON])

    init(parsing data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = ScenarioJSON(any)
    }

    init(_ any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(ScenarioJSON.init))
        case let object as [String: Any]:
            self = .object(object.mapValues(ScenarioJSON.init))
        default:
            self = .string(String(describing: any))
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let values): return "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { "\"\($0)\": \(fields[$0]?.description ?? "null")" }
                .joined(separator: ", ") + "}"
        }
    }

    subscript(key: String) -> ScenarioJSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }
}

// MARK: - Scenario

struct ScenarioLoadError: Error, CustomStringConvertible {
    let description: String
}

/// One session scenario, parsed from a fixture file.
struct SessionScenario {

    /// The configuration subset a scenario may set; everything else is the
    /// default config (with TTS off so a test run makes no sound).
    struct Config {
        var harnessKind: String?
        /// The ACP agent and its command line. A scenario that selects the
        /// ACP harness must use the "custom" agent, so the command never
        /// depends on what is installed on the machine running the tests.
        var acpAgent: String?
        var acpCustomCommand: String?
        var model: String?
        var effort: String?
        var permissionMode: String?
        var controlMode: String?
        /// True: `projectDir` is a fresh folder in the sandbox (written
        /// `$project` in expectations). False: no project chosen.
        var project = false
        var lastSessionID: String?
        /// True: a (simulated) pad is connected before AppState is built.
        var controllerConnected = false
    }

    enum Call: Equatable {
        case startSessionIfNeeded
        case newSession
        case sendUserText(String)
        case interruptClaude
        case answerPendingPermission(allow: Bool)
        /// The Settings recents list's Switch button. The folder is named
        /// (`<sandbox>/<name>`, written `$<name>` in expectations); the runner
        /// creates it when needed. `"project"` is the folder `config.project`
        /// makes.
        case switchProject(String)
    }

    /// A Settings window edit: the harness picker. Unset fields stay as
    /// they are.
    struct SettingsChange {
        var harnessKind: String?
        var acpAgent: String?
        var acpCustomCommand: String?
    }

    /// Which scripted adapter a harness event comes from.
    enum Adapter: String {
        case claude, acp
    }

    enum Action {
        case call(Call)
        case intent(Intent)
        case settings(SettingsChange)
        /// nil adapter: the one the current config selects.
        case harnessEvent(HarnessEvent, from: Adapter?)
        /// A Claude Code hook as the remote listener delivers it (remote mode).
        case hookEvent(RemoteHookEvent)
        /// Moves the scripted clock forward this many seconds, running the
        /// expiry checks that fall due on the way. Never a sleep.
        case advanceClock(TimeInterval)
    }

    struct Step {
        let number: Int            // 1-based, as printed in failures
        let action: Action
        /// The step must leave every observable fact unchanged.
        let expectNoChange: Bool
        /// False: the next step runs straight after this one, before AppState
        /// gets the main-actor turns that run work it deferred (a Task it
        /// spawned to hop off an event delivery). Models input that was
        /// already on its way when the step happened.
        let settle: Bool
        /// Facts checked right after this step (a checkpoint), in the same
        /// terms as the scenario's final `expect`.
        let expect: Expectations?
        let label: String          // the step's JSON, for failure messages
    }

    /// Facts checked after the script. nil = not checked.
    struct Expectations {
        var harnessCalls: [[String: ScenarioJSON]]?
        var transcript: [[String: ScenarioJSON]]?
        var errorShown: Bool?
        /// `.some(nil)` asserts no session id is stored.
        var lastSessionID: String??
        var pendingPermission: Bool?
        /// The pending request is a destructive one that a first Approve has
        /// armed (the banner reads "Confirm"). False when nothing is pending.
        var pendingPermissionArmed: Bool?
        var status: String?
        /// What the harness last reported as its model (the session's
        /// `liveModel`). `.some(nil)` asserts nothing has been reported.
        var liveModel: String??
        /// The model chip's label.
        var modelChip: String?
        /// Remote mode: a remote turn drives the working state (the focused
        /// session's, when a focus is set).
        var remoteTurnActive: Bool?
        /// Remote mode: the focused session id. `.some(nil)` asserts no focus
        /// (every session is heard).
        var remoteFocus: String??
        /// Everything remote mode typed or pressed in the remote session, in
        /// order and with an exact count.
        var injectorCalls: [[String: ScenarioJSON]]?
        /// The configured permission mode.
        var permissionMode: String?
        /// The session id the running harness owns (sent to protocol clients
        /// as `sessionID`). `.some(nil)` asserts there is none.
        var liveSessionID: String??
        /// The reply Replay Last Reply speaks. `.some(nil)` asserts there is
        /// none yet.
        var lastAssistantReply: String??
    }

    static let formatVersion = 1

    let file: String
    let name: String
    let config: Config
    let script: [Step]
    let expect: Expectations

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let json: ScenarioJSON
        do {
            json = try ScenarioJSON(parsing: data)
        } catch {
            throw ScenarioLoadError(description: "\(url.lastPathComponent): not valid JSON (\(error.localizedDescription))")
        }
        try self.init(json: json, file: url.lastPathComponent)
    }

    init(json: ScenarioJSON, file: String) throws {
        self.file = file
        var reader = Reader(file: file)
        let root = try reader.object(json, at: "$", allowed: [
            "formatVersion", "name", "description", "reason", "source", "verifiedBy",
            "config", "script", "expect",
        ])
        let version = try reader.int(root["formatVersion"], at: "$.formatVersion")
        guard version == Self.formatVersion else {
            throw reader.error("$.formatVersion", "this runner reads format \(Self.formatVersion), the file is format \(version)")
        }
        name = try reader.string(root["name"], at: "$.name")
        _ = try reader.string(root["description"], at: "$.description")
        _ = try reader.string(root["reason"], at: "$.reason")
        if let source = root["source"] { _ = try reader.string(source, at: "$.source") }
        _ = try reader.stringArray(root["verifiedBy"], at: "$.verifiedBy")

        config = try Self.parseConfig(root["config"], reader: &reader)

        guard case .array(let steps)? = root["script"], !steps.isEmpty else {
            throw reader.error("$.script", "must be a non-empty array of steps")
        }
        script = try steps.enumerated().map { index, step in
            try Self.parseStep(step, number: index + 1, reader: &reader)
        }
        try Self.checkACPAgents(config: config, script: script, reader: reader)
        if let last = script.last, !last.settle {
            throw reader.error("$.script[\(last.number - 1)].settle",
                               "the last step has no next step to run before deferred work")
        }
        expect = try Self.parseExpectations(root["expect"], at: "$.expect", reader: &reader)
    }

    // MARK: Parsing

    private static func parseConfig(_ json: ScenarioJSON?, reader: inout Reader) throws -> Config {
        guard let json else { return Config() }
        let fields = try reader.object(json, at: "$.config", allowed: [
            "harnessKind", "acpAgent", "acpCustomCommand", "model", "effort", "permissionMode", "controlMode",
            "project", "lastSessionID", "controllerConnected",
        ])
        var config = Config()
        config.harnessKind = try reader.harnessKind(fields["harnessKind"], at: "$.config.harnessKind")
        config.acpAgent = try reader.optionalString(fields["acpAgent"], at: "$.config.acpAgent")
        config.acpCustomCommand = try reader.optionalString(fields["acpCustomCommand"], at: "$.config.acpCustomCommand")
        config.model = try reader.optionalString(fields["model"], at: "$.config.model")
        config.effort = try reader.optionalString(fields["effort"], at: "$.config.effort")
        config.permissionMode = try reader.optionalString(fields["permissionMode"], at: "$.config.permissionMode")
        config.controlMode = try reader.optionalString(fields["controlMode"], at: "$.config.controlMode")
        config.project = try reader.optionalBool(fields["project"], at: "$.config.project") ?? false
        config.lastSessionID = try reader.optionalString(fields["lastSessionID"], at: "$.config.lastSessionID")
        config.controllerConnected = try reader.optionalBool(fields["controllerConnected"],
                                                            at: "$.config.controllerConnected") ?? false
        return config
    }

    private static func parseStep(_ json: ScenarioJSON, number: Int, reader: inout Reader) throws -> Step {
        let path = "$.script[\(number - 1)]"
        let fields = try reader.object(json, at: path, allowed: [
            "call", "intent", "settings", "harnessEvent", "hookEvent", "advanceClock", "text", "allow",
            "project", "adapter", "reason", "expectNoChange", "settle", "expect",
        ])
        if let reason = fields["reason"] { _ = try reader.string(reason, at: "\(path).reason") }
        let expectNoChange = try reader.optionalBool(fields["expectNoChange"], at: "\(path).expectNoChange") ?? false
        let settle = try reader.optionalBool(fields["settle"], at: "\(path).settle") ?? true
        let checkpoint = try fields["expect"].map {
            try parseExpectations($0, at: "\(path).expect", reader: &reader)
        }
        let kinds = ["call", "intent", "settings", "harnessEvent", "hookEvent", "advanceClock"].filter { fields[$0] != nil }
        guard kinds.count == 1 else {
            throw reader.error(path, "a step has exactly one of \"call\", \"intent\", \"settings\", "
                               + "\"harnessEvent\", \"hookEvent\" or \"advanceClock\"")
        }
        let text = try reader.optionalString(fields["text"], at: "\(path).text")
        let allow = try reader.optionalBool(fields["allow"], at: "\(path).allow")
        let project = try reader.optionalString(fields["project"], at: "\(path).project")
        if fields["harnessEvent"] == nil, fields["adapter"] != nil {
            throw reader.error("\(path).adapter", "only a harnessEvent step names an adapter")
        }
        if project != nil, fields["call"] != .string("switchProject") {
            throw reader.error("\(path).project", "not used by this step")
        }

        func unused(_ key: String, _ value: Any?) throws {
            if value != nil { throw reader.error("\(path).\(key)", "not used by this step") }
        }

        let action: Action
        if let call = fields["call"] {
            let name = try reader.string(call, at: "\(path).call")
            switch name {
            case "startSessionIfNeeded":
                try unused("text", text); try unused("allow", allow)
                action = .call(.startSessionIfNeeded)
            case "newSession":
                try unused("text", text); try unused("allow", allow)
                action = .call(.newSession)
            case "interruptClaude":
                try unused("text", text); try unused("allow", allow)
                action = .call(.interruptClaude)
            case "sendUserText":
                guard let text else { throw reader.error("\(path).text", "sendUserText needs \"text\"") }
                try unused("allow", allow)
                action = .call(.sendUserText(text))
            case "answerPendingPermission":
                guard let allow else { throw reader.error("\(path).allow", "answerPendingPermission needs \"allow\"") }
                try unused("text", text)
                action = .call(.answerPendingPermission(allow: allow))
            case "switchProject":
                guard let project else { throw reader.error("\(path).project", "switchProject needs \"project\"") }
                guard project.range(of: "^[a-z][A-Za-z0-9-]*$", options: .regularExpression) != nil else {
                    throw reader.error("\(path).project", "a folder name: a lowercase letter, then letters, digits or \"-\"")
                }
                try unused("text", text); try unused("allow", allow)
                action = .call(.switchProject(project))
            default:
                throw reader.error("\(path).call", "unknown call \"\(name)\"")
            }
        } else if let intent = fields["intent"] {
            let name = try reader.string(intent, at: "\(path).intent")
            try unused("allow", allow)
            // The protocol vocabulary (docs/protocol.md) is the intent names a
            // non-pad source may send. Opening a window has no place in a test;
            // voice capture belongs to the speech-lifecycle suites (1.4).
            guard name != "showWindow",
                  let parsed = IntentMapper.intent(forProtocolName: name, text: text) else {
                throw reader.error("\(path).intent", "unknown or unsupported intent \"\(name)\"")
            }
            if name != "sendPrompt" { try unused("text", text) }
            action = .intent(parsed)
        } else if let settings = fields["settings"] {
            try unused("text", text); try unused("allow", allow)
            let change = try reader.object(settings, at: "\(path).settings",
                                           allowed: ["harnessKind", "acpAgent", "acpCustomCommand"])
            guard !change.isEmpty else { throw reader.error("\(path).settings", "changes nothing") }
            action = .settings(SettingsChange(
                harnessKind: try reader.harnessKind(change["harnessKind"], at: "\(path).settings.harnessKind"),
                acpAgent: try reader.optionalString(change["acpAgent"], at: "\(path).settings.acpAgent"),
                acpCustomCommand: try reader.optionalString(change["acpCustomCommand"],
                                                            at: "\(path).settings.acpCustomCommand")))
        } else if let hook = fields["hookEvent"] {
            try unused("text", text); try unused("allow", allow)
            action = .hookEvent(try parseHookEvent(hook, at: "\(path).hookEvent", reader: &reader))
        } else if let seconds = fields["advanceClock"] {
            try unused("text", text); try unused("allow", allow)
            action = .advanceClock(try reader.seconds(seconds, at: "\(path).advanceClock"))
        } else {
            try unused("text", text); try unused("allow", allow)
            var adapter: Adapter?
            if let name = try reader.optionalString(fields["adapter"], at: "\(path).adapter") {
                guard let parsed = Adapter(rawValue: name) else {
                    throw reader.error("\(path).adapter", "\"claude\" or \"acp\"")
                }
                adapter = parsed
            }
            action = .harnessEvent(try parseEvent(fields["harnessEvent"], at: "\(path).harnessEvent", reader: &reader),
                                   from: adapter)
        }
        return Step(number: number, action: action, expectNoChange: expectNoChange,
                    settle: settle, expect: checkpoint, label: label(of: json))
    }

    /// The step as printed in failures: its JSON without the checkpoint
    /// block, which would only repeat what the failure already names.
    private static func label(of json: ScenarioJSON) -> String {
        guard case .object(var fields) = json else { return json.description }
        fields["expect"] = nil
        return ScenarioJSON.object(fields).description
    }

    /// The normalized harness vocabulary (`HarnessEvent`), one object per
    /// event, tagged by `type`, fields named as in Swift.
    private static func parseEvent(_ json: ScenarioJSON?, at path: String, reader: inout Reader) throws -> HarnessEvent {
        guard let json, case .object(let fields) = json, let typeJSON = fields["type"] else {
            throw reader.error(path, "must be an object with a \"type\"")
        }
        let type = try reader.string(typeJSON, at: "\(path).type")
        func keys(_ allowed: String...) throws -> [String: ScenarioJSON] {
            try reader.object(json, at: path, allowed: Set(allowed + ["type"]))
        }
        switch type {
        case "sessionReady":
            let f = try keys("sessionID", "model")
            return .sessionReady(sessionID: try reader.string(f["sessionID"], at: "\(path).sessionID"),
                                 model: try reader.string(f["model"], at: "\(path).model"))
        case "replyDelta":
            let f = try keys("text")
            return .replyDelta(try reader.string(f["text"], at: "\(path).text"))
        case "reply":
            let f = try keys("text")
            return .reply(try reader.string(f["text"], at: "\(path).text"))
        case "toolUse":
            let f = try keys("name", "detail")
            return .toolUse(name: try reader.string(f["name"], at: "\(path).name"),
                            detail: try reader.string(f["detail"], at: "\(path).detail"))
        case "turnCompleted":
            let f = try keys("resultText", "costUSD", "isError", "detail")
            return .turnCompleted(resultText: try reader.optionalString(f["resultText"], at: "\(path).resultText"),
                                  costUSD: try reader.optionalDouble(f["costUSD"], at: "\(path).costUSD"),
                                  isError: try reader.bool(f["isError"], at: "\(path).isError"),
                                  detail: try reader.string(f["detail"], at: "\(path).detail"))
        case "controlResult":
            let f = try keys("action", "ok", "detail", "value")
            return .controlResult(action: try reader.string(f["action"], at: "\(path).action"),
                                  ok: try reader.bool(f["ok"], at: "\(path).ok"),
                                  detail: try reader.string(f["detail"], at: "\(path).detail"),
                                  value: try reader.optionalString(f["value"], at: "\(path).value"))
        case "permissionRequest":
            let f = try keys("id", "name", "kind", "detail")
            return .permissionRequest(id: try reader.string(f["id"], at: "\(path).id"),
                                      name: try reader.string(f["name"], at: "\(path).name"),
                                      kind: try reader.string(f["kind"], at: "\(path).kind"),
                                      detail: try reader.string(f["detail"], at: "\(path).detail"))
        case "notification":
            let f = try keys("message")
            return .notification(try reader.string(f["message"], at: "\(path).message"))
        case "runtimeError":
            let f = try keys("message")
            return .runtimeError(try reader.string(f["message"], at: "\(path).message"))
        case "ended":
            let f = try keys("exitCode")
            return .ended(exitCode: Int32(try reader.int(f["exitCode"], at: "\(path).exitCode")))
        default:
            throw reader.error("\(path).type", "unknown harness event \"\(type)\"")
        }
    }

    /// A Claude Code hook as `RemoteListener` normalizes it, tagged by
    /// `type` (the `RemoteHookEvent.Kind` case), with `sessionID`, `cwd` and
    /// `text` (prompt / reply / message / tool name / end reason) optional.
    private static func parseHookEvent(_ json: ScenarioJSON, at path: String,
                                       reader: inout Reader) throws -> RemoteHookEvent {
        let fields = try reader.object(json, at: path, allowed: ["type", "sessionID", "cwd", "text"])
        let type = try reader.string(fields["type"], at: "\(path).type")
        let kinds: [String: RemoteHookEvent.Kind] = [
            "userPromptSubmit": .userPromptSubmit, "postToolUse": .postToolUse, "notification": .notification,
            "stop": .stop, "sessionEnd": .sessionEnd,
        ]
        guard let kind = kinds[type] else {
            throw reader.error("\(path).type", "unknown hook event \"\(type)\" (allowed: \(kinds.keys.sorted().joined(separator: ", ")))")
        }
        return RemoteHookEvent(kind: kind,
                               text: try reader.optionalString(fields["text"], at: "\(path).text"),
                               sessionID: try reader.optionalString(fields["sessionID"], at: "\(path).sessionID"),
                               cwd: try reader.optionalString(fields["cwd"], at: "\(path).cwd"))
    }

    /// Whenever the script selects the ACP harness, the agent must be the
    /// "custom" one: the other agents' commands are looked up on this
    /// machine's disk, which would make the recorded `agentCommand` vary.
    private static func checkACPAgents(config: Config, script: [Step], reader: Reader) throws {
        var kind = config.harnessKind ?? "claude"
        var agent = config.acpAgent ?? AppConfig.defaultConfig().acpAgent
        func check(_ path: String) throws {
            if kind == "acp", agent != "custom" {
                throw reader.error(path, "the ACP harness needs \"acpAgent\": \"custom\" (with \"acpCustomCommand\"), "
                                   + "so the agent command never depends on this machine")
            }
        }
        try check("$.config")
        for step in script {
            guard case .settings(let change) = step.action else { continue }
            if let value = change.harnessKind { kind = value }
            if let value = change.acpAgent { agent = value }
            try check("$.script[\(step.number - 1)].settings")
        }
    }

    static let statusNames = ["noController", "idle", "listening", "thinking", "speaking"]
    static let transcriptKinds = ["user", "assistant", "tool", "system", "error"]
    static let callTypes: [String: Set<String>] = [
        "start": ["projectDir", "model", "permissionMode", "effort", "resumeSessionID",
                  "binaryPathOverride", "agentCommand"],
        "send": ["text"],
        "interrupt": [],
        "setModel": ["model"],
        "setPermissionMode": ["mode"],
        "respondToPermission": ["id", "allow"],
        "stop": [],
    ]
    static let injectorCallTypes: [String: Set<String>] = [
        "text": ["text", "submit"],
        "key": ["key"],
    ]

    private static func parseExpectations(_ json: ScenarioJSON?, at root: String,
                                          reader: inout Reader) throws -> Expectations {
        guard let json else { throw reader.error(root, "missing") }
        let fields = try reader.object(json, at: root, allowed: [
            "harnessCalls", "transcript", "errorShown", "lastSessionID", "pendingPermission",
            "pendingPermissionArmed", "status", "liveModel", "modelChip",
            "remoteTurnActive", "remoteFocus", "injectorCalls", "permissionMode", "liveSessionID",
            "lastAssistantReply",
        ])
        guard !fields.isEmpty else { throw reader.error(root, "expects nothing") }
        var expect = Expectations()

        if let calls = fields["harnessCalls"] {
            guard case .array(let items) = calls else { throw reader.error("\(root).harnessCalls", "must be an array") }
            expect.harnessCalls = try items.enumerated().map { index, item in
                let path = "\(root).harnessCalls[\(index)]"
                guard case .object(let object) = item, let typeJSON = object["type"] else {
                    throw reader.error(path, "must be an object with a \"type\"")
                }
                let type = try reader.string(typeJSON, at: "\(path).type")
                guard let allowed = callTypes[type] else {
                    throw reader.error("\(path).type", "unknown harness call \"\(type)\"")
                }
                let call = try reader.object(item, at: path, allowed: allowed.union(["type", "adapter"]))
                if let adapter = call["adapter"] {
                    let name = try reader.string(adapter, at: "\(path).adapter")
                    guard Adapter(rawValue: name) != nil else { throw reader.error("\(path).adapter", "\"claude\" or \"acp\"") }
                }
                return call
            }
        }
        if let transcript = fields["transcript"] {
            guard case .array(let items) = transcript else { throw reader.error("\(root).transcript", "must be an array") }
            expect.transcript = try items.enumerated().map { index, item in
                let path = "\(root).transcript[\(index)]"
                let object = try reader.object(item, at: path, allowed: ["kind", "text"])
                let kind = try reader.string(object["kind"], at: "\(path).kind")
                guard transcriptKinds.contains(kind) else {
                    throw reader.error("\(path).kind", "unknown entry kind \"\(kind)\"")
                }
                if let text = object["text"] { _ = try reader.string(text, at: "\(path).text") }
                return object
            }
        }
        expect.errorShown = try reader.optionalBool(fields["errorShown"], at: "\(root).errorShown")
        if let id = fields["lastSessionID"] {
            expect.lastSessionID = .some(try reader.optionalString(id, at: "\(root).lastSessionID"))
        }
        expect.pendingPermission = try reader.optionalBool(fields["pendingPermission"], at: "\(root).pendingPermission")
        expect.pendingPermissionArmed = try reader.optionalBool(fields["pendingPermissionArmed"],
                                                                at: "\(root).pendingPermissionArmed")
        if let status = fields["status"] {
            let name = try reader.string(status, at: "\(root).status")
            guard statusNames.contains(name) else { throw reader.error("\(root).status", "unknown status \"\(name)\"") }
            expect.status = name
        }
        if let model = fields["liveModel"] {
            expect.liveModel = .some(try reader.optionalString(model, at: "\(root).liveModel"))
        }
        expect.modelChip = try reader.optionalString(fields["modelChip"], at: "\(root).modelChip")
        expect.remoteTurnActive = try reader.optionalBool(fields["remoteTurnActive"], at: "\(root).remoteTurnActive")
        if let focus = fields["remoteFocus"] {
            expect.remoteFocus = .some(try reader.optionalString(focus, at: "\(root).remoteFocus"))
        }
        expect.permissionMode = try reader.optionalString(fields["permissionMode"], at: "\(root).permissionMode")
        if let id = fields["liveSessionID"] {
            expect.liveSessionID = .some(try reader.optionalString(id, at: "\(root).liveSessionID"))
        }
        if let reply = fields["lastAssistantReply"] {
            expect.lastAssistantReply = .some(try reader.optionalString(reply, at: "\(root).lastAssistantReply"))
        }
        if let calls = fields["injectorCalls"] {
            guard case .array(let items) = calls else { throw reader.error("\(root).injectorCalls", "must be an array") }
            expect.injectorCalls = try items.enumerated().map { index, item in
                let path = "\(root).injectorCalls[\(index)]"
                guard case .object(let object) = item, let typeJSON = object["type"] else {
                    throw reader.error(path, "must be an object with a \"type\"")
                }
                let type = try reader.string(typeJSON, at: "\(path).type")
                guard let allowed = injectorCallTypes[type] else {
                    throw reader.error("\(path).type", "unknown injector call \"\(type)\"")
                }
                return try reader.object(item, at: path, allowed: allowed.union(["type"]))
            }
        }
        return expect
    }

    /// Typed, path-aware access to the parsed JSON.
    private struct Reader {
        let file: String

        func error(_ path: String, _ message: String) -> ScenarioLoadError {
            ScenarioLoadError(description: "\(file) \(path): \(message)")
        }

        func object(_ json: ScenarioJSON?, at path: String, allowed: Set<String>) throws -> [String: ScenarioJSON] {
            guard case .object(let fields)? = json else { throw error(path, "must be an object") }
            if let unknown = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw error("\(path).\(unknown)", "unknown key (allowed: \(allowed.sorted().joined(separator: ", ")))")
            }
            return fields
        }

        func string(_ json: ScenarioJSON?, at path: String) throws -> String {
            guard case .string(let value)? = json else { throw error(path, "must be a string") }
            return value
        }

        func optionalString(_ json: ScenarioJSON?, at path: String) throws -> String? {
            guard let json, json != .null else { return nil }
            return try string(json, at: path)
        }

        /// An optional harness kind, one of `AppConfig.harnessKindOptions`.
        func harnessKind(_ json: ScenarioJSON?, at path: String) throws -> String? {
            guard let kind = try optionalString(json, at: path) else { return nil }
            guard AppConfig.harnessKindOptions.contains(kind) else {
                throw error(path, "unknown harness kind \"\(kind)\" (allowed: \(AppConfig.harnessKindOptions.joined(separator: ", ")))")
            }
            return kind
        }

        func stringArray(_ json: ScenarioJSON?, at path: String) throws -> [String] {
            guard case .array(let items)? = json else { throw error(path, "must be an array of strings") }
            return try items.enumerated().map { try string($1, at: "\(path)[\($0)]") }
        }

        func bool(_ json: ScenarioJSON?, at path: String) throws -> Bool {
            guard case .bool(let value)? = json else { throw error(path, "must be true or false") }
            return value
        }

        func optionalBool(_ json: ScenarioJSON?, at path: String) throws -> Bool? {
            guard let json else { return nil }
            return try bool(json, at: path)
        }

        func int(_ json: ScenarioJSON?, at path: String) throws -> Int {
            guard case .number(let value)? = json, value.rounded() == value, abs(value) <= Double(Int32.max) else {
                throw error(path, "must be an integer")
            }
            return Int(value)
        }

        /// A finite, non-negative number of seconds.
        func seconds(_ json: ScenarioJSON?, at path: String) throws -> TimeInterval {
            guard case .number(let value)? = json, value.isFinite, value >= 0 else {
                throw error(path, "must be a number of seconds, zero or more")
            }
            return value
        }

        func optionalDouble(_ json: ScenarioJSON?, at path: String) throws -> Double? {
            guard let json, json != .null else { return nil }
            guard case .number(let value) = json else { throw error(path, "must be a number") }
            return value
        }
    }
}

// MARK: - Runner

/// Plays a scenario through the AppState seam (#110) with two scripted
/// `FakeHarnessAdapter`s (#111), one standing in for the built-in Claude
/// adapter and one for the ACP adapter (#119), a `RecordingInjector` standing
/// in for the remote session and a `ManualRemoteTurnClock` (#118), and
/// returns every mismatch, each prefixed with the scenario name. An empty
/// result means the scenario passed.
@MainActor
enum SessionScenarioRunner {

    /// `Tests/Fixtures/<area>/` at the repository root, found relative to
    /// this source file (SwiftPM does not accept resources outside a target).
    static func fixturesDirectory(_ area: String, filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()   // PowerUpTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(area, isDirectory: true)
    }

    /// Every `*.json` scenario in `Tests/Fixtures/session/`, sorted by file name.
    static func scenarioFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixturesDirectory("session"),
                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Main-actor turns given to AppState after each step, so the Tasks it
    /// spawns from a handler (the deferred effort restart, coalesced status
    /// refreshes) run before the next step. A bounded yield, never a sleep.
    static let settleTurns = 50

    static func run(_ scenario: SessionScenario) async -> [String] {
        let prefix = "[\(scenario.name)] (\(scenario.file))"
        let env: AppStateTestEnvironment
        do {
            env = try AppStateTestEnvironment()
        } catch {
            return ["\(prefix) could not build the test environment: \(error)"]
        }
        defer { env.tearDown() }

        // Starting configuration.
        let projectURL = env.directory.appendingPathComponent("project", isDirectory: true)
        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false           // and the TTS below only records
        if let value = scenario.config.harnessKind { config.harnessKind = value }
        if let value = scenario.config.acpAgent { config.acpAgent = value }
        if let value = scenario.config.acpCustomCommand { config.acpCustomCommand = value }
        if let value = scenario.config.model { config.model = value }
        if let value = scenario.config.effort { config.effort = value }
        if let value = scenario.config.permissionMode { config.permissionMode = value }
        if let value = scenario.config.controlMode { config.controlMode = value }
        config.lastSessionID = scenario.config.lastSessionID
        if scenario.config.project {
            do {
                try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
                config.projectDir = projectURL.path
            } catch {
                return ["\(prefix) could not create the project folder: \(error)"]
            }
        } else {
            config.projectDir = nil
        }
        do {
            try ConfigStore.encode(config).write(to: env.configURL, options: .atomic)
        } catch {
            return ["\(prefix) could not write the starting config: \(error)"]
        }

        let controller = ControllerService()
        if scenario.config.controllerConnected { controller.simulateConnect() }
        // One fake per harness kind, as the app has one adapter per kind; the
        // config's harness kind picks between them. Each reports the
        // capabilities of the adapter it stands in for: the built-in Claude
        // adapter switches effort by restart + resume, ACP agents have no
        // effort setting (Harness.swift defaults) and drop their session id
        // as soon as they are stopped. Both record into one ordered log.
        let harnesses = Harnesses()
        harnesses.claude.supportsEffort = true
        harnesses.acp.supportsEffort = false
        harnesses.acp.clearsSessionIDOnStop = true
        // Hooks arrive through the listener's callback; it never binds a port
        // here (the environment skips `.syncListener`). Remote mode types into
        // the environment's recording injector, never a real terminal.
        let listener = RemoteListener()
        let clock = ManualRemoteTurnClock()
        let injector = env.injector
        // `ttsEnabled = false` alone does not keep a run silent: a replay or
        // a toggleTTS intent speaks regardless. A recording TTS never reaches
        // a synthesizer, whatever the script does.
        let tts = TTSService()
        tts.recordsOutput = true
        let app = env.makeAppState(controller: controller, tts: tts,
                                   harness: harnesses.claude, acpHarness: harnesses.acp,
                                   listener: listener, clock: clock)
        await settle()

        // Facts are measured from here: anything AppState logged while being
        // built is not part of the script.
        let transcript = TranscriptLog(baseline: app.transcript)
        harnesses.clearCalls()
        injector.clearCalls()
        let projects = ProjectFolders(sandbox: env.directory)
        func observe() -> Observation {
            observation(app, harnesses, injector, transcript: transcript, projects: projects)
        }

        var failures: [String] = []
        for step in scenario.script {
            let before = observe()
            do {
                try perform(step.action, on: app, harnesses: harnesses, listener: listener, clock: clock,
                            projects: projects)
            } catch {
                failures.append("\(prefix) step \(step.number) \(step.label) could not run: \(error)")
                break
            }
            if step.settle { await settle() }
            let after = observe()
            if step.expectNoChange, let difference = firstDifference(before, after) {
                failures.append("\(prefix) step \(step.number) \(step.label) is tagged expectNoChange "
                                + "but changed \(difference)")
            }
            if let checkpoint = step.expect {
                failures += compare(checkpoint, with: after, at: "step \(step.number) expect").map {
                    "\(prefix) \($0)"
                }
            }
        }

        let final = observe()
        failures += compare(scenario.expect, with: final).map { "\(prefix) \($0)" }
        withExtendedLifetime((app, listener, harnesses)) {}
        return failures
    }

    // MARK: Playing a step

    private static func perform(_ action: SessionScenario.Action, on app: AppState, harnesses: Harnesses,
                                listener: RemoteListener, clock: ManualRemoteTurnClock,
                                projects: ProjectFolders) throws {
        switch action {
        case .harnessEvent(let event, let adapter):
            // By default the event comes from the adapter the config selects.
            let source = adapter ?? (app.configStore.config.harnessKind == "acp" ? .acp : .claude)
            harnesses.fake(source).emit(event)
        case .settings(let change):
            // What the Settings window's harness picker writes; AppState
            // picks the change up in its derived-update pass, as in the app.
            if let value = change.harnessKind { app.configStore.config.harnessKind = value }
            if let value = change.acpAgent { app.configStore.config.acpAgent = value }
            if let value = change.acpCustomCommand { app.configStore.config.acpCustomCommand = value }
        case .hookEvent(let event):
            listener.onEvent?(RemoteHookEvent(kind: event.kind, text: event.text, sessionID: event.sessionID,
                                              cwd: try event.cwd.map(projects.path)))
        case .advanceClock(let seconds):
            clock.advance(by: seconds)
        case .intent(let intent):
            app.handle(intent)
        case .call(let call):
            switch call {
            case .startSessionIfNeeded: app.startSessionIfNeeded()
            case .newSession: app.newSession()
            case .sendUserText(let text): app.sendUserText(text)
            case .interruptClaude: app.interruptClaude()
            case .answerPendingPermission(let allow): app.answerPendingPermission(allow: allow)
            case .switchProject(let name): app.switchProject(to: try projects.folder(name).path)
            }
        }
    }

    private static func settle() async {
        for _ in 0..<settleTurns { await Task.yield() }
    }

    // MARK: Observing

    /// Everything a scenario can assert, in fixture terms.
    struct Observation {
        var harnessCalls: [[String: ScenarioJSON]]
        var transcript: [[String: ScenarioJSON]]
        var lastSessionID: String?
        var pendingPermission: Bool
        var pendingPermissionArmed: Bool
        var status: String
        var liveModel: String?
        var modelChip: String
        var remoteTurnActive: Bool
        var remoteFocus: String?
        var injectorCalls: [[String: ScenarioJSON]]
        var permissionMode: String
        var liveSessionID: String?
        var lastAssistantReply: String?
    }

    /// The two scripted adapters and their shared, ordered call log.
    @MainActor
    final class Harnesses {
        let claude = FakeHarnessAdapter()
        let acp = FakeHarnessAdapter()
        private(set) var log: [(adapter: SessionScenario.Adapter, call: FakeHarnessAdapter.Call)] = []

        init() {
            claude.onCall = { [unowned self] in self.log.append((.claude, $0)) }
            acp.onCall = { [unowned self] in self.log.append((.acp, $0)) }
        }

        func fake(_ adapter: SessionScenario.Adapter) -> FakeHarnessAdapter {
            adapter == .acp ? acp : claude
        }

        func clearCalls() {
            log.removeAll()
            claude.clearCalls()
            acp.clearCalls()
        }
    }

    /// The transcript entries that appeared during the script, in order of
    /// first appearance. A project switch replaces the window's scrollback
    /// with the new folder's stored history; entries already seen are not
    /// counted twice, but the "restored" marker on top of it is new.
    final class TranscriptLog {
        private var seen: Set<UUID>
        private(set) var entries: [[String: ScenarioJSON]] = []

        init(baseline: [TranscriptEntry]) {
            seen = Set(baseline.map(\.id))
        }

        func update(_ transcript: [TranscriptEntry]) {
            for entry in transcript where !seen.contains(entry.id) {
                seen.insert(entry.id)
                entries.append(["kind": .string(entry.kind.rawValue), "text": .string(entry.text)])
            }
        }
    }

    /// Project folders in the sandbox, by name: `<sandbox>/<name>`, written
    /// `$<name>` in expectations. `config.project` makes `project`.
    final class ProjectFolders {
        let sandbox: URL

        init(sandbox: URL) { self.sandbox = sandbox }

        func folder(_ name: String) throws -> URL {
            let url = sandbox.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// A hook's `cwd` as written in a fixture: `$<name>` is that sandbox
        /// folder, `$<name>/sub/dir` a folder below it, anything else a path.
        func path(_ written: String) throws -> String {
            guard written.hasPrefix("$") else { return written }
            let parts = written.dropFirst().split(separator: "/", maxSplits: 1)
            var url = try folder(String(parts.first ?? ""))
            if parts.count > 1 { url.appendPathComponent(String(parts[1]), isDirectory: true) }
            return url.path
        }

        /// `$<name>` for a sandbox folder, the path itself otherwise.
        func label(_ path: String) -> String {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let name = URL(fileURLWithPath: path).lastPathComponent
            return parent == sandbox.path && !name.isEmpty ? "$" + name : path
        }
    }

    private static func observation(_ app: AppState, _ harnesses: Harnesses, _ injector: RecordingInjector,
                                    transcript: TranscriptLog, projects: ProjectFolders) -> Observation {
        transcript.update(app.transcript)
        return Observation(
            harnessCalls: harnesses.log.map { entry in
                var described = describe(entry.call, projects: projects)
                described["adapter"] = .string(entry.adapter.rawValue)
                return described
            },
            transcript: transcript.entries,
            lastSessionID: app.configStore.config.lastSessionID,
            pendingPermission: app.pendingPermission != nil,
            pendingPermissionArmed: app.pendingPermission?.armed ?? false,
            status: statusName(app.status),
            liveModel: app.harnessReportedModel,
            modelChip: app.modelChipLabel,
            remoteTurnActive: app.remoteTurnActive,
            remoteFocus: app.remoteFocusSessionID,
            injectorCalls: injector.calls.map(describe),
            permissionMode: app.configStore.config.permissionMode,
            liveSessionID: app.harness.sessionID,
            lastAssistantReply: app.lastAssistantReply)
    }

    private static func describe(_ call: RecordingInjector.Call) -> [String: ScenarioJSON] {
        switch call {
        case .text(let text, let submit):
            return ["type": .string("text"), "text": .string(text), "submit": .bool(submit)]
        case .key(let key):
            let name: String
            switch key {
            case .enter: name = "enter"
            case .escape: name = "escape"
            case .shiftTab: name = "shiftTab"
            }
            return ["type": .string("key"), "key": .string(name)]
        }
    }

    private static func statusName(_ status: AppStatus) -> String {
        switch status {
        case .noController: return "noController"
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        }
    }

    private static func describe(_ call: FakeHarnessAdapter.Call, projects: ProjectFolders) -> [String: ScenarioJSON] {
        func optional(_ value: String?) -> ScenarioJSON { value.map(ScenarioJSON.string) ?? .null }
        switch call {
        case .start(let configuration):
            return [
                "type": .string("start"),
                "projectDir": .string(projects.label(configuration.projectDir.path)),
                "model": .string(configuration.model),
                "permissionMode": .string(configuration.permissionMode),
                "effort": .string(configuration.effort),
                "resumeSessionID": optional(configuration.resumeSessionID),
                "binaryPathOverride": optional(configuration.binaryPathOverride),
                "agentCommand": configuration.agentCommand.map { .array($0.map(ScenarioJSON.string)) } ?? .null,
            ]
        case .send(let text):
            return ["type": .string("send"), "text": .string(text)]
        case .interrupt:
            return ["type": .string("interrupt")]
        case .setModel(let model):
            return ["type": .string("setModel"), "model": .string(model)]
        case .setPermissionMode(let mode):
            return ["type": .string("setPermissionMode"), "mode": .string(mode)]
        case .respondToPermission(let id, let allow):
            return ["type": .string("respondToPermission"), "id": .string(id), "allow": .bool(allow)]
        case .stop:
            return ["type": .string("stop")]
        }
    }

    // MARK: Comparing

    private static func firstDifference(_ before: Observation, _ after: Observation) -> String? {
        if before.harnessCalls != after.harnessCalls {
            let added = after.harnessCalls.dropFirst(before.harnessCalls.count).map { ScenarioJSON.object($0).description }
            return "harnessCalls (recorded \(added.joined(separator: ", ")))"
        }
        if before.transcript != after.transcript {
            let added = after.transcript.dropFirst(before.transcript.count).map { ScenarioJSON.object($0).description }
            return "transcript (appended \(added.joined(separator: ", ")))"
        }
        if before.lastSessionID != after.lastSessionID {
            return "lastSessionID (\(before.lastSessionID ?? "null") → \(after.lastSessionID ?? "null"))"
        }
        if before.pendingPermission != after.pendingPermission {
            return "pendingPermission (\(before.pendingPermission) → \(after.pendingPermission))"
        }
        if before.pendingPermissionArmed != after.pendingPermissionArmed {
            return "pendingPermissionArmed (\(before.pendingPermissionArmed) → \(after.pendingPermissionArmed))"
        }
        if before.status != after.status {
            return "status (\(before.status) → \(after.status))"
        }
        if before.liveModel != after.liveModel {
            return "liveModel (\(before.liveModel ?? "null") → \(after.liveModel ?? "null"))"
        }
        if before.modelChip != after.modelChip {
            return "modelChip (\(before.modelChip) → \(after.modelChip))"
        }
        if before.remoteTurnActive != after.remoteTurnActive {
            return "remoteTurnActive (\(before.remoteTurnActive) → \(after.remoteTurnActive))"
        }
        if before.remoteFocus != after.remoteFocus {
            return "remoteFocus (\(before.remoteFocus ?? "null") → \(after.remoteFocus ?? "null"))"
        }
        if before.permissionMode != after.permissionMode {
            return "permissionMode (\(before.permissionMode) → \(after.permissionMode))"
        }
        if before.liveSessionID != after.liveSessionID {
            return "liveSessionID (\(before.liveSessionID ?? "null") → \(after.liveSessionID ?? "null"))"
        }
        if before.lastAssistantReply != after.lastAssistantReply {
            return "lastAssistantReply (\(before.lastAssistantReply ?? "null") → \(after.lastAssistantReply ?? "null"))"
        }
        if before.injectorCalls != after.injectorCalls {
            let added = after.injectorCalls.dropFirst(before.injectorCalls.count).map { ScenarioJSON.object($0).description }
            return "injectorCalls (recorded \(added.joined(separator: ", ")))"
        }
        return nil
    }

    /// Each mismatch as "<root>.<path>: expected …, got …", where root is
    /// `expect` or a step's checkpoint (`step 4 expect`). Lists compare
    /// element by element; an expected element's keys are checked and keys it
    /// leaves out are not, so a fixture states only the facts its rule is about.
    private static func compare(_ expect: SessionScenario.Expectations, with actual: Observation,
                                at root: String = "expect") -> [String] {
        var failures: [String] = []

        func compareList(_ name: String, _ expected: [[String: ScenarioJSON]], _ actual: [[String: ScenarioJSON]]) {
            for (index, wanted) in expected.enumerated() {
                guard index < actual.count else {
                    failures.append("\(root).\(name)[\(index)]: expected \(ScenarioJSON.object(wanted)), got nothing "
                                    + "(only \(actual.count) recorded)")
                    return
                }
                let got = actual[index]
                for key in wanted.keys.sorted() where wanted[key] != got[key] {
                    failures.append("\(root).\(name)[\(index)].\(key): expected \(wanted[key] ?? .null), "
                                    + "got \(got[key] ?? .null) — full entry \(ScenarioJSON.object(got))")
                    return
                }
            }
            if actual.count > expected.count {
                let extra = actual.dropFirst(expected.count).map { ScenarioJSON.object($0).description }
                failures.append("\(root).\(name): expected \(expected.count) entries, got \(actual.count); "
                                + "unexpected \(extra.joined(separator: ", "))")
            }
        }

        if let calls = expect.harnessCalls { compareList("harnessCalls", calls, actual.harnessCalls) }
        if let calls = expect.injectorCalls { compareList("injectorCalls", calls, actual.injectorCalls) }
        if let transcript = expect.transcript { compareList("transcript", transcript, actual.transcript) }
        if let errorShown = expect.errorShown {
            let shown = actual.transcript.contains { $0["kind"] == .string("error") }
            if shown != errorShown {
                failures.append("\(root).errorShown: expected \(errorShown), got \(shown)")
            }
        }
        if let wanted = expect.lastSessionID, wanted != actual.lastSessionID {
            failures.append("\(root).lastSessionID: expected \(wanted.map { "\"\($0)\"" } ?? "null"), "
                            + "got \(actual.lastSessionID.map { "\"\($0)\"" } ?? "null")")
        }
        if let pending = expect.pendingPermission, pending != actual.pendingPermission {
            failures.append("\(root).pendingPermission: expected \(pending), got \(actual.pendingPermission)")
        }
        if let armed = expect.pendingPermissionArmed, armed != actual.pendingPermissionArmed {
            failures.append("\(root).pendingPermissionArmed: expected \(armed), got \(actual.pendingPermissionArmed)")
        }
        if let status = expect.status, status != actual.status {
            failures.append("\(root).status: expected \"\(status)\", got \"\(actual.status)\"")
        }
        if let wanted = expect.liveModel, wanted != actual.liveModel {
            failures.append("\(root).liveModel: expected \(wanted.map { "\"\($0)\"" } ?? "null"), "
                            + "got \(actual.liveModel.map { "\"\($0)\"" } ?? "null")")
        }
        if let chip = expect.modelChip, chip != actual.modelChip {
            failures.append("\(root).modelChip: expected \"\(chip)\", got \"\(actual.modelChip)\"")
        }
        if let active = expect.remoteTurnActive, active != actual.remoteTurnActive {
            failures.append("\(root).remoteTurnActive: expected \(active), got \(actual.remoteTurnActive)")
        }
        if let wanted = expect.remoteFocus, wanted != actual.remoteFocus {
            failures.append("\(root).remoteFocus: expected \(wanted.map { "\"\($0)\"" } ?? "null"), "
                            + "got \(actual.remoteFocus.map { "\"\($0)\"" } ?? "null")")
        }
        if let mode = expect.permissionMode, mode != actual.permissionMode {
            failures.append("\(root).permissionMode: expected \"\(mode)\", got \"\(actual.permissionMode)\"")
        }
        if let wanted = expect.liveSessionID, wanted != actual.liveSessionID {
            failures.append("\(root).liveSessionID: expected \(wanted.map { "\"\($0)\"" } ?? "null"), "
                            + "got \(actual.liveSessionID.map { "\"\($0)\"" } ?? "null")")
        }
        if let wanted = expect.lastAssistantReply, wanted != actual.lastAssistantReply {
            failures.append("\(root).lastAssistantReply: expected \(wanted.map { "\"\($0)\"" } ?? "null"), "
                            + "got \(actual.lastAssistantReply.map { "\"\($0)\"" } ?? "null")")
        }
        return failures
    }
}
