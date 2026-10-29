import XCTest
@testable import PowerUp

// MARK: - Shared fixture loading

/// Loads the remote-mode text-safety corpus from `Tests/Fixtures/text-safety/`.
///
/// The files are plain JSON so the Rust core (which owns these rules since
/// slice 2.5 and plays them in `rust/powerup-core/tests/text_safety.rs`) and
/// the Windows and Linux injectors (stage 3) are held to the very same cases.
/// Every file has the same envelope: a header (`description`, `function`,
/// `verifiedBy`, optional `capturedAgainst`) and a `cases` list where each
/// case carries a unique `name`, an `input`, an `expected` output and a
/// `reason` naming the failure it guards against. `Expected` varies per rule
/// (a string, a list of segments, …), so later rules reuse this loader.
enum TextSafetyFixtures {

    struct File<Expected: Decodable>: Decodable {
        let description: String
        let function: String
        let verifiedBy: String
        let capturedAgainst: String?
        let cases: [Case<Expected>]
    }

    struct Case<Expected: Decodable>: Decodable {
        let name: String
        let input: String
        let expected: Expected
        let reason: String
    }

    /// The same envelope for rules whose input is more than one string
    /// (condense takes a `maxChars`, the failure message a whole command
    /// result). The JSON shape is identical; only `input` is an object.
    struct StructuredFile<Input: Decodable, Expected: Decodable>: Decodable {
        let description: String
        let function: String
        let verifiedBy: String
        let capturedAgainst: String?
        let cases: [StructuredCase<Input, Expected>]
    }

    struct StructuredCase<Input: Decodable, Expected: Decodable>: Decodable {
        let name: String
        let input: Input
        let expected: Expected
        let reason: String
    }

    /// `Tests/Fixtures/text-safety/`, found relative to this source file so it
    /// works from `swift test` in any checkout without bundling resources.
    static var directory: URL { directory(area: "text-safety") }

    /// `Tests/Fixtures/<area>/`. Other areas (`status`, …) use the same
    /// envelope, so their tests reuse this loader instead of writing one.
    static func directory(area: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PowerUpTests/
            .deletingLastPathComponent()      // Tests/
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(area, isDirectory: true)
    }

    static func load<Expected: Decodable>(_ fileName: String,
                                          as _: Expected.Type) throws -> File<Expected> {
        let url = directory.appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(File<Expected>.self, from: data)
    }

    static func load<Input: Decodable, Expected: Decodable>(
        _ fileName: String,
        area: String = "text-safety",
        input _: Input.Type,
        expected _: Expected.Type
    ) throws -> StructuredFile<Input, Expected> {
        let url = directory(area: area).appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StructuredFile<Input, Expected>.self, from: data)
    }

    /// The failure text for one case, or nil when `actual` matches. Kept as a
    /// function (rather than an inline assertion) so a test can prove that a
    /// wrong expectation is reported under the case's own name.
    static func mismatch<Expected: Equatable>(in fileName: String,
                                              _ fixtureCase: Case<Expected>,
                                              actual: Expected) -> String? {
        report(fileName, name: fixtureCase.name, reason: fixtureCase.reason,
               input: fixtureCase.input, expected: fixtureCase.expected, actual: actual)
    }

    static func mismatch<Input, Expected: Equatable>(in fileName: String,
                                                     _ fixtureCase: StructuredCase<Input, Expected>,
                                                     actual: Expected) -> String? {
        report(fileName, name: fixtureCase.name, reason: fixtureCase.reason,
               input: fixtureCase.input, expected: fixtureCase.expected, actual: actual)
    }

    private static func report<Input, Expected: Equatable>(_ fileName: String,
                                                           name: String,
                                                           reason: String,
                                                           input: Input,
                                                           expected: Expected,
                                                           actual: Expected) -> String? {
        guard actual != expected else { return nil }
        return "\(fileName) case \"\(name)\" failed — guards: \(reason)\n"
            + "  input:    \(debugDescription(input))\n"
            + "  expected: \(debugDescription(expected))\n"
            + "  actual:   \(debugDescription(actual))"
    }

    /// Spells out invisible scalars (LF, U+2028, …) so a failure is readable.
    static func debugDescription<Value>(_ value: Value) -> String {
        String(reflecting: value).unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x20...0x7E: return String(scalar)
            case 0x2028, 0x2029, 0x0085, 0x00...0x1F, 0x7F:
                return String(format: "\\u{%X}", scalar.value)
            default: return String(scalar)
            }
        }.joined()
    }

    /// Fails the test when the envelope itself is unusable: no cases, a case
    /// without a name or reason, or two cases sharing a name (which would make
    /// a failure message ambiguous).
    static func assertWellFormed<Expected>(_ file: File<Expected>,
                                           _ fileName: String,
                                           line: UInt = #line) {
        checkEnvelope(fileName, description: file.description, function: file.function,
                      verifiedBy: file.verifiedBy,
                      cases: file.cases.map { ($0.name, $0.reason) }, line: line)
    }

    static func assertWellFormed<Input, Expected>(_ file: StructuredFile<Input, Expected>,
                                                  _ fileName: String,
                                                  line: UInt = #line) {
        checkEnvelope(fileName, description: file.description, function: file.function,
                      verifiedBy: file.verifiedBy,
                      cases: file.cases.map { ($0.name, $0.reason) }, line: line)
    }

    private static func checkEnvelope(_ fileName: String,
                                      description: String,
                                      function: String,
                                      verifiedBy: String,
                                      cases: [(name: String, reason: String)],
                                      line: UInt) {
        XCTAssertFalse(description.isEmpty, "\(fileName): empty description", line: line)
        XCTAssertFalse(function.isEmpty, "\(fileName): empty function", line: line)
        XCTAssertFalse(verifiedBy.isEmpty, "\(fileName): empty verifiedBy", line: line)
        XCTAssertFalse(cases.isEmpty, "\(fileName): no cases", line: line)
        var seen = Set<String>()
        for fixtureCase in cases {
            XCTAssertFalse(fixtureCase.name.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(fileName): a case has no name", line: line)
            XCTAssertFalse(fixtureCase.reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(fileName) case \"\(fixtureCase.name)\": missing reason", line: line)
            XCTAssertTrue(seen.insert(fixtureCase.name).inserted,
                          "\(fileName): duplicate case name \"\(fixtureCase.name)\"", line: line)
        }
    }
}

// MARK: - Tests

/// Table-driven tests for the remote-mode text-safety rules (spec #93, 1.3.1):
/// line-break flattening and escape-safe `cmux send` segmentation, played
/// through the bridge (`CoreBridgeTextSafety.swift`), since the Rust core
/// owns the rules (slice 2.5, DESIGN v2.14). Pure functions only — no
/// service, no cmux process, no actor hops.
final class TextSafetyFixtureTests: XCTestCase {

    private static let lineBreaksFile = "line-breaks.json"
    private static let segmentationFile = "segmentation.json"

    // MARK: Line-break flattening

    func testLineBreakFlatteningMatchesFixtures() throws {
        let file = try TextSafetyFixtures.load(Self.lineBreaksFile, as: String.self)
        TextSafetyFixtures.assertWellFormed(file, Self.lineBreaksFile)
        for fixtureCase in file.cases {
            let actual = try XCTUnwrap(CoreBridge.flattenLineBreaks(fixtureCase.input))
            if let failure = TextSafetyFixtures.mismatch(in: Self.lineBreaksFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// The spec's minimum coverage — deleting one of these cases from the
    /// fixture is caught here rather than silently shrinking the contract.
    func testLineBreakFixtureCoversEveryBreakKind() throws {
        let file = try TextSafetyFixtures.load(Self.lineBreaksFile, as: String.self)
        let inputs = file.cases.map(\.input)
        let required: [(String, (String) -> Bool)] = [
            ("LF", { $0.unicodeScalars.contains("\u{0A}") && !$0.contains("\r") }),
            ("CR alone", { $0.unicodeScalars.contains("\u{0D}") && !$0.unicodeScalars.contains("\u{0A}") }),
            ("CRLF", { $0.contains("\r\n") }),
            ("U+2028", { $0.unicodeScalars.contains("\u{2028}") }),
            ("U+2029", { $0.unicodeScalars.contains("\u{2029}") }),
            ("mixed", { input in
                let kinds: [Unicode.Scalar] = ["\u{0A}", "\u{0D}", "\u{2028}", "\u{2029}"]
                return kinds.filter { input.unicodeScalars.contains($0) }.count >= 3
            }),
            ("trailing", { $0.unicodeScalars.last.map { [0x0A, 0x0D, 0x2028, 0x2029].contains($0.value) } ?? false }),
            ("empty", { $0.isEmpty }),
        ]
        for (kind, matches) in required {
            XCTAssertTrue(inputs.contains(where: matches),
                          "\(Self.lineBreaksFile) has no case covering \(kind)")
        }
    }

    // MARK: Escape-safe segmentation

    func testEscapeSafeSegmentationMatchesFixtures() throws {
        let file = try TextSafetyFixtures.load(Self.segmentationFile, as: [String].self)
        TextSafetyFixtures.assertWellFormed(file, Self.segmentationFile)
        for fixtureCase in file.cases {
            let actual = try XCTUnwrap(CoreBridge.escapeSafeSegments(fixtureCase.input))
            if let failure = TextSafetyFixtures.mismatch(in: Self.segmentationFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// Whatever the split, segmentation must never lose, add or reorder text:
    /// the segments concatenate back to the (flattened) input. Checked on
    /// every fixture input, independently of the recorded expectations.
    func testSegmentsAlwaysReassembleToTheFlattenedInput() throws {
        let file = try TextSafetyFixtures.load(Self.segmentationFile, as: [String].self)
        for fixtureCase in file.cases {
            let segments = try XCTUnwrap(CoreBridge.escapeSafeSegments(fixtureCase.input))
            XCTAssertEqual(segments.joined(),
                           try XCTUnwrap(CoreBridge.flattenLineBreaks(fixtureCase.input)),
                           "\(Self.segmentationFile) case \"\(fixtureCase.name)\" does not reassemble")
            XCTAssertFalse(segments.contains(""),
                           "\(Self.segmentationFile) case \"\(fixtureCase.name)\" produced an empty segment")
        }
    }

    func testSegmentationFixtureCoversRequiredKinds() throws {
        let file = try TextSafetyFixtures.load(Self.segmentationFile, as: [String].self)
        let inputs = file.cases.map(\.input)
        let required: [(String, (String) -> Bool)] = [
            ("backslash-n", { $0.contains("\\n") }),
            ("backslash-r", { $0.contains("\\r") }),
            ("backslash-t", { $0.contains("\\t") }),
            ("a run of escapes", { $0.contains("\\n\\n") }),
            ("a surrogate pair", { $0.utf16.count > $0.unicodeScalars.count }),
            ("CJK", { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }),
            ("empty", { $0.isEmpty }),
            ("the segment cap", { $0.components(separatedBy: "\\n").count > 13 }),
        ]
        for (kind, matches) in required {
            XCTAssertTrue(inputs.contains(where: matches),
                          "\(Self.segmentationFile) has no case covering \(kind)")
        }
    }

    // MARK: Failure reporting

    /// Acceptance criterion: a deliberately wrong expectation fails naming the
    /// case. Proven here without editing the shared fixture.
    func testWrongExpectationIsReportedUnderTheCaseName() throws {
        let wrong = TextSafetyFixtures.Case(name: "LF becomes a space",
                                            input: "a\nb",
                                            expected: "a\nb",
                                            reason: "a dictated newline must not submit early")
        let actual = try XCTUnwrap(CoreBridge.flattenLineBreaks(wrong.input))
        let failure = TextSafetyFixtures.mismatch(in: "line-breaks.json", wrong, actual: actual)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.contains("\"LF becomes a space\"") ?? false, failure ?? "")
        XCTAssertTrue(failure?.contains("line-breaks.json") ?? false, failure ?? "")
        XCTAssertTrue(failure?.contains("a dictated newline must not submit early") ?? false, failure ?? "")

        let right = TextSafetyFixtures.Case(name: "LF becomes a space", input: "a\nb",
                                            expected: "a b", reason: "x")
        XCTAssertNil(TextSafetyFixtures.mismatch(in: "line-breaks.json", right,
                                                 actual: try XCTUnwrap(CoreBridge.flattenLineBreaks(right.input))))
    }

    // MARK: Visibility seam

    /// The helpers that were private to RemoteControlService (spec #93,
    /// Visibility) are reachable from tests through the bridge, which now
    /// answers for them. Their fixtures are tested in
    /// CmuxReportingFixtureTests (1.3.2); this only pins that the seam exists.
    func testFormerlyPrivateHelpersAreReachable() {
        XCTAssertEqual(CoreBridge.stripStatusGlyph("✳ Design"), "Design")
        XCTAssertEqual(CoreBridge.condense("a\n b", maxChars: 10), "a b")
        let result = RemoteControlService.CommandResult(status: 0, standardOutput: "", standardError: "",
                                                         timedOut: true, spawnFailed: false)
        XCTAssertEqual(CoreBridge.failureMessage(action: "Listing cmux workspaces", result: result),
                       "Listing cmux workspaces timed out — is the cmux app running?")
    }
}
