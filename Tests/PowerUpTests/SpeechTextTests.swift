import XCTest
@testable import PowerUp

/// Covers the pure text pipeline that turns a markdown-ish Claude reply into
/// something speakable, plus the language detection that routes voices —
/// the Rust core's speech rules since slice 2.5, asked through the bridge
/// (`CoreBridgeSpeech.swift`, DESIGN v2.14) — and the voice exclusions
/// TTSService keeps.
@MainActor
final class SpeechTextTests: XCTestCase {

    // MARK: Markdown stripping

    func testFencedCodeBlocksCollapse() throws {
        let input = "Here is the fix:\n```swift\nlet x = 1\n```\nAll done."
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: input, maxChars: 0))
        XCTAssertEqual(output, "Here is the fix: code omitted All done.")
    }

    func testInlineMarkdownIsStripped() throws {
        let input = "Use `swift build` to **compile** the [project](https://example.com) _now_."
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: input, maxChars: 0))
        XCTAssertEqual(output, "Use swift build to compile the project now.")
    }

    func testHeadingsQuotesAndBulletsAreStripped() throws {
        let input = "# Title\n> quoted line\n- first item\n* second item\nplain"
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: input, maxChars: 0))
        XCTAssertEqual(output, "Title quoted line first item second item plain")
    }

    func testWhitespaceCollapses() throws {
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: "a\n\n\n   b\t\tc", maxChars: 0))
        XCTAssertEqual(output, "a b c")
    }

    // MARK: Truncation

    func testZeroMaxCharsMeansNoLimit() throws {
        let long = String(repeating: "word ", count: 2000)
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: long, maxChars: 0))
        XCTAssertGreaterThan(output.count, 5000)
        XCTAssertFalse(output.contains("truncated"))
    }

    func testTruncationCutsAtSentenceBoundary() throws {
        let input = "First sentence. Second sentence. " + String(repeating: "x", count: 200)
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: input, maxChars: 40))
        XCTAssertEqual(output, "First sentence. Second sentence. … reply truncated.")
    }

    func testTruncationWithoutSentenceBoundaryHardCuts() throws {
        let input = String(repeating: "a", count: 100)
        let output = try XCTUnwrap(CoreBridge.speechText(fromMarkdown: input, maxChars: 30))
        XCTAssertEqual(output, String(repeating: "a", count: 30) + " … reply truncated.")
    }

    func testShortTextIsUntouched() throws {
        XCTAssertEqual(try XCTUnwrap(CoreBridge.speechText(fromMarkdown: "Hi there.", maxChars: 600)), "Hi there.")
    }

    // MARK: Chinese localization

    func testChineseReplyGetsChinesePhrases() throws {
        let input = "我已经修改了这个函数。\n```python\nprint(1)\n```\n现在测试可以通过了。"
        let (text, language) = try XCTUnwrap(CoreBridge.spokenReply(fromMarkdown: input, maxChars: 0))
        XCTAssertEqual(language, "zh")
        XCTAssertTrue(text.contains("（代码已省略）"), "expected the Chinese code-omitted phrase in: \(text)")
        XCTAssertFalse(text.contains("code omitted"))
    }

    func testChineseTruncationUsesChineseSuffixAndFullWidthEnders() throws {
        let sentence = "这个函数已经被修改并且通过了所有的测试。"
        let input = String(repeating: sentence, count: 20)
        let (text, language) = try XCTUnwrap(CoreBridge.spokenReply(fromMarkdown: input, maxChars: 60))
        XCTAssertEqual(language, "zh")
        XCTAssertTrue(text.hasSuffix("……回复已截断。"), "expected the Chinese truncation suffix in: \(text)")
        // Chinese joins the suffix with no space.
        XCTAssertFalse(text.contains("。 …"))
    }

    func testCodeHeavyChineseReplyIsStillDetectedAsChinese() throws {
        // The fences are removed BEFORE detection, so ASCII identifiers inside
        // them can't swamp the letter counts.
        let input = "修改完成。\n```\n" + String(repeating: "func veryLongEnglishIdentifierName() {}\n", count: 20) + "```"
        let (_, language) = try XCTUnwrap(CoreBridge.spokenReply(fromMarkdown: input, maxChars: 0))
        XCTAssertEqual(language, "zh")
    }

    // MARK: Language detection gates

    func testShortAmbiguousStringsReturnNil() {
        // The recognizer misfiles short strings constantly ("OK" → Polish,
        // "Model: Sonnet" → German); the gate must admit "don't know".
        XCTAssertNil(CoreBridge.dominantLanguage(of: "OK"))
        XCTAssertNil(CoreBridge.dominantLanguage(of: ""))
    }

    func testClearEnglishIsDetected() {
        let text = "The build completed successfully and all of the tests passed without any failures."
        XCTAssertEqual(CoreBridge.dominantLanguage(of: text), "en")
    }

    func testCJKScriptWinsEvenInShortMixedText() {
        // Script evidence is reliable at any length: kana only writes Japanese,
        // hangul only Korean, Han with neither is Chinese.
        XCTAssertEqual(CoreBridge.dominantLanguage(of: "我修改了 parseJSON() 函数"), "zh")
        XCTAssertEqual(CoreBridge.dominantLanguage(of: "テストは全部通りました"), "ja")
        XCTAssertEqual(CoreBridge.dominantLanguage(of: "테스트가 모두 통과했습니다"), "ko")
    }

    func testEnglishQuotingACharacterOrTwoStaysEnglish() {
        let text = "The variable named 中 is renamed everywhere in the file, and the build now passes cleanly."
        XCTAssertEqual(CoreBridge.dominantLanguage(of: text), "en")
    }

    // MARK: Voice-quality exclusions

    func testSuperCompactAndLegacyVoicesAreExcluded() {
        // The robotic tiers must never be listed or resolved — including the
        // modern "super-compact" identifiers the old prefix filter missed.
        XCTAssertTrue(TTSService.isExcludedVoiceIdentifier("com.apple.voice.super-compact.en-AU.Karen"))
        XCTAssertTrue(TTSService.isExcludedVoiceIdentifier("com.apple.speech.synthesis.voice.samantha"))
        XCTAssertTrue(TTSService.isExcludedVoiceIdentifier("com.apple.eloquence.en-US.Flo"))
    }

    func testStandardCompactAndQualityVoicesAreKept() {
        // Plain "compact" is the normal default tier (Samantha, Tingting) and
        // often a language's only voice — excluding it would silence TTS.
        XCTAssertFalse(TTSService.isExcludedVoiceIdentifier("com.apple.voice.compact.en-US.Samantha"))
        XCTAssertFalse(TTSService.isExcludedVoiceIdentifier("com.apple.voice.compact.zh-CN.Tingting"))
        XCTAssertFalse(TTSService.isExcludedVoiceIdentifier("com.apple.voice.enhanced.en-US.Evan"))
        XCTAssertFalse(TTSService.isExcludedVoiceIdentifier("com.apple.voice.premium.en-US.Zoe"))
    }
}
