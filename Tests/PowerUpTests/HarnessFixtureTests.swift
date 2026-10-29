import XCTest
@testable import PowerUp

/// Plays the `Tests/Fixtures/harness/` case tables (spec #98, slice 2.3)
/// against the Swift app: what one stdout line of the claude CLI parses
/// into, and what each call writes on its stdin. The Rust core plays the
/// same files (`rust/powerup-core/tests/harness.rs`), so the two can only
/// agree.
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
            return ClaudeService.userTurnLine(input.text ?? "")
        case "interrupt":
            return ClaudeService.controlRequestLine(requestID: try requestID(input), subtype: "interrupt", value: nil)
        case "setModel":
            return ClaudeService.controlRequestLine(requestID: try requestID(input), subtype: "set_model", value: input.model)
        case "setPermissionMode":
            return ClaudeService.controlRequestLine(requestID: try requestID(input), subtype: "set_permission_mode",
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
}
