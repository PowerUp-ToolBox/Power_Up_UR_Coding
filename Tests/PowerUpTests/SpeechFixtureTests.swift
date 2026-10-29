import XCTest
@testable import PowerUp

/// Plays the eight `Tests/Fixtures/speech/` tables against the app's speech
/// rules: the spoken text of a reply, the language its phrases and voice are
/// chosen for, the voice language a caller may pin, and the pure rules of
/// spoken summaries (spec #100 slice 2.5, ticket #160). Played through the
/// bridge (`CoreBridgeSpeech.swift`) since the Rust core owns the rules
/// (slice 2.5, DESIGN v2.14); every expected value was captured from the
/// Swift code the core replaced, and `language-agreement.json` records where
/// the core's detector is allowed to differ from it. Pure functions only:
/// nothing is spoken, no voice is resolved and no summarizer runs.
@MainActor
final class SpeechFixtureTests: XCTestCase {

    // MARK: speech-text.json

    func testSpeechTextTable() throws {
        try play("speech-text.json") { input in
            let text = try SpeechFixtures.text(input["text"])
            let maxChars = try SpeechFixtures.integer(input["maxChars"])
            return .string(try XCTUnwrap(CoreBridge.speechText(fromMarkdown: text, maxChars: maxChars)))
        } expected: { .string(try SpeechFixtures.text($0)) }
    }

    // MARK: spoken-reply.json

    func testSpokenReplyTable() throws {
        try play("spoken-reply.json") { input in
            let spoken = try XCTUnwrap(CoreBridge.spokenReply(fromMarkdown: try SpeechFixtures.text(input["text"]),
                                                              maxChars: try SpeechFixtures.integer(input["maxChars"])))
            return .object(["text": .string(spoken.text), "language": .string(spoken.language)])
        }
    }

    // MARK: language.json and language-agreement.json

    func testLanguageTable() throws {
        try play("language.json") { input in
            SpeechFixtures.optional(CoreBridge.dominantLanguage(of: try SpeechFixtures.text(input)))
        }
    }

    /// Compares the app's decision, the core's since slice 2.5, with
    /// `expected.core` where the table records an accepted difference and
    /// with the Swift app's captured `expected.swift` everywhere else.
    func testLanguageAgreementTable() throws {
        try play("language-agreement.json") { input in
            SpeechFixtures.optional(CoreBridge.dominantLanguage(of: try SpeechFixtures.text(input)))
        } expected: { expected in
            guard case .object(let fields) = expected,
                  Set(fields.keys).isSubset(of: ["swift", "core"]),
                  let swift = fields["swift"] else {
                throw FixtureValueError(description: "not an agreement expectation: \(expected)")
            }
            return fields["core"] ?? swift
        }
    }

    /// An accepted difference is a real one, and of the three kinds the
    /// ledger accepts: the core undecided (spoken in English; HK-421,
    /// HK-422, HK-423); CJK text the core decides by its script where the
    /// recognizer named another CJK language (HK-420, HK-423; the Rust
    /// runner also checks the core's answer is the script's); or German the
    /// core reads as French, which only one sentence repeated does (HK-424).
    func testAgreementDifferencesAreRealAndOfAnAcceptedKind() throws {
        let file = try SpeechFixtures.load("language-agreement.json")
        var differences = 0
        for fixtureCase in file.cases {
            guard case .object(let fields) = fixtureCase.expected, let core = fields["core"] else { continue }
            differences += 1
            let swift = fields["swift"]
            XCTAssertNotEqual(swift, core, "\(fixtureCase.name): a recorded difference that is none")
            let cjk: [JSONValue] = [.string("zh"), .string("ja"), .string("ko")]
            let byScript = cjk.contains(core) && swift.map { cjk.contains($0) } == true
            XCTAssertTrue(core == .null || byScript || (core == .string("fr") && swift == .string("de")),
                          "\(fixtureCase.name): core \(core) where Swift said \(String(describing: swift))")
        }
        XCTAssertGreaterThan(differences, 0, "the table records its accepted differences")
    }

    // MARK: summary-*.json

    func testSummaryThresholdTable() throws {
        try play("summary-threshold.json") { input in
            .bool(CoreBridge.wantsSummary(of: try SpeechFixtures.text(input["reply"]),
                                          speakSummaries: try SpeechFixtures.bool(input["speakSummaries"])))
        }
    }

    func testSummaryAcceptanceTable() throws {
        try play("summary-acceptance.json") { input in
            let summary = try SpeechFixtures.optionalText(input["summary"])
            let reply = try SpeechFixtures.text(input["reply"])
            return SpeechFixtures.optional(CoreBridge.usableSummary(summary, for: reply))
        } expected: { SpeechFixtures.optional(try SpeechFixtures.optionalText($0)) }
    }

    func testSummaryPromptTable() throws {
        try play("summary-prompt.json") { input in
            .string(try XCTUnwrap(CoreBridge.summaryPrompt(for: try SpeechFixtures.text(input))))
        }
    }

    // MARK: voice-language.json

    func testVoiceLanguageTable() throws {
        try play("voice-language.json") { input in
            .string(CoreBridge.voiceLanguage(for: try SpeechFixtures.text(input["text"]),
                                             language: try SpeechFixtures.optionalText(input["language"])))
        }
    }

    // MARK: Coverage

    /// The spec's minimum: every sentence ender, both truncation outcomes,
    /// and (HK-173) a multi-scalar Character at the cut. Deleting such a case
    /// is caught here instead of silently shrinking the contract.
    func testSpeechTextTableCoversTheTruncationEdges() throws {
        let file = try SpeechFixtures.load("speech-text.json")
        let suffix = " … reply truncated."
        let enders: [Character] = [".", "!", "?", "。", "！", "？", "…"]
        var truncatedInputs: [String] = []
        var keptTexts: [String] = []
        for fixtureCase in file.cases {
            let output = try SpeechFixtures.text(fixtureCase.expected)
            guard output.hasSuffix(suffix) else { continue }
            truncatedInputs.append(try SpeechFixtures.text(fixtureCase.input["text"]))
            keptTexts.append(String(output.dropLast(suffix.count)))
        }
        for ender in enders {
            XCTAssertTrue(keptTexts.contains { $0.last == ender }, "no case cuts after \(ender)")
        }
        XCTAssertTrue(keptTexts.contains { !$0.contains(where: enders.contains) }, "no case hard cuts")
        let clusters: [(String, (String) -> Bool)] = [
            ("a skin-tone emoji", { $0.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } }),
            ("a flag", { $0.unicodeScalars.contains { (0x1F1E6...0x1F1FF).contains($0.value) } }),
            ("a ZWJ sequence", { $0.unicodeScalars.contains("\u{200D}") }),
            ("a decomposed accent", { $0.unicodeScalars.contains("\u{0301}") }),
        ]
        for (kind, matches) in clusters {
            XCTAssertTrue(truncatedInputs.contains(where: matches), "no truncated case puts \(kind) at the cut")
        }
    }

    /// The agreement corpus stays a corpus: at least 80 sentences, and each
    /// language and kind of text the spec names is there.
    func testLanguageAgreementCorpusCoversEveryKind() throws {
        let file = try SpeechFixtures.load("language-agreement.json")
        XCTAssertGreaterThanOrEqual(file.cases.count, 80)
        let kinds = ["en", "de", "fr", "es", "it", "pt", "nl", "zh-Hans", "zh-Hant", "ja", "ko",
                     "mixed", "fullwidth", "script", "short", "code", "han", "gate", "unlisted"]
        for kind in kinds {
            let count = file.cases.filter { $0.name.hasPrefix("\(kind): ") }.count
            XCTAssertGreaterThanOrEqual(count, 4, "language-agreement.json has \(count) \(kind) sentences")
        }
        XCTAssertEqual(file.cases.filter { name in !kinds.contains { name.name.hasPrefix("\($0): ") } }.map(\.name), [],
                       "every agreement case is named after its kind")
    }

    // MARK: Helpers

    /// Loads one table, checks its envelope, and compares every case's
    /// result scalar for scalar (Swift's `==` on strings would accept a
    /// canonically equivalent spelling the core is not allowed to produce).
    private func play(_ fileName: String,
                      _ run: (JSONValue) throws -> JSONValue,
                      expected: (JSONValue) throws -> JSONValue = { $0 }) throws {
        let file = try SpeechFixtures.load(fileName)
        TextSafetyFixtures.assertWellFormed(file, fileName)
        XCTAssertNotNil(file.capturedAgainst, "\(fileName): the expected values were captured, say from what")
        for fixtureCase in file.cases {
            let actual = try run(fixtureCase.input)
            let wanted = try expected(fixtureCase.expected)
            guard !SpeechFixtures.sameScalars(actual, wanted) else { continue }
            XCTFail("\(fileName) case \"\(fixtureCase.name)\" failed — guards: \(fixtureCase.reason)\n"
                    + "  expected: \(TextSafetyFixtures.debugDescription(wanted))\n"
                    + "  actual:   \(TextSafetyFixtures.debugDescription(actual))")
        }
    }
}

/// The `speech/` values (Tests/Fixtures/README.md): a text descriptor is a
/// string, or a list of strings and `{"repeat": s, "times": n}` parts joined
/// in order, so a 2000-word reply stays a one-line case.
enum SpeechFixtures {

    static func load(_ fileName: String) throws -> TextSafetyFixtures.StructuredFile<JSONValue, JSONValue> {
        try TextSafetyFixtures.load(fileName, area: "speech", input: JSONValue.self, expected: JSONValue.self)
    }

    static func text(_ value: JSONValue?) throws -> String {
        guard let text = try optionalText(value) else {
            throw FixtureValueError(description: "a text descriptor is required here, not null")
        }
        return text
    }

    /// A text descriptor, or nil for JSON null.
    static func optionalText(_ value: JSONValue?) throws -> String? {
        switch value {
        case .null?:
            return nil
        case .string(let text)?:
            return text
        case .array(let parts)?:
            return try parts.map { part -> String in
                switch part {
                case .string(let text):
                    return text
                case .object(let fields):
                    guard fields.count == 2, let piece = fields["repeat"]?.stringValue,
                          case .integer(let times)? = fields["times"], times >= 0 else {
                        throw FixtureValueError(description: "not a repeat part: \(part)")
                    }
                    return String(repeating: piece, count: Int(times))
                default:
                    throw FixtureValueError(description: "not a text part: \(part)")
                }
            }.joined()
        default:
            throw FixtureValueError(description: "not a text descriptor: \(String(describing: value))")
        }
    }

    static func integer(_ value: JSONValue?) throws -> Int {
        guard case .integer(let number)? = value else {
            throw FixtureValueError(description: "not an integer: \(String(describing: value))")
        }
        return Int(number)
    }

    static func bool(_ value: JSONValue?) throws -> Bool {
        guard case .bool(let flag)? = value else {
            throw FixtureValueError(description: "not a bool: \(String(describing: value))")
        }
        return flag
    }

    static func optional(_ text: String?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }

    /// JSON equality with strings compared scalar for scalar.
    static func sameScalars(_ left: JSONValue, _ right: JSONValue) -> Bool {
        switch (left, right) {
        case (.string(let a), .string(let b)):
            return Array(a.unicodeScalars) == Array(b.unicodeScalars)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { sameScalars($0, $1) }
        case (.object(let a), .object(let b)):
            return Set(a.keys) == Set(b.keys) && a.allSatisfy { key, value in
                b[key].map { sameScalars(value, $0) } ?? false
            }
        default:
            return left == right
        }
    }
}
