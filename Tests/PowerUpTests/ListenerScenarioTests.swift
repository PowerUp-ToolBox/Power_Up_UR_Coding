import XCTest
@testable import PowerUp

/// Plays `Tests/Fixtures/listener/` (spec #101, slice 2.6) through the
/// bridge: each scenario drives one `CoreBridge.ListenerPolicy`, the object
/// RemoteListener runs on, input by input, and compares the effects of every
/// step, in order and in the app's types, with the ones the scenario lists.
/// `rust/powerup-core/tests/listener.rs` plays the same files against the
/// core directly; ProtocolServerTests drives the policy over a real socket.
/// No socket is opened here and no timer runs: a fired timer is an input
/// like any other.
///
/// A sent buffer is compared by what it is, as the Rust runner does: HTTP
/// response text, one protocol message (its JSON, members in any order), a
/// close code, a pong payload, or raw bytes.
final class ListenerScenarioTests: XCTestCase {

    func testEveryListenerScenario() throws {
        let urls = try FileManager.default
            .contentsOfDirectory(at: TextSafetyFixtures.directory(area: "listener"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "no listener scenarios")
        for url in urls {
            try play(url)
        }
        // Every input the policy takes and every effect it returns appears
        // somewhere, so a conversion in CoreBridgeListener.swift is never
        // left unplayed.
        XCTAssertEqual(inputsPlayed, ["start", "stop", "bindReady", "bindWaiting", "bindFailed", "bindCancelled",
                                      "listenRefused", "retryFired", "accept", "receive", "endOfStream", "closed",
                                      "deadlineFired", "broadcast", "welcome"])
        XCTAssertEqual(effectsSeen, ["publish", "listen", "stopListening", "scheduleBindRetry", "admit", "refuse",
                                     "armIdleDeadline", "send", "broadcast", "close", "cancel", "deliverHook",
                                     "deliverIntent", "welcome"])
    }

    private var inputsPlayed: Set<String> = []
    private var effectsSeen: Set<String> = []

    // MARK: Playing a scenario

    private static let stepKeys: Set<String> = ["reason", "effects", "state"]

    private func play(_ url: URL) throws {
        let file = url.lastPathComponent
        let scenario = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        XCTAssertEqual(scenario["formatVersion"], .integer(1), "\(file): formatVersion")
        for key in ["name", "description", "reason", "source", "verifiedBy"] {
            let value = scenario[key]?.stringValue ?? ""
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(file): no \(key)")
        }
        guard case .array(let steps)? = scenario["steps"], !steps.isEmpty else {
            return XCTFail("\(file): no steps")
        }

        let policy = CoreBridge.ListenerPolicy()
        for (index, step) in steps.enumerated() {
            guard case .object(let fields) = step,
                  let reason = fields["reason"]?.stringValue,
                  case .array(let expected)? = fields["effects"] else {
                return XCTFail("\(file) step \(index): a step needs a reason and effects")
            }
            let inputs = fields.keys.filter { !Self.stepKeys.contains($0) }
            guard inputs.count == 1, let input = inputs.first, let value = fields[input] else {
                return XCTFail("\(file) step \(index): a step holds exactly one input, not \(inputs.sorted())")
            }
            let context = "\(file) step \(index) (\(input)) failed — guards: \(reason)"

            let actual = try run(policy, input, value).map(Self.descriptor)
            inputsPlayed.insert(input)
            effectsSeen.formUnion(actual.compactMap { $0["effect"]?.stringValue })
            let wanted = try expected.map(Self.normalized)
            if actual != wanted {
                return XCTFail("\(context)\n  expected: \(wanted)\n  actual:   \(actual)")
            }
            if case .object(let facts)? = fields["state"] {
                let now: [String: JSONValue] = [
                    "connections": .integer(Int64(policy.connectionCount)),
                    "authenticated": .integer(Int64(policy.authenticatedCount)),
                    "generation": .integer(Int64(policy.generation)),
                    "running": .bool(policy.status.isRunning),
                ]
                for (key, want) in facts {
                    XCTAssertEqual(now[key], want, "\(context): state \(key)")
                }
            }
        }
    }

    /// Runs one step's input.
    private func run(_ policy: CoreBridge.ListenerPolicy, _ input: String,
                     _ value: JSONValue) throws -> [CoreBridge.ListenerEffect] {
        switch input {
        case "start":
            let port = try Self.integer(value["port"])
            guard let port = UInt16(exactly: port) else { throw FixtureValueError(description: "bad port \(port)") }
            return policy.start(port: port, token: try Self.string(value["token"]))
        case "stop": return policy.stop()
        case "bindReady": return policy.bindReady(generation: try Self.id(value))
        case "bindWaiting":
            return policy.bindWaiting(generation: try Self.id(value["generation"]), error: try Self.bindError(value["error"]))
        case "bindFailed":
            return policy.bindFailed(generation: try Self.id(value["generation"]), error: try Self.bindError(value["error"]))
        case "bindCancelled": return policy.bindCancelled(generation: try Self.id(value))
        case "listenRefused":
            return policy.listenRefused(generation: try Self.id(value["generation"]),
                                        detail: try Self.string(value["detail"]))
        case "retryFired": return policy.retryFired(generation: try Self.id(value))
        case "accept": return policy.accepted(generation: try Self.id(value))
        case "receive":
            return policy.received(connection: try Self.id(value["connection"]),
                                   bytes: try FixtureBytes.data(try XCTUnwrap(value["bytes"])))
        case "endOfStream": return policy.endOfStream(connection: try Self.id(value))
        case "closed": return policy.closed(connection: try Self.id(value))
        case "deadlineFired": return policy.deadlineFired(connection: try Self.id(value))
        case "broadcast": return policy.broadcast(try ProtocolFixtureTests.serverMessageValue(value))
        case "welcome":
            guard case .array(let snapshot)? = value["snapshot"] else {
                throw FixtureValueError(description: "a welcome needs a snapshot list: \(value)")
            }
            return policy.welcome(connection: try Self.id(value["connection"]),
                                  appVersion: try Self.string(value["appVersion"]),
                                  snapshot: try snapshot.map(ProtocolFixtureTests.serverMessageValue))
        default:
            throw FixtureValueError(description: "unknown input \(input)")
        }
    }

    // MARK: Effects as the scenarios write them

    static func descriptor(_ effect: CoreBridge.ListenerEffect) -> JSONValue {
        func object(_ name: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
            .object(fields.merging(["effect": .string(name)]) { field, _ in field })
        }
        switch effect {
        case .publish(let status):
            return object("publish", ["running": .bool(status.isRunning),
                                      "problem": status.lastError.map(JSONValue.string) ?? .null])
        case .listen(let generation, let port):
            return object("listen", ["generation": .integer(Int64(generation)), "port": .integer(Int64(port))])
        case .stopListening: return object("stopListening")
        case .scheduleBindRetry(let generation, let seconds):
            return object("scheduleBindRetry", ["generation": .integer(Int64(generation)), "seconds": number(seconds)])
        case .admit(let connection): return object("admit", ["connection": .integer(Int64(connection))])
        case .refuse: return object("refuse")
        case .armIdleDeadline(let connection, let seconds):
            return object("armIdleDeadline", ["connection": .integer(Int64(connection)), "seconds": number(seconds)])
        case .send(let connection, let bytes):
            let (key, value) = sent(bytes)
            return object("send", ["connection": .integer(Int64(connection)), key: value])
        case .broadcast(let connections, let bytes):
            let (key, value) = sent(bytes)
            return object("broadcast", ["connections": .array(connections.map { .integer(Int64($0)) }), key: value])
        case .close(let connection): return object("close", ["connection": .integer(Int64(connection))])
        case .cancel(let connection): return object("cancel", ["connection": .integer(Int64(connection))])
        case .deliverHook(let generation, let event):
            return object("deliverHook", ["generation": .integer(Int64(generation)), "hook": hook(event)])
        case .deliverIntent(let generation, let intent):
            return object("deliverIntent", ["generation": .integer(Int64(generation)),
                                            "intent": intent.fixtureDescriptor])
        case .welcome(let connection): return object("welcome", ["connection": .integer(Int64(connection))])
        }
    }

    /// A scenario's effect with its bytes descriptors reduced to hex, the
    /// spelling `descriptor` writes.
    private static func normalized(_ effect: JSONValue) throws -> JSONValue {
        guard case .object(var fields) = effect else { return effect }
        for key in ["pong", "hex"] {
            if let bytes = fields[key] { fields[key] = FixtureBytes.descriptor(try FixtureBytes.data(bytes)) }
        }
        return .object(fields)
    }

    private static func number(_ value: Double) -> JSONValue {
        if let whole = Int64(exactly: value) { return .integer(whole) }
        return .number(value)
    }

    private static func hook(_ event: RemoteHookEvent) -> JSONValue {
        let kind: String
        switch event.kind {
        case .stop: kind = "stop"
        case .userPromptSubmit: kind = "userPromptSubmit"
        case .notification: kind = "notification"
        case .sessionEnd: kind = "sessionEnd"
        case .postToolUse: kind = "postToolUse"
        }
        func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
        return .object(["kind": .string(kind), "text": optional(event.text),
                        "sessionID": optional(event.sessionID), "cwd": optional(event.cwd)])
    }

    /// What a sent buffer is, as a scenario writes it.
    private static func sent(_ bytes: Data) -> (String, JSONValue) {
        if bytes.starts(with: Data("HTTP/".utf8)), let response = String(data: bytes, encoding: .utf8) {
            return ("http", .string(response))
        }
        guard let (opcode, payload) = serverFrame(bytes) else { return ("hex", FixtureBytes.descriptor(bytes)) }
        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else { return ("hex", FixtureBytes.descriptor(bytes)) }
            if let message = try? JSONDecoder().decode(JSONValue.self, from: payload), case .object = message {
                return ("message", message)
            }
            return ("text", .string(text))
        case 0x8 where payload.count == 2:
            return ("close", .integer(Int64(UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]))))
        case 0xA:
            return ("pong", FixtureBytes.descriptor(payload))
        default:
            return ("hex", FixtureBytes.descriptor(bytes))
        }
    }

    /// One unmasked, final server frame: its opcode and payload, or nil when
    /// the bytes are anything else.
    private static func serverFrame(_ data: Data) -> (UInt8, Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] & 0xF0 == 0x80, bytes[1] & 0x80 == 0 else { return nil }
        var offset = 2
        var length = Int(bytes[1])
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var wide: UInt64 = 0
            for byte in bytes[2..<10] { wide = wide << 8 | UInt64(byte) }
            guard let exact = Int(exactly: wide) else { return nil }
            length = exact
            offset = 10
        }
        guard bytes.count - offset == length else { return nil }
        return (bytes[0] & 0x0F, Data(bytes[offset...]))
    }

    // MARK: Values

    private static func integer(_ value: JSONValue?) throws -> Int64 {
        guard case .integer(let number)? = value else {
            throw FixtureValueError(description: "not an integer: \(String(describing: value))")
        }
        return number
    }

    private static func id(_ value: JSONValue?) throws -> UInt64 {
        let number = try integer(value)
        guard let id = UInt64(exactly: number) else { throw FixtureValueError(description: "not an id: \(number)") }
        return id
    }

    private static func string(_ value: JSONValue?) throws -> String {
        guard let text = value?.stringValue else {
            throw FixtureValueError(description: "not a string: \(String(describing: value))")
        }
        return text
    }

    /// `"addressInUse"` or `{"other": <detail>}`.
    private static func bindError(_ value: JSONValue?) throws -> CoreBridge.BindError {
        if value?.stringValue == "addressInUse" { return .addressInUse }
        if let detail = value?["other"]?.stringValue { return .other(detail) }
        throw FixtureValueError(description: "not a bind error: \(String(describing: value))")
    }
}
