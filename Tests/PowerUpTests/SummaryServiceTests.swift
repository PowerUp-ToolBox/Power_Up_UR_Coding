import XCTest
@testable import PowerUp

/// Covers the pure parts of the spoken-summaries feature. The process spawn
/// itself is deliberately untested — tests never run real `claude` sessions
/// (see CLAUDE.md); every failure of that path resolves to nil, which callers
/// treat as "speak the full reply".
final class SummaryServiceTests: XCTestCase {

    func testInvocationIsOneShotToollessTextOut() {
        let arguments = SummaryService.arguments(model: "haiku")
        XCTAssertEqual(arguments, ["-p", "--model", "haiku",
                                   "--output-format", "text",
                                   "--permission-mode", "default"])
        XCTAssertFalse(arguments.contains("--input-format"),
                       "a summary call must never open a streaming session")
        XCTAssertFalse(arguments.contains("bypassPermissions"))
    }

    func testPromptEmbedsTheReplyAndAsksForSpokenProse() {
        let prompt = SummaryService.prompt(for: "I refactored the parser and all tests pass.")
        XCTAssertTrue(prompt.contains("I refactored the parser and all tests pass."))
        XCTAssertTrue(prompt.contains("READ ALOUD"))
        XCTAssertTrue(prompt.contains("same language"),
                      "non-English replies must get summaries in their language")
        XCTAssertTrue(prompt.contains("no markdown"))
    }

    func testConfigDefaultsAreOffAndHaiku() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.speakSummaries, "summaries cost tokens — must be opt-in")
        XCTAssertEqual(decoded.summaryModel, "haiku")
    }

    func testBlankSummaryModelFallsBackToDefault() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self,
                                               from: Data(#"{"summaryModel":"  "}"#.utf8))
        XCTAssertEqual(decoded.summaryModel, "haiku")
    }
}
