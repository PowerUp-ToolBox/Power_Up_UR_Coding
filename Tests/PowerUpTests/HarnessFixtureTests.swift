import XCTest
@testable import PowerUp

/// Plays the `Tests/Fixtures/harness/` case tables (spec #98, slice 2.3)
/// against the Swift app: how stdout bytes become lines, what one line of
/// the claude CLI parses into, what each call writes on its stdin, and the
/// argv a launch passes, and the adapter's process rules. The Rust core plays
/// the same files (`rust/powerup-core/tests/harness.rs`), so the two can only
/// agree. Every table runs through the bridge since slice 2.3: the app's
/// parser, line splitter, stdin writer, argv and adapter rules are the core's.
final class HarnessFixtureTests: XCTestCase {

    private static let area = "harness"

    // MARK: claude-stream.json

    func testClaudeStreamTable() throws {
        let fileName = "claude-stream.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: JSONValue.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let line = try FixtureLine.bytes(fixtureCase.input)
            let actual = JSONValue.array(ClaudeService.events(fromLine: line).map(\.fixtureDescriptor))
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: claude-stdin.json

    private struct StdinInput: Decodable {
        let call: String
        let text: String?
        let model: String?
        let mode: String?
        let requestID: String?
    }

    private func stdinLine(_ input: StdinInput) throws -> Data? {
        switch input.call {
        case "send":
            return CoreBridge.claudeUserTurnLine(input.text ?? "")
        case "interrupt":
            return CoreBridge.claudeControlRequestLine(requestID: try requestID(input), subtype: "interrupt", value: nil)
        case "setModel":
            return CoreBridge.claudeControlRequestLine(requestID: try requestID(input), subtype: "set_model", value: input.model)
        case "setPermissionMode":
            return CoreBridge.claudeControlRequestLine(requestID: try requestID(input), subtype: "set_permission_mode",
                                                       value: input.mode)
        default:
            throw FixtureValueError(description: "unknown stdin call \(input.call)")
        }
    }

    private func requestID(_ input: StdinInput) throws -> String {
        guard let requestID = input.requestID else {
            throw FixtureValueError(description: "\(input.call) needs a requestID")
        }
        return requestID
    }

    func testClaudeStdinTable() throws {
        let fileName = "claude-stdin.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: StdinInput.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            var actual = JSONValue.null
            if let line = try stdinLine(fixtureCase.input) {
                // One line: compact JSON escapes every line break, so the
                // only newline is the terminator the CLI reads up to.
                XCTAssertEqual(line.last, 0x0A, "\(fileName) case \(fixtureCase.name): no newline at the end")
                XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "\(fileName) case \(fixtureCase.name): more than one line")
                actual = try JSONDecoder().decode(JSONValue.self, from: line)
                // The flat control-request shape kills the CLI (DESIGN.md v1.1 A).
                if actual["type"] == .string("control_request") {
                    XCTAssertNil(actual["subtype"], "\(fileName) case \(fixtureCase.name): the flat shape")
                }
            }
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: claude-lines.json

    private struct LinesInput: Decodable {
        let chunks: [JSONValue]
        let flush: Bool
    }

    private struct LinesExpected: Decodable, Equatable {
        let lines: [[String]]
        let remainder: String?
    }

    func testClaudeLinesTable() throws {
        let fileName = "claude-lines.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: LinesInput.self, expected: LinesExpected.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let io = IOChannel()
            var lines: [[String]] = []
            for chunk in fixtureCase.input.chunks {
                lines.append(io.ingestStdout(try FixtureLine.bytes(chunk)).map { String(decoding: $0, as: UTF8.self) })
            }
            var remainder: String?
            if fixtureCase.input.flush {
                remainder = io.flushStdoutRemainder().map { String(decoding: $0, as: UTF8.self) }
                // A flush empties the buffer.
                XCTAssertNil(io.flushStdoutRemainder(), "\(fileName) case \(fixtureCase.name): a second flush gave bytes")
            }
            let actual = LinesExpected(lines: lines, remainder: remainder)
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: claude-launch.json

    private struct LaunchInput: Decodable {
        let model: String
        let permissionMode: String
        let effort: String
        let resumeSessionID: String?
    }

    func testClaudeLaunchTable() throws {
        let fileName = "claude-launch.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: LaunchInput.self, expected: [String].self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let input = fixtureCase.input
            let actual = CoreBridge.claudeLaunchArguments(model: input.model, permissionMode: input.permissionMode,
                                                          effort: input.effort, resumeSessionID: input.resumeSessionID)
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    // MARK: claude-adapter.json

    /// The adapter as ClaudeService drives it: through the bridge, with the
    /// request id prefix the table expects.
    private func adapterStep(_ adapter: CoreBridge.ClaudeAdapter,
                             _ step: JSONValue) throws -> [CoreBridge.ClaudeAdapterEffect] {
        guard case .object(let fields) = step else { throw FixtureValueError(description: "a step is not an object: \(step)") }
        func string(_ key: String, in object: JSONValue? = nil) throws -> String {
            guard let value = (object ?? step)[key]?.stringValue else {
                throw FixtureValueError(description: "\(key) must be a string: \(step)")
            }
            return value
        }
        func optionalString(_ key: String, in object: JSONValue) throws -> String? {
            guard let value = object[key] else { throw FixtureValueError(description: "\(key) is missing: \(step)") }
            if value == .null { return nil }
            return try string(key, in: object)
        }
        func running() throws -> Bool {
            guard case .bool(let running)? = fields["processRunning"] else {
                throw FixtureValueError(description: "processRunning must be a bool: \(step)")
            }
            return running
        }
        func exit(_ object: JSONValue?) throws -> (Int32, Bool, String) {
            guard let object, case .integer(let code)? = object["exitCode"], let exitCode = Int32(exactly: code),
                  case .bool(let clean)? = object["clean"] else {
                throw FixtureValueError(description: "not an exit: \(step)")
            }
            return (exitCode, clean, try string("stderrTail", in: object))
        }
        func feed(_ generation: UInt64, _ line: JSONValue?) throws -> [CoreBridge.ClaudeAdapterEffect] {
            guard let line else { throw FixtureValueError(description: "no line: \(step)") }
            return CoreBridge.claudeEvents(fromLine: try FixtureLine.bytes(line))
                .flatMap { adapter.stdoutEvent(generation: generation, event: $0) }
        }
        let current = adapter.generation
        let retired = current &- 1
        switch fields.keys.sorted() {
        case ["start"]:
            guard let config = fields["start"] else { throw FixtureValueError(description: "no start") }
            return adapter.start(HarnessConfiguration(
                projectDir: URL(fileURLWithPath: try string("projectDir", in: config), isDirectory: true),
                model: try string("model", in: config),
                permissionMode: try string("permissionMode", in: config),
                effort: try string("effort", in: config),
                resumeSessionID: try optionalString("resumeSessionID", in: config),
                binaryPathOverride: try optionalString("binaryPathOverride", in: config)))
        case ["binaryResolved"]:
            return adapter.binaryResolved(generation: current, path: try optionalString("binaryResolved", in: step))
        case ["spawned"]:
            return adapter.spawned(generation: current)
        case ["spawnFailed"]:
            let failure = fields["spawnFailed"]
            return adapter.spawnFailed(generation: current, executable: try string("executable", in: failure),
                                       description: try string("description", in: failure))
        case ["processRunning", "send"]:
            return adapter.send(try string("send"), processRunning: try running())
        case ["interrupt", "processRunning"]:
            return adapter.interrupt(processRunning: try running())
        case ["processRunning", "setModel"]:
            return adapter.setModel(try string("setModel"), processRunning: try running())
        case ["processRunning", "setPermissionMode"]:
            return adapter.setPermissionMode(try string("setPermissionMode"), processRunning: try running())
        case ["stop"]:
            return adapter.stop()
        case ["line"]:
            return try feed(current, fields["line"])
        case ["retiredLine"]:
            return try feed(retired, fields["retiredLine"])
        case ["terminated"]:
            let (code, clean, tail) = try exit(fields["terminated"])
            return adapter.terminated(generation: current, exitCode: code, clean: clean, stderrTail: tail)
        case ["retiredTerminated"]:
            let (code, clean, tail) = try exit(fields["retiredTerminated"])
            return adapter.terminated(generation: retired, exitCode: code, clean: clean, stderrTail: tail)
        case ["writeFailed"]:
            return adapter.stdinWriteFailed(description: try string("writeFailed"))
        default:
            throw FixtureValueError(description: "unknown adapter step: \(step)")
        }
    }

    private struct AdapterInput: Decodable {
        let steps: [JSONValue]
    }

    func testClaudeAdapterTable() throws {
        let fileName = "claude-adapter.json"
        let file = try TextSafetyFixtures.load(fileName, area: Self.area,
                                               input: AdapterInput.self, expected: JSONValue.self)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        for fixtureCase in file.cases {
            let adapter = CoreBridge.ClaudeAdapter(requestIDPrefix: "R")
            var effects: [JSONValue] = []
            for step in fixtureCase.input.steps {
                effects.append(.array(try adapterStep(adapter, step).map { try $0.fixtureDescriptor() }))
            }
            let actual = try JSONValue(encoding: JSONValue.object([
                "effects": .array(effects),
                "snapshot": adapter.snapshot.fixtureFields,
            ]))
            if let failure = TextSafetyFixtures.mismatch(in: fileName, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }
}
