import XCTest
@testable import PowerUp

/// What AppState speaks for a completed reply (spec #100 slice 2.5, #160),
/// driven through the AppState seam with the fake harness, a simulated pad
/// and a TTS service that records instead of speaking: the spoken text is
/// the Rust core's (`CoreBridgeSpeech.swift`), the threshold, the prompt and
/// the summary check are the core's, and AppState carries out the rest —
/// the summary request, the "Summary: …" entry, the fallbacks to the full
/// reply, Replay and its error buzz.
///
/// The summarizer is a `/bin/sh` script this test writes, never a real
/// `claude`: `config.claudePath` points at it and
/// `ClaudeService.resolveClaudeBinary` takes a runnable override before any
/// other lookup (a test refuses to start when the script is not runnable).
/// It logs its argv and stdin and prints the summary the test gave it.
/// Nothing is heard: `recordsOutput` replaces the synthesizer.
@MainActor
final class AppStateSpokenReplyTests: XCTestCase {

    /// AppState's error haptic, first buzz (the second waits on the clock).
    private static let errorBuzz = ControllerOutput.rumble(intensity: 0.9, duration: 0.06)

    /// At least 350 Characters, so with summaries on it goes to the
    /// summarizer. No surrounding whitespace: the session trims a turn's
    /// result before it is spoken or kept for Replay.
    private static let longReply = "## Done\n\n"
        + String(repeating: "The parser now handles every **edge** case. ", count: 10)
        + "Nothing else changed."

    private static let script = #"""
    #!/bin/sh
    LOG='@LOG@'
    for arg in "$@"; do
      # A summary is one-shot text out; anything else is not this test's call.
      [ "$arg" = "stream-json" ] && exit 1
    done
    n=$(cat "$LOG/count" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$LOG/count"
    : > "$LOG/argv-$n.txt"
    for arg in "$@"; do printf '%s\n' "$arg" >> "$LOG/argv-$n.txt"; done
    cat > "$LOG/stdin-$n.txt"
    cat "$LOG/summary.txt"
    """#

    private var env: AppStateTestEnvironment!
    private var root: URL!
    private var logDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-spoken-reply-\(UUID().uuidString)", isDirectory: true)
        logDirectory = root.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        env?.tearDown()
        env = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: Fixture

    private struct Rig {
        let app: AppState
        let controller: ControllerService
        let tts: TTSService
        let harness: FakeHarnessAdapter
    }

    /// An AppState with spoken replies on, a connected (simulated) pad and
    /// the fake summarizer as its `claude`, settled at `.idle` with the
    /// connect-time output flushed.
    private func makeRig(speakSummaries: Bool = false, maxSpokenChars: Int = 0,
                         summary: String = "") async throws -> Rig {
        let scriptURL = root.appendingPathComponent("fake-claude")
        try Self.script.replacingOccurrences(of: "@LOG@", with: logDirectory.path)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        // Never let the lookup fall through to a real claude.
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("the fake summarizer script could not be made executable")
        }
        try summary.write(to: logDirectory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.projectDir = root.path
        config.claudePath = scriptURL.path
        config.ttsEnabled = true
        config.speakSummaries = speakSummaries
        config.summaryModel = "haiku"
        config.maxSpokenChars = maxSpokenChars
        config.hapticsEnabled = true
        env = try AppStateTestEnvironment(config: config)

        let controller = ControllerService()
        controller.recordsOutput = true
        let tts = TTSService()
        tts.recordsOutput = true
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, tts: tts, harness: harness)
        controller.simulateConnect()
        await settle(until: app.status == .idle)
        controller.clearRecordedOutput()
        tts.clearRecordedOutput()
        return Rig(app: app, controller: controller, tts: tts, harness: harness)
    }

    private func completeATurn(_ rig: Rig, replying reply: String) {
        rig.app.sendUserText("What changed?")
        rig.harness.emit(.turnCompleted(resultText: reply, costUSD: nil, isError: false, detail: "success"))
    }

    private func file(_ name: String) -> String? {
        try? String(contentsOf: logDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private var launches: Int {
        Int(file("count")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Polls with 100 ms sleeps, because the summarizer is a real process;
    /// bounded, so a broken path fails instead of hanging.
    private func waitForSpeech(_ rig: Rig, timeout: TimeInterval = 10) async throws {
        var elapsed: TimeInterval = 0
        while rig.tts.recordedOutput.isEmpty, elapsed < timeout {
            try await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 0.1
        }
        guard !rig.tts.recordedOutput.isEmpty else {
            throw Timeout(description: "nothing was spoken; transcript: \(rig.app.transcript.map(\.text))")
        }
    }

    private struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private func spokenText(of reply: String, maxChars: Int) throws -> String {
        try XCTUnwrap(CoreBridge.speechText(fromMarkdown: reply, maxChars: maxChars))
    }

    // MARK: The full reply

    func testAMarkdownReplyIsSpokenAsTheCoresSpeechText() async throws {
        let rig = try await makeRig()
        completeATurn(rig, replying: "Here is the fix:\n```swift\nlet x = 1\n```\n**All** done.")

        XCTAssertEqual(rig.tts.recordedOutput, [.speak("Here is the fix: code omitted All done.")])
    }

    func testALongReplyIsCutAfterItsLastSentenceInTheLimit() async throws {
        let rig = try await makeRig(maxSpokenChars: 40)
        completeATurn(rig, replying: "First sentence. Second sentence. " + String(repeating: "x", count: 200))

        XCTAssertEqual(rig.tts.recordedOutput, [.speak("First sentence. Second sentence. … reply truncated.")])
    }

    func testAChineseReplyIsSpokenWithTheChinesePhrases() async throws {
        let rig = try await makeRig()
        completeATurn(rig, replying: "我已经修改了这个函数。\n```python\nprint(1)\n```\n现在测试可以通过了。")

        XCTAssertEqual(rig.tts.recordedOutput, [.speak("我已经修改了这个函数。 （代码已省略） 现在测试可以通过了。")])
    }

    // MARK: Replay

    func testReplaySpeaksTheWholeReplyAgain() async throws {
        let rig = try await makeRig()
        let reply = "Use `swift build` to **compile** the [project](https://example.com)."
        completeATurn(rig, replying: reply)
        rig.tts.finishRecordedSpeech()
        rig.tts.clearRecordedOutput()

        rig.app.speakLastReply()

        XCTAssertEqual(rig.tts.recordedOutput, [.speak("Use swift build to compile the project.")])
    }

    func testAReplyOfOnlyMarkupSpeaksNothingAndItsReplayBuzzes() async throws {
        let rig = try await makeRig()
        completeATurn(rig, replying: "***")
        XCTAssertEqual(rig.tts.recordedOutput, [], "nothing speakable: nothing is spoken")
        rig.controller.clearRecordedOutput()

        rig.app.speakLastReply()

        XCTAssertEqual(rig.tts.recordedOutput, [])
        XCTAssertEqual(rig.controller.recordedOutput.filter(\.isRumble), [Self.errorBuzz])
    }

    // MARK: Spoken summaries

    func testWithSummariesOnAReplyUnder350CharactersIsSpokenInFull() async throws {
        let rig = try await makeRig(speakSummaries: true, summary: "A summary.")
        let reply = String(repeating: "é", count: 349)
        completeATurn(rig, replying: reply)

        XCTAssertEqual(rig.tts.recordedOutput, [.speak(reply)])
        XCTAssertEqual(launches, 0, "no summarizer runs for a short reply")
    }

    func testALongReplySpeaksItsSummaryStrippedAndLogsItAsWritten() async throws {
        let summary = "**Fixed** the `parser`; run the tests.\n"
        let rig = try await makeRig(speakSummaries: true, maxSpokenChars: 40, summary: summary)
        completeATurn(rig, replying: Self.longReply)
        XCTAssertEqual(rig.tts.recordedOutput, [], "the summary is awaited, the reply not spoken")

        try await waitForSpeech(rig)

        // Markdown-stripped but never cut, though the limit is 40.
        XCTAssertEqual(rig.tts.recordedOutput, [.speak("Fixed the parser; run the tests.")])
        XCTAssertEqual(rig.app.transcript.filter { $0.kind == .system }.map(\.text).last,
                       "Summary: **Fixed** the `parser`; run the tests.")
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(file("argv-1.txt"),
                       SummaryService.arguments(model: "haiku").map { $0 + "\n" }.joined())
        XCTAssertEqual(file("stdin-1.txt"), try XCTUnwrap(CoreBridge.summaryPrompt(for: Self.longReply)),
                       "the summarizer reads the core's prompt")
        XCTAssertEqual(rig.app.lastAssistantReply, Self.longReply, "Replay keeps the full reply")
    }

    func testASummaryNoShorterThanTheReplyFallsBackToTheFullReply() async throws {
        let rig = try await makeRig(speakSummaries: true, summary: Self.longReply)
        completeATurn(rig, replying: Self.longReply)

        try await waitForSpeech(rig)

        XCTAssertEqual(rig.tts.recordedOutput, [.speak(try spokenText(of: Self.longReply, maxChars: 0))])
        XCTAssertFalse(rig.app.transcript.contains { $0.text.hasPrefix("Summary:") },
                       "an unusable summary is never logged")
    }

    func testASummaryOfOnlyMarkupFallsBackToTheFullReply() async throws {
        let rig = try await makeRig(speakSummaries: true, maxSpokenChars: 100, summary: "***")
        completeATurn(rig, replying: Self.longReply)

        try await waitForSpeech(rig)

        XCTAssertEqual(rig.tts.recordedOutput, [.speak(try spokenText(of: Self.longReply, maxChars: 100))])
        XCTAssertEqual(rig.app.transcript.filter { $0.kind == .system }.map(\.text).last, "Summary: ***")
    }
}

private extension ControllerOutput {
    var isRumble: Bool {
        if case .rumble = self { return true }
        return false
    }
}
