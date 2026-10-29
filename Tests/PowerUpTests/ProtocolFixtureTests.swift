import XCTest
@testable import PowerUp

/// Plays the seven `Tests/Fixtures/protocol/` tables against the Swift
/// protocol code: how a client message reads (`PowerUpProtocol`), the
/// protocol name table (`IntentMapper`), every server message as encoded,
/// the handshake from the request bytes (`RequestHead` and
/// `PowerUpProtocol.upgradeDecision`), the accept key and frame decoding and
/// encoding (`WebSocketFraming`). Everything is pure: no socket is opened
/// (ProtocolServerTests drives the same rules over a real loopback port).
final class ProtocolFixtureTests: XCTestCase {

    // MARK: client-message.json

    func testClientMessageTable() throws {
        let file = try play("client-message.json")
        let expected = file.cases.map(\.expected)
        for type in ["hello", "intent", "ping"] {
            XCTAssertTrue(expected.contains { $0["type"]?.stringValue == type },
                          "client-message.json has no \(type) case")
        }
        for code in ["malformed", "unknown_type", "bad_hello", "unsupported_protocol", "unknown_intent"] {
            XCTAssertTrue(expected.contains { $0["error"]?.stringValue == code },
                          "client-message.json has no \(code) case")
        }
    }

    // MARK: intent-names.json

    func testIntentNameTable() throws {
        let file = try play("intent-names.json")
        let mapped = Set(file.cases.compactMap { $0.expected["intent"]?.stringValue })
        XCTAssertEqual(mapped, Set(Self.protocolNames), "every protocol name maps in the table")
        let refused = Set(file.cases.filter { $0.expected == .null }.compactMap { $0.input["name"]?.stringValue })
        for voice in ["beginVoiceCapture", "endVoiceCapture", "pushToTalk", "pushToTalkDraft"] {
            XCTAssertTrue(refused.contains(voice), "intent-names.json must refuse \(voice)")
        }
    }

    // MARK: server-message.json

    func testServerMessageTable() throws {
        let file = try play("server-message.json")
        let inputs = file.cases.map(\.input)
        for type in ["welcome", "status", "transcript", "session", "pong", "error"] {
            XCTAssertTrue(inputs.contains { $0["type"]?.stringValue == type },
                          "server-message.json has no \(type) case")
        }
        let statuses = Set(inputs.compactMap { $0["status"]?.stringValue })
        XCTAssertEqual(statuses, ["noController", "idle", "listening", "thinking", "speaking"])
        let kinds = Set(inputs.compactMap { $0["entry"]?["kind"]?.stringValue })
        XCTAssertEqual(kinds, ["user", "assistant", "tool", "system", "error"])
        for fixtureCase in file.cases {
            if case .string(let text) = fixtureCase.expected {
                XCTAssertFalse(text.contains("\n"), "\(fixtureCase.name): a message is one line (HK-233)")
            }
        }
    }

    // MARK: handshake.json

    func testHandshakeTable() throws {
        let file = try play("handshake.json")
        let outcomes = Set(file.cases.compactMap { $0.expected["outcome"]?.stringValue })
        XCTAssertEqual(outcomes, ["incomplete", "unparseable", "notWebSocket", "refuse", "accept"])
        let statuses = Set(file.cases.compactMap { fixtureCase -> Int64? in
            guard case .integer(let status)? = fixtureCase.expected["status"] else { return nil }
            return status
        })
        XCTAssertEqual(statuses, [400, 403, 405, 426])
    }

    // MARK: accept-key.json

    func testAcceptKeyTable() throws {
        try play("accept-key.json")
    }

    // MARK: frame-decode.json

    func testFrameDecodeTable() throws {
        let file = try play("frame-decode.json")
        let opcodes = Set(file.cases.flatMap { fixtureCase -> [String] in
            guard case .array(let frames)? = fixtureCase.expected["frames"] else { return [] }
            return frames.compactMap { $0["opcode"]?.stringValue }
        })
        XCTAssertEqual(opcodes, ["text", "binary", "close", "ping", "pong"])
        XCTAssertTrue(file.cases.contains { $0.expected["error"] != nil }, "frame-decode.json has no violation")
    }

    // MARK: frame-encode.json

    func testFrameEncodeTable() throws {
        let file = try play("frame-encode.json")
        let codes = Set(file.cases.compactMap { fixtureCase -> Int64? in
            guard case .integer(let code)? = fixtureCase.input["close"] else { return nil }
            return code
        })
        XCTAssertTrue(codes.isSuperset(of: [1000, 1002, 1003, 1009, 1013, 4001, 4003]),
                      "frame-encode.json must encode every close code in use")
        let opcodes = Set(file.cases.compactMap { $0.input["opcode"]?.stringValue })
        XCTAssertEqual(opcodes, Set(Self.opcodeNames.values))
    }

    // MARK: Playing a table

    /// Loads one table, checks its envelope and compares every case's actual
    /// value with its expected one, as `compare` sees them.
    @discardableResult
    private func play(_ fileName: String) throws -> TextSafetyFixtures.StructuredFile<JSONValue, JSONValue> {
        let file = try TextSafetyFixtures.load(fileName, area: "protocol", input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let actual = try Self.actual(fileName, fixtureCase.input)
            let shown = try Self.matches(fileName, actual: actual, expected: fixtureCase.expected)
                ? fixtureCase.expected : actual
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: shown) {
                XCTFail(failure)
            }
        }
        return file
    }

    /// What the Swift code returns for one case's input, as a fixture value.
    static func actual(_ fileName: String, _ input: JSONValue) throws -> JSONValue {
        switch fileName {
        case "client-message.json": return clientMessage(try FixtureBytes.data(input))
        case "intent-names.json": return try intentName(input)
        case "server-message.json": return try serverMessage(input)
        case "handshake.json": return handshake(try FixtureBytes.data(input))
        case "accept-key.json":
            guard let key = input.stringValue else { throw FixtureValueError(description: "not a key: \(input)") }
            return .string(WebSocketFraming.acceptKey(forClientKey: key))
        case "frame-decode.json": return try frameDecode(input)
        case "frame-encode.json": return try frameEncode(input)
        default: throw FixtureValueError(description: "no runner for \(fileName)")
        }
    }

    /// Bytes descriptors compare by the bytes they stand for, and a server
    /// message member by member at every level: Swift writes the members of
    /// a dictionary in a hash order that changes from launch to launch.
    static func matches(_ fileName: String, actual: JSONValue, expected: JSONValue) throws -> Bool {
        switch fileName {
        case "server-message.json":
            guard case .string(let written) = actual, case .string(let fixed) = expected else {
                return actual == expected
            }
            return JSONMembers.canonical(written) == JSONMembers.canonical(fixed)
        case "frame-decode.json":
            return actual == (try decodedBytes(expected))
        case "frame-encode.json":
            return actual == (try FixtureBytes.descriptor(FixtureBytes.data(expected)))
        default:
            return actual == expected
        }
    }

    // MARK: Runners

    private static func clientMessage(_ payload: Data) -> JSONValue {
        switch PowerUpProtocol.parseClientMessage(payload) {
        case .success(.hello(let token)):
            return .object(["type": .string("hello"), "token": .string(token)])
        case .success(.intent(let intent)):
            guard case .object(var fields) = intent.fixtureDescriptor else { return .null }
            fields["type"] = .string("intent")
            return .object(fields)
        case .success(.ping):
            return .object(["type": .string("ping")])
        case .failure(let failure):
            return .object(["error": .string(failure.code), "message": .string(failure.message)])
        }
    }

    private static func intentName(_ input: JSONValue) throws -> JSONValue {
        guard let name = input["name"]?.stringValue else {
            throw FixtureValueError(description: "no name in \(input)")
        }
        let text: String?
        switch input["text"] {
        case .string(let value)?: text = value
        case .null?, nil: text = nil
        default: throw FixtureValueError(description: "text must be a string or null: \(input)")
        }
        return IntentMapper.intent(forProtocolName: name, text: text)?.fixtureDescriptor ?? .null
    }

    private static func serverMessage(_ input: JSONValue) throws -> JSONValue {
        let message: [String: Any]
        switch input["type"]?.stringValue {
        case "welcome":
            message = PowerUpProtocol.welcome(appVersion: try string(input, "appVersion"))
        case "status":
            message = PowerUpProtocol.status(try status(try string(input, "status")))
        case "transcript":
            message = PowerUpProtocol.transcript(try entry(input["entry"]))
        case "session":
            message = PowerUpProtocol.session(model: try string(input, "model"),
                                              liveModel: try optionalString(input, "liveModel"),
                                              effort: try string(input, "effort"),
                                              permissionMode: try string(input, "permissionMode"),
                                              controlMode: try string(input, "controlMode"),
                                              sessionID: try optionalString(input, "sessionID"),
                                              costUSD: try double(input["costUSD"]),
                                              tokens: try integer(input["tokens"]))
        case "pong":
            message = PowerUpProtocol.pong()
        case "error":
            message = PowerUpProtocol.error(code: try string(input, "code"), message: try string(input, "message"))
        default:
            throw FixtureValueError(description: "unknown server message \(input)")
        }
        guard let data = PowerUpProtocol.encode(message) else { return .null }
        return .string(String(decoding: data, as: UTF8.self))
    }

    private static func handshake(_ request: Data) -> JSONValue {
        guard let boundary = RequestHead.headerBoundary(in: request) else {
            return .object(["outcome": .string("incomplete")])
        }
        let headData = request.subdata(in: request.startIndex..<(request.startIndex + boundary.headerEnd))
        guard let head = RequestHead(headData) else {
            return .object(["outcome": .string("unparseable")])
        }
        var fields: [String: JSONValue] = ["method": .string(head.method), "path": .string(head.path)]
        switch PowerUpProtocol.upgradeDecision(method: head.method, path: head.path, header: { head.value(for: $0) }) {
        case nil:
            fields["outcome"] = .string("notWebSocket")
        case .reject(let status, let reason)?:
            fields["outcome"] = .string("refuse")
            fields["status"] = .integer(Int64(status))
            fields["reason"] = .string(reason)
        case .accept(let acceptKey)?:
            fields["outcome"] = .string("accept")
            fields["acceptKey"] = .string(acceptKey)
        }
        return .object(fields)
    }

    private static func frameDecode(_ input: JSONValue) throws -> JSONValue {
        var buffer = try FixtureBytes.data(try XCTUnwrap(input["buffer"]))
        let maxPayload = try integer(input["maxPayload"])
        let frames: [WebSocketFraming.Frame]
        do {
            frames = try WebSocketFraming.decodeFrames(from: &buffer, maxPayload: maxPayload)
        } catch {
            return .object(["error": .string("protocolViolation")])
        }
        return .object([
            "frames": .array(frames.map { frame in
                .object(["opcode": .string(opcodeNames[frame.opcode] ?? "?"),
                         "payload": FixtureBytes.descriptor(frame.payload)])
            }),
            "remaining": FixtureBytes.descriptor(buffer),
        ])
    }

    private static func frameEncode(_ input: JSONValue) throws -> JSONValue {
        if case .integer(let code)? = input["close"] {
            guard let code = UInt16(exactly: code) else { throw FixtureValueError(description: "bad close code \(code)") }
            return FixtureBytes.descriptor(WebSocketFraming.encodeClose(code: code))
        }
        let payload = try FixtureBytes.data(try XCTUnwrap(input["payload"]))
        let name = try string(input, "opcode")
        guard let opcode = opcodeNames.first(where: { $0.value == name })?.key else {
            throw FixtureValueError(description: "unknown opcode \(name)")
        }
        let frame = WebSocketFraming.encodeFrame(opcode: opcode, payload: payload)
        if opcode == .text {
            XCTAssertEqual(WebSocketFraming.encodeText(payload), frame, "encodeText is encodeFrame(opcode: .text)")
        }
        return FixtureBytes.descriptor(frame)
    }

    /// A decode expectation with every bytes descriptor spelled as `{"hex"}`.
    private static func decodedBytes(_ expected: JSONValue) throws -> JSONValue {
        guard case .array(let frames)? = expected["frames"] else { return expected }
        return .object([
            "frames": .array(try frames.map { frame in
                guard case .object(var fields) = frame else { return frame }
                fields["payload"] = FixtureBytes.descriptor(try FixtureBytes.data(try XCTUnwrap(fields["payload"])))
                return .object(fields)
            }),
            "remaining": FixtureBytes.descriptor(try FixtureBytes.data(try XCTUnwrap(expected["remaining"]))),
        ])
    }

    // MARK: Values

    /// The sixteen names of docs/protocol.md's intent vocabulary.
    static let protocolNames = [
        "sendPrompt", "sendDraft", "approve", "reject", "interrupt", "stopSpeaking", "replayLastReply",
        "toggleTTS", "newSession", "showWindow", "cycleModel", "cycleEffort", "cyclePermissionMode",
        "cycleProject", "cycleFocus", "toggleControlMode",
    ]

    static let opcodeNames: [WebSocketFraming.Opcode: String] = [
        .continuation: "continuation", .text: "text", .binary: "binary",
        .close: "close", .ping: "ping", .pong: "pong",
    ]

    private static func status(_ name: String) throws -> AppStatus {
        switch name {
        case "noController": return .noController
        case "idle": return .idle
        case "listening": return .listening
        case "thinking": return .thinking
        case "speaking": return .speaking
        default: throw FixtureValueError(description: "unknown status \(name)")
        }
    }

    private static func entry(_ value: JSONValue?) throws -> TranscriptEntry {
        guard let value,
              let id = value["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let kind = value["kind"]?.stringValue.flatMap(TranscriptEntry.Kind.init(rawValue:)),
              let text = value["text"]?.stringValue else {
            throw FixtureValueError(description: "not a transcript entry: \(String(describing: value))")
        }
        let seconds = try double(value["date"])
        let date = Date(timeIntervalSince1970: seconds)
        guard date.timeIntervalSince1970 == seconds else {
            throw FixtureValueError(description: "the date \(seconds) is not one a Date holds exactly")
        }
        return TranscriptEntry(id: id, kind: kind, text: text, date: date)
    }

    private static func string(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.stringValue else {
            throw FixtureValueError(description: "no string \(key) in \(input)")
        }
        return value
    }

    private static func optionalString(_ input: JSONValue, _ key: String) throws -> String? {
        switch input[key] {
        case .string(let value)?: return value
        case .null?: return nil
        default: throw FixtureValueError(description: "\(key) must be a string or null in \(input)")
        }
    }

    private static func integer(_ value: JSONValue?) throws -> Int {
        guard case .integer(let number)? = value, let integer = Int(exactly: number) else {
            throw FixtureValueError(description: "not an integer: \(String(describing: value))")
        }
        return integer
    }

    /// A number, or `"nan"`, `"infinity"` or `"-0"` for a Double JSON cannot
    /// spell or the fixture reader would not keep.
    private static func double(_ value: JSONValue?) throws -> Double {
        switch value {
        case .integer(let whole)?: return Double(whole)
        case .number(let number)?: return number
        case .string("nan")?: return .nan
        case .string("infinity")?: return .infinity
        case .string("-0")?: return -0.0
        default: throw FixtureValueError(description: "not a number: \(String(describing: value))")
        }
    }
}

/// The members of a JSON object's text, compared without their order: each
/// object's members are sorted as text, at every level, and nothing else is
/// changed, so strings and numbers still compare byte for byte.
enum JSONMembers {
    static func canonical(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        let result = value(scalars, &index)
        return index == scalars.count ? result : nil
    }

    private static func value(_ scalars: [Unicode.Scalar], _ index: inout Int) -> String? {
        guard index < scalars.count else { return nil }
        if scalars[index] == "{" { return object(scalars, &index) }
        if scalars[index] == "[" { return array(scalars, &index) }
        if scalars[index] == "\"" { return string(scalars, &index) }
        var token = ""
        while index < scalars.count, !",}]".unicodeScalars.contains(scalars[index]) {
            token.unicodeScalars.append(scalars[index])
            index += 1
        }
        return token.isEmpty ? nil : token
    }

    private static func string(_ scalars: [Unicode.Scalar], _ index: inout Int) -> String? {
        var text = "\""
        index += 1
        var escaped = false
        while index < scalars.count {
            let scalar = scalars[index]
            text.unicodeScalars.append(scalar)
            index += 1
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == "\"" {
                return text
            }
        }
        return nil
    }

    private static func object(_ scalars: [Unicode.Scalar], _ index: inout Int) -> String? {
        index += 1
        var members: [String] = []
        while index < scalars.count, scalars[index] != "}" {
            guard scalars[index] == "\"", let key = string(scalars, &index),
                  index < scalars.count, scalars[index] == ":" else { return nil }
            index += 1
            guard let member = value(scalars, &index) else { return nil }
            members.append(key + ":" + member)
            if index < scalars.count, scalars[index] == "," { index += 1 }
        }
        guard index < scalars.count else { return nil }
        index += 1
        return "{" + members.sorted().joined(separator: ",") + "}"
    }

    private static func array(_ scalars: [Unicode.Scalar], _ index: inout Int) -> String? {
        index += 1
        var items: [String] = []
        while index < scalars.count, scalars[index] != "]" {
            guard let item = value(scalars, &index) else { return nil }
            items.append(item)
            if index < scalars.count, scalars[index] == "," { index += 1 }
        }
        guard index < scalars.count else { return nil }
        index += 1
        return "[" + items.joined(separator: ",") + "]"
    }
}
