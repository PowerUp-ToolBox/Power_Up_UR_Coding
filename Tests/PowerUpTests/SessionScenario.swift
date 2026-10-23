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
    }

    enum Action {
        case call(Call)
        case intent(Intent)
        case harnessEvent(HarnessEvent)
    }

    struct Step {
        let number: Int            // 1-based, as printed in failures
        let action: Action
        /// The step must leave every observable fact unchanged.
        let expectNoChange: Bool
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
        expect = try Self.parseExpectations(root["expect"], reader: &reader)
    }

    // MARK: Parsing

    private static func parseConfig(_ json: ScenarioJSON?, reader: inout Reader) throws -> Config {
        guard let json else { return Config() }
        let fields = try reader.object(json, at: "$.config", allowed: [
            "harnessKind", "model", "effort", "permissionMode", "controlMode",
            "project", "lastSessionID", "controllerConnected",
        ])
        var config = Config()
        config.harnessKind = try reader.optionalString(fields["harnessKind"], at: "$.config.harnessKind")
        config.model = try reader.optionalString(fields["model"], at: "$.config.model")
        config.effort = try reader.optionalString(fields["effort"], at: "$.config.effort")
        config.permissionMode = try reader.optionalString(fields["permissionMode"], at: "$.config.permissionMode")
        config.controlMode = try reader.optionalString(fields["controlMode"], at: "$.config.controlMode")
        if config.controlMode == "remote" {
            // Remote mode types into a real terminal (cmux / the frontmost
            // app). The runner has no fake remote target yet, and the safety
            // rails forbid driving the real one.
            throw reader.error("$.config.controlMode",
                               "\"remote\" needs a fake remote target, which this runner does not have yet")
        }
        config.project = try reader.optionalBool(fields["project"], at: "$.config.project") ?? false
        config.lastSessionID = try reader.optionalString(fields["lastSessionID"], at: "$.config.lastSessionID")
        config.controllerConnected = try reader.optionalBool(fields["controllerConnected"],
                                                            at: "$.config.controllerConnected") ?? false
        return config
    }

    private static func parseStep(_ json: ScenarioJSON, number: Int, reader: inout Reader) throws -> Step {
        let path = "$.script[\(number - 1)]"
        let fields = try reader.object(json, at: path, allowed: [
            "call", "intent", "harnessEvent", "text", "allow", "reason", "expectNoChange",
        ])
        if let reason = fields["reason"] { _ = try reader.string(reason, at: "\(path).reason") }
        let expectNoChange = try reader.optionalBool(fields["expectNoChange"], at: "\(path).expectNoChange") ?? false
        let kinds = ["call", "intent", "harnessEvent"].filter { fields[$0] != nil }
        guard kinds.count == 1 else {
            throw reader.error(path, "a step has exactly one of \"call\", \"intent\" or \"harnessEvent\"")
        }
        let text = try reader.optionalString(fields["text"], at: "\(path).text")
        let allow = try reader.optionalBool(fields["allow"], at: "\(path).allow")

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
        } else {
            try unused("text", text); try unused("allow", allow)
            action = .harnessEvent(try parseEvent(fields["harnessEvent"], at: "\(path).harnessEvent", reader: &reader))
        }
        return Step(number: number, action: action, expectNoChange: expectNoChange, label: json.description)
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

    private static func parseExpectations(_ json: ScenarioJSON?, reader: inout Reader) throws -> Expectations {
        guard let json else { throw reader.error("$.expect", "missing") }
        let fields = try reader.object(json, at: "$.expect", allowed: [
            "harnessCalls", "transcript", "errorShown", "lastSessionID", "pendingPermission",
            "pendingPermissionArmed", "status",
        ])
        guard !fields.isEmpty else { throw reader.error("$.expect", "expects nothing") }
        var expect = Expectations()

        if let calls = fields["harnessCalls"] {
            guard case .array(let items) = calls else { throw reader.error("$.expect.harnessCalls", "must be an array") }
            expect.harnessCalls = try items.enumerated().map { index, item in
                let path = "$.expect.harnessCalls[\(index)]"
                guard case .object(let object) = item, let typeJSON = object["type"] else {
                    throw reader.error(path, "must be an object with a \"type\"")
                }
                let type = try reader.string(typeJSON, at: "\(path).type")
                guard let allowed = callTypes[type] else {
                    throw reader.error("\(path).type", "unknown harness call \"\(type)\"")
                }
                return try reader.object(item, at: path, allowed: allowed.union(["type"]))
            }
        }
        if let transcript = fields["transcript"] {
            guard case .array(let items) = transcript else { throw reader.error("$.expect.transcript", "must be an array") }
            expect.transcript = try items.enumerated().map { index, item in
                let path = "$.expect.transcript[\(index)]"
                let object = try reader.object(item, at: path, allowed: ["kind", "text"])
                let kind = try reader.string(object["kind"], at: "\(path).kind")
                guard transcriptKinds.contains(kind) else {
                    throw reader.error("\(path).kind", "unknown entry kind \"\(kind)\"")
                }
                if let text = object["text"] { _ = try reader.string(text, at: "\(path).text") }
                return object
            }
        }
        expect.errorShown = try reader.optionalBool(fields["errorShown"], at: "$.expect.errorShown")
        if let id = fields["lastSessionID"] {
            expect.lastSessionID = .some(try reader.optionalString(id, at: "$.expect.lastSessionID"))
        }
        expect.pendingPermission = try reader.optionalBool(fields["pendingPermission"], at: "$.expect.pendingPermission")
        expect.pendingPermissionArmed = try reader.optionalBool(fields["pendingPermissionArmed"],
                                                                at: "$.expect.pendingPermissionArmed")
        if let status = fields["status"] {
            let name = try reader.string(status, at: "$.expect.status")
            guard statusNames.contains(name) else { throw reader.error("$.expect.status", "unknown status \"\(name)\"") }
            expect.status = name
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

        func optionalDouble(_ json: ScenarioJSON?, at path: String) throws -> Double? {
            guard let json, json != .null else { return nil }
            guard case .number(let value) = json else { throw error(path, "must be a number") }
            return value
        }
    }
}

// MARK: - Runner

/// Plays a scenario through the AppState seam (#110) with a scripted
/// `FakeHarnessAdapter` (#111) and returns every mismatch, each prefixed with
/// the scenario name. An empty result means the scenario passed.
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
        config.ttsEnabled = false           // a test run makes no sound
        if let value = scenario.config.harnessKind { config.harnessKind = value }
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
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, harness: harness)
        await settle()

        // Facts are measured from here: anything AppState logged while being
        // built is not part of the script.
        let transcriptBase = app.transcript.count
        harness.clearCalls()
        let projectPath = scenario.config.project ? projectURL.path : nil

        var failures: [String] = []
        for step in scenario.script {
            if app.isRemoteMode {
                failures.append("\(prefix) step \(step.number) \(step.label): AppState is in remote mode; "
                                + "this runner has no fake remote target, so it stops here")
                return failures
            }
            let before = observation(app, harness, transcriptBase: transcriptBase, projectPath: projectPath)
            perform(step.action, on: app, harness: harness)
            await settle()
            if step.expectNoChange {
                let after = observation(app, harness, transcriptBase: transcriptBase, projectPath: projectPath)
                if let difference = firstDifference(before, after) {
                    failures.append("\(prefix) step \(step.number) \(step.label) is tagged expectNoChange "
                                    + "but changed \(difference)")
                }
            }
        }

        let final = observation(app, harness, transcriptBase: transcriptBase, projectPath: projectPath)
        failures += compare(scenario.expect, with: final).map { "\(prefix) \($0)" }
        withExtendedLifetime(app) {}
        return failures
    }

    // MARK: Playing a step

    private static func perform(_ action: SessionScenario.Action, on app: AppState, harness: FakeHarnessAdapter) {
        switch action {
        case .harnessEvent(let event):
            harness.emit(event)
        case .intent(let intent):
            app.handle(intent)
        case .call(let call):
            switch call {
            case .startSessionIfNeeded: app.startSessionIfNeeded()
            case .newSession: app.newSession()
            case .sendUserText(let text): app.sendUserText(text)
            case .interruptClaude: app.interruptClaude()
            case .answerPendingPermission(let allow): app.answerPendingPermission(allow: allow)
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
    }

    private static func observation(_ app: AppState, _ harness: FakeHarnessAdapter,
                                    transcriptBase: Int, projectPath: String?) -> Observation {
        Observation(
            harnessCalls: harness.calls.map { describe($0, projectPath: projectPath) },
            transcript: app.transcript.dropFirst(transcriptBase).map {
                ["kind": .string($0.kind.rawValue), "text": .string($0.text)]
            },
            lastSessionID: app.configStore.config.lastSessionID,
            pendingPermission: app.pendingPermission != nil,
            pendingPermissionArmed: app.pendingPermission?.armed ?? false,
            status: statusName(app.status))
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

    private static func describe(_ call: FakeHarnessAdapter.Call, projectPath: String?) -> [String: ScenarioJSON] {
        func optional(_ value: String?) -> ScenarioJSON { value.map(ScenarioJSON.string) ?? .null }
        switch call {
        case .start(let configuration):
            let dir = configuration.projectDir.path
            return [
                "type": .string("start"),
                "projectDir": .string(dir == projectPath ? "$project" : dir),
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
        return nil
    }

    /// Each mismatch as "expect.<path>: expected …, got …". Lists compare
    /// element by element; an expected element's keys are checked and keys it
    /// leaves out are not, so a fixture states only the facts its rule is about.
    private static func compare(_ expect: SessionScenario.Expectations, with actual: Observation) -> [String] {
        var failures: [String] = []

        func compareList(_ name: String, _ expected: [[String: ScenarioJSON]], _ actual: [[String: ScenarioJSON]]) {
            for (index, wanted) in expected.enumerated() {
                guard index < actual.count else {
                    failures.append("expect.\(name)[\(index)]: expected \(ScenarioJSON.object(wanted)), got nothing "
                                    + "(only \(actual.count) recorded)")
                    return
                }
                let got = actual[index]
                for key in wanted.keys.sorted() where wanted[key] != got[key] {
                    failures.append("expect.\(name)[\(index)].\(key): expected \(wanted[key] ?? .null), "
                                    + "got \(got[key] ?? .null) — full entry \(ScenarioJSON.object(got))")
                    return
                }
            }
            if actual.count > expected.count {
                let extra = actual.dropFirst(expected.count).map { ScenarioJSON.object($0).description }
                failures.append("expect.\(name): expected \(expected.count) entries, got \(actual.count); "
                                + "unexpected \(extra.joined(separator: ", "))")
            }
        }

        if let calls = expect.harnessCalls { compareList("harnessCalls", calls, actual.harnessCalls) }
        if let transcript = expect.transcript { compareList("transcript", transcript, actual.transcript) }
        if let errorShown = expect.errorShown {
            let shown = actual.transcript.contains { $0["kind"] == .string("error") }
            if shown != errorShown {
                failures.append("expect.errorShown: expected \(errorShown), got \(shown)")
            }
        }
        if let wanted = expect.lastSessionID, wanted != actual.lastSessionID {
            failures.append("expect.lastSessionID: expected \(wanted.map { "\"\($0)\"" } ?? "null"), "
                            + "got \(actual.lastSessionID.map { "\"\($0)\"" } ?? "null")")
        }
        if let pending = expect.pendingPermission, pending != actual.pendingPermission {
            failures.append("expect.pendingPermission: expected \(pending), got \(actual.pendingPermission)")
        }
        if let armed = expect.pendingPermissionArmed, armed != actual.pendingPermissionArmed {
            failures.append("expect.pendingPermissionArmed: expected \(armed), got \(actual.pendingPermissionArmed)")
        }
        if let status = expect.status, status != actual.status {
            failures.append("expect.status: expected \"\(status)\", got \"\(actual.status)\"")
        }
        return failures
    }
}
