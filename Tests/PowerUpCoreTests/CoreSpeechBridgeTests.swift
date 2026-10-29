import XCTest
import PowerUpCore

/// The speech text half of the bridge (slice 2.5): markdown with CJK,
/// emoji and combining marks in, a record of text and language out,
/// optional strings both ways, a Bool in and out, and Int64 limits at their
/// extremes, all through the generated functions. Only literal text is
/// used; nothing is spoken and no summarizer runs.
final class CoreSpeechBridgeTests: XCTestCase {

    func testAReplyCrossesWithItsLanguage() throws {
        XCTAssertEqual(try spokenReply(markdown: "好的。\n```swift\nlet x = 1\n```\n完成了。", maxChars: 0),
                       CoreSpokenReply(text: "好的。 （代码已省略） 完成了。", language: "zh"))
        XCTAssertEqual(try spokenReply(markdown: "テストは全部通りました。\n```\nx\n```", maxChars: 0),
                       CoreSpokenReply(text: "テストは全部通りました。 code omitted", language: "ja"))
        XCTAssertEqual(try spokenReply(markdown: "", maxChars: Int64.min),
                       CoreSpokenReply(text: "", language: "en"))
        XCTAssertEqual(try speechText(markdown: "**Done.** It works now.", maxChars: 6),
                       "Done. … reply truncated.")
        XCTAssertEqual(try speechText(markdown: "# Title\n- `x` 👩‍👩‍👧", maxChars: Int64.max), "Title x 👩‍👩‍👧")
        // A placeholder a combining mark extends is kept: the rule is on Characters.
        XCTAssertEqual(Array(try speechText(markdown: "x\u{FFFC}\u{301}y", maxChars: 0).unicodeScalars),
                       Array("x\u{FFFC}\u{301}y".unicodeScalars))
    }

    func testTheDecisionAndTheOverrideCrossAsOptionals() throws {
        XCTAssertNil(try dominantLanguage(text: "OK"))
        XCTAssertNil(try dominantLanguage(text: ""))
        XCTAssertEqual(try dominantLanguage(text: "我修改了 parseJSON() 函数"), "zh")
        XCTAssertEqual(try dominantLanguage(text: "테스트가 모두 통과했습니다"), "ko")
        XCTAssertEqual(try dominantLanguage(text: "The build completed successfully and all of the tests passed."),
                       "en")
        XCTAssertEqual(try voiceLanguage(text: "OK", language: nil), "en")
        XCTAssertEqual(try voiceLanguage(text: "这是一个测试", language: "EN"), "EN")
        XCTAssertEqual(try voiceLanguage(text: "这是一个测试", language: ""), "")
        XCTAssertEqual(try voiceLanguage(text: "这是一个测试", language: nil), "zh")
    }

    func testSummaryRulesCross() throws {
        let reply = String(repeating: "é", count: 350)
        XCTAssertTrue(try wantsSummary(reply: reply, speakSummaries: true))
        XCTAssertFalse(try wantsSummary(reply: reply, speakSummaries: false))
        XCTAssertFalse(try wantsSummary(reply: String(reply.dropLast()), speakSummaries: true))
        XCTAssertEqual(try usableSummary(summary: "  Fixed it.\n", reply: reply), "Fixed it.")
        XCTAssertNil(try usableSummary(summary: nil, reply: reply))
        XCTAssertNil(try usableSummary(summary: " \u{200B}", reply: reply))
        let prompt = try summaryPrompt(reply: "  # 東京\n")
        XCTAssertTrue(prompt.hasPrefix("Summarize the following coding-assistant reply"))
        XCTAssertTrue(prompt.hasSuffix("\n\nReply to summarize:\n  # 東京\n"))
    }
}
