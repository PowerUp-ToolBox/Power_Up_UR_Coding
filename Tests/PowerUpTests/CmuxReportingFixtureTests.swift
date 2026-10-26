import XCTest
@testable import PowerUp

/// Table-driven tests for the remote-mode rules that read cmux and report back
/// to the person (spec #93, 1.3.2): `cmux list-workspaces` parsing,
/// status-glyph stripping, condensing command output, and the friendly
/// failure message per command result kind. The cases live in
/// `Tests/Fixtures/text-safety/` (loaded by `TextSafetyFixtures`) so the Rust
/// core and the Windows/Linux injectors are held to the same behavior.
/// Pure functions only: no service, no cmux process, no actor hops.
final class CmuxReportingFixtureTests: XCTestCase {

    private static let workspacesFile = "cmux-workspaces.json"
    private static let statusGlyphFile = "status-glyph.json"
    private static let condenseFile = "condense.json"
    private static let failureMessageFile = "failure-message.json"

    // MARK: Fixture shapes

    /// One parsed `cmux list-workspaces` row, as the fixture spells it.
    struct WorkspaceRow: Decodable, Equatable {
        let ref: String
        let title: String
        let selected: Bool
    }

    struct CondenseInput: Decodable {
        let text: String
        let maxChars: Int
    }

    /// The action label plus every field of `RemoteControlService.CommandResult`.
    struct FailureInput: Decodable {
        let action: String
        let status: Int32
        let standardOutput: String
        let standardError: String
        let timedOut: Bool
        let spawnFailed: Bool

        var commandResult: RemoteControlService.CommandResult {
            RemoteControlService.CommandResult(status: status,
                                               standardOutput: standardOutput,
                                               standardError: standardError,
                                               timedOut: timedOut,
                                               spawnFailed: spawnFailed)
        }
    }

    // MARK: cmux workspace parsing

    func testWorkspaceParsingMatchesFixtures() throws {
        let file = try TextSafetyFixtures.load(Self.workspacesFile, as: [WorkspaceRow].self)
        TextSafetyFixtures.assertWellFormed(file, Self.workspacesFile)
        for fixtureCase in file.cases {
            let actual = RemoteControlService.parseWorkspaces(fixtureCase.input).map {
                WorkspaceRow(ref: $0.ref, title: $0.title, selected: $0.selected)
            }
            if let failure = TextSafetyFixtures.mismatch(in: Self.workspacesFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// Acceptance criterion: the header names the cmux version the parsing
    /// cases were captured against.
    func testWorkspaceFixtureNamesTheCmuxVersion() throws {
        let file = try TextSafetyFixtures.load(Self.workspacesFile, as: [WorkspaceRow].self)
        let capturedAgainst = try XCTUnwrap(file.capturedAgainst,
                                            "\(Self.workspacesFile) must record capturedAgainst")
        XCTAssertNotNil(capturedAgainst.range(of: #"cmux \d+\.\d+\.\d+"#, options: .regularExpression),
                        "\(Self.workspacesFile) capturedAgainst should name a cmux version: \(capturedAgainst)")
    }

    func testWorkspaceFixtureCoversRequiredKinds() throws {
        let file = try TextSafetyFixtures.load(Self.workspacesFile, as: [WorkspaceRow].self)
        let cases = file.cases
        let required: [(String, (TextSafetyFixtures.Case<[WorkspaceRow]>) -> Bool)] = [
            ("the leading * marker alone", { fixtureCase in
                fixtureCase.input.split(separator: "\n").contains { $0.hasPrefix("*") }
                    && !fixtureCase.input.contains("[selected]")
                    && fixtureCase.expected.contains(where: \.selected)
            }),
            ("the trailing [selected] marker alone", { fixtureCase in
                !fixtureCase.input.split(separator: "\n").contains { $0.hasPrefix("*") }
                    && fixtureCase.input.contains("[selected]")
                    && fixtureCase.expected.contains(where: \.selected)
            }),
            ("a name containing [selected]", { fixtureCase in
                fixtureCase.expected.contains { $0.title.contains("[selected]") }
            }),
            ("a name containing *", { fixtureCase in
                fixtureCase.expected.contains { $0.title.contains("*") && !$0.selected }
            }),
            ("empty output", { $0.input.isEmpty && $0.expected.isEmpty }),
            ("trailing whitespace", { fixtureCase in
                fixtureCase.input.split(separator: "\n").contains { line in
                    line.last.map { $0 == " " || $0 == "\t" } ?? false
                }
            }),
        ]
        for (kind, matches) in required {
            XCTAssertTrue(cases.contains(where: matches),
                          "\(Self.workspacesFile) has no case covering \(kind)")
        }
    }

    // MARK: Status-glyph stripping

    func testStatusGlyphStrippingMatchesFixtures() throws {
        let file = try TextSafetyFixtures.load(Self.statusGlyphFile, as: String.self)
        TextSafetyFixtures.assertWellFormed(file, Self.statusGlyphFile)
        for fixtureCase in file.cases {
            let actual = RemoteControlService.stripStatusGlyph(fixtureCase.input)
            if let failure = TextSafetyFixtures.mismatch(in: Self.statusGlyphFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    func testStatusGlyphFixtureCoversRequiredKinds() throws {
        let file = try TextSafetyFixtures.load(Self.statusGlyphFile, as: String.self)
        let cases = file.cases
        func leading(_ fixtureCase: TextSafetyFixtures.Case<String>) -> UInt32? {
            fixtureCase.input.unicodeScalars.first?.value
        }
        let required: [(String, (TextSafetyFixtures.Case<String>) -> Bool)] = [
            ("a Braille spinner frame", { leading($0).map { (0x2800...0x28FF).contains($0) } ?? false }),
            ("a Dingbats activity mark", { fixtureCase in
                (leading(fixtureCase).map { (0x2700...0x27BF).contains($0) } ?? false)
                    && fixtureCase.expected != fixtureCase.input
            }),
            ("an emoji preserved", { fixtureCase in
                (fixtureCase.input.unicodeScalars.first?.properties.isEmojiPresentation ?? false)
                    && fixtureCase.expected == fixtureCase.input
            }),
            ("a leading ellipsis preserved", { $0.input.hasPrefix("…") && $0.expected == $0.input }),
            ("a glyph in the middle not stripped", { fixtureCase in
                fixtureCase.expected == fixtureCase.input
                    && fixtureCase.input.unicodeScalars.dropFirst().contains { (0x2800...0x28FF).contains($0.value) }
            }),
            ("empty input", { $0.input.isEmpty }),
        ]
        for (kind, matches) in required {
            XCTAssertTrue(cases.contains(where: matches),
                          "\(Self.statusGlyphFile) has no case covering \(kind)")
        }
    }

    // MARK: Condensing

    func testCondenseMatchesFixtures() throws {
        let file = try TextSafetyFixtures.load(Self.condenseFile, input: CondenseInput.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, Self.condenseFile)
        for fixtureCase in file.cases {
            let actual = RemoteControlService.condense(fixtureCase.input.text, maxChars: fixtureCase.input.maxChars)
            if let failure = TextSafetyFixtures.mismatch(in: Self.condenseFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// Independent of the recorded expectations: for any limit of 2 or more
    /// the result never exceeds it, and a shortened result ends in "…".
    func testCondenseNeverExceedsTheLimit() throws {
        let file = try TextSafetyFixtures.load(Self.condenseFile, input: CondenseInput.self, expected: String.self)
        for fixtureCase in file.cases where fixtureCase.input.maxChars >= 2 {
            let input = fixtureCase.input
            let actual = RemoteControlService.condense(input.text, maxChars: input.maxChars)
            XCTAssertLessThanOrEqual(actual.count, input.maxChars,
                                     "\(Self.condenseFile) case \"\(fixtureCase.name)\" exceeds its limit")
            let collapsed = input.text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == "\r\n" })
                .joined(separator: " ")
            if collapsed.count > input.maxChars {
                XCTAssertTrue(actual.hasSuffix("…"),
                              "\(Self.condenseFile) case \"\(fixtureCase.name)\" was shortened without a marker")
            }
        }
    }

    func testCondenseFixtureCoversRequiredKinds() throws {
        let file = try TextSafetyFixtures.load(Self.condenseFile, input: CondenseInput.self, expected: String.self)
        let cases = file.cases
        typealias CondenseCase = TextSafetyFixtures.StructuredCase<CondenseInput, String>
        let required: [(String, (CondenseCase) -> Bool)] = [
            ("below the limit", { $0.expected.count < $0.input.maxChars && !$0.expected.hasSuffix("…") }),
            ("exactly at the limit", { $0.expected.count == $0.input.maxChars && $0.expected == $0.input.text }),
            ("above the limit with the marker", { $0.expected.hasSuffix("…") && $0.input.text.count > $0.input.maxChars }),
            ("a multi-byte boundary", { fixtureCase in
                fixtureCase.expected.hasSuffix("…")
                    && fixtureCase.input.text.utf8.count > fixtureCase.input.text.count * 2
            }),
        ]
        for (kind, matches) in required {
            XCTAssertTrue(cases.contains(where: matches),
                          "\(Self.condenseFile) has no case covering \(kind)")
        }
    }

    // MARK: Friendly failure message

    func testFailureMessageMatchesFixtures() throws {
        let file = try TextSafetyFixtures.load(Self.failureMessageFile, input: FailureInput.self, expected: String.self)
        TextSafetyFixtures.assertWellFormed(file, Self.failureMessageFile)
        for fixtureCase in file.cases {
            let actual = RemoteControlService.failureMessage(action: fixtureCase.input.action,
                                                             result: fixtureCase.input.commandResult)
            if let failure = TextSafetyFixtures.mismatch(in: Self.failureMessageFile, fixtureCase, actual: actual) {
                XCTFail(failure)
            }
        }
    }

    /// Every command result kind has at least one case: spawn failure (with
    /// and without detail), timeout, the socket refusal, cmux not running,
    /// a plain non-zero exit with stderr, the stdout fallback and no detail.
    func testFailureMessageFixtureCoversEveryResultKind() throws {
        let file = try TextSafetyFixtures.load(Self.failureMessageFile, input: FailureInput.self, expected: String.self)
        let cases = file.cases
        typealias FailureCase = TextSafetyFixtures.StructuredCase<FailureInput, String>
        let required: [(String, (FailureCase) -> Bool)] = [
            ("spawn failure with detail", { $0.input.spawnFailed && !$0.input.standardError.isEmpty }),
            ("spawn failure without detail", { $0.input.spawnFailed && $0.input.standardError.isEmpty }),
            ("timeout", { $0.input.timedOut && !$0.input.spawnFailed }),
            ("socket refusal", { $0.expected.hasPrefix("cmux refused the connection") }),
            ("cmux not running", { $0.expected.contains("isn’t running") }),
            ("non-zero exit with stderr", { fixtureCase in
                !fixtureCase.input.spawnFailed && !fixtureCase.input.timedOut
                    && !fixtureCase.input.standardError.isEmpty
                    && fixtureCase.expected.hasPrefix("\(fixtureCase.input.action) failed: ")
            }),
            ("stdout fallback", { fixtureCase in
                !fixtureCase.input.spawnFailed && !fixtureCase.input.timedOut
                    && fixtureCase.input.standardError.isEmpty && !fixtureCase.input.standardOutput.isEmpty
            }),
            ("no detail at all", { $0.expected.hasSuffix("(exit \($0.input.status)).") }),
        ]
        for (kind, matches) in required {
            XCTAssertTrue(cases.contains(where: matches),
                          "\(Self.failureMessageFile) has no case covering \(kind)")
        }
    }

    /// The structured envelope reports a wrong expectation under the case's
    /// own name, like the string one (proven without editing a shared fixture).
    func testWrongStructuredExpectationIsReportedUnderTheCaseName() {
        let wrong = TextSafetyFixtures.StructuredCase(name: "above the limit",
                                                      input: CondenseInput(text: "abcdef", maxChars: 5),
                                                      expected: "abcdef",
                                                      reason: "long output must be shortened")
        let actual = RemoteControlService.condense(wrong.input.text, maxChars: wrong.input.maxChars)
        let failure = TextSafetyFixtures.mismatch(in: Self.condenseFile, wrong, actual: actual)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.contains("\"above the limit\"") ?? false, failure ?? "")
        XCTAssertTrue(failure?.contains(Self.condenseFile) ?? false, failure ?? "")
        XCTAssertTrue(failure?.contains("long output must be shortened") ?? false, failure ?? "")
        XCTAssertTrue(failure?.contains("maxChars: 5") ?? false, failure ?? "")
    }
}
