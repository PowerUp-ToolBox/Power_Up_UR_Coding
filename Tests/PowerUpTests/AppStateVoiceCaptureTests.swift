import XCTest
@testable import PowerUp

/// Voice capture driven through the AppState seam (#112): a controller hold
/// starts a capture on a `ScriptedSpeechEngine`, the release ends it, and the
/// scripted transcript lands where the hold's action says — the harness for
/// push to talk, the prompt box for dictate-to-prompt-box.
///
/// The only asynchronous step is AppState's permission check, which runs in a
/// main-actor Task; `settle(until:)` (AppStateTestSupport) yields the main actor a bounded number of
/// times for it. No sleeps, no timed expectations.
@MainActor
final class AppStateVoiceCaptureTests: XCTestCase {

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    override func setUpWithError() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-voice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        // TTS is real in the seam; keep it silent.
        config.ttsEnabled = false
        // A project is needed for a prompt to start (and reach) the session.
        config.projectDir = sandbox.path
        // Pin the hold mapping these scenarios press, rather than lean on defaults.
        config.mapping[.r2] = .pushToTalk
        config.mapping[.l2] = .pushToTalkDraft
        env = try AppStateTestEnvironment(config: config)
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
        if let projectDir { try? FileManager.default.removeItem(at: projectDir) }
        projectDir = nil
    }

    // MARK: Push to talk → harness

    func testHoldCapturesAndReleaseSendsTheTranscriptToTheHarness() async {
        let controller = ControllerService()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "Fix the failing build."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        controller.onButtonDown?(.r2)
        XCTAssertTrue(app.isPTTActive)
        await settle(until: speech.isListening)
        XCTAssertTrue(engine.isCapturing, "the hold press began a capture")
        XCTAssertTrue(harness.calls.isEmpty, "nothing is sent while holding")

        engine.emitPartial("fix the")
        XCTAssertEqual(speech.partialTranscript, "fix the")

        controller.onButtonUp?(.r2)

        XCTAssertFalse(app.isPTTActive)
        XCTAssertFalse(speech.isListening)
        XCTAssertFalse(engine.isCapturing, "the release ended the capture")
        XCTAssertEqual(harness.calls.last, .send("Fix the failing build."))
        XCTAssertEqual(harness.calls.filter(\.isStart).count, 1, "the prompt started the session first")
        XCTAssertEqual(app.transcript.last(where: { $0.kind == .user })?.text, "Fix the failing build.")
        XCTAssertEqual(app.draftText, "", "push to talk never touches the prompt box")
    }

    func testHoldWithNothingHeardSendsNothing() async {
        let controller = ControllerService()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "   "
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        controller.onButtonDown?(.r2)
        await settle(until: speech.isListening)
        controller.onButtonUp?(.r2)

        XCTAssertFalse(app.isPTTActive)
        XCTAssertTrue(harness.calls.isEmpty)
        XCTAssertFalse(app.transcript.contains(where: { $0.kind == .user }))
    }

    func testHoldWithSpeechPermissionDeniedNeverCaptures() async {
        let controller = ControllerService()
        let engine = ScriptedSpeechEngine()
        engine.authorization = .notDetermined
        engine.permissionAnswer = false
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        controller.onButtonDown?(.r2)
        await settle(until: !app.isPTTActive)

        XCTAssertEqual(engine.calls, [.requestAuthorization], "asked once, never started")
        XCTAssertFalse(speech.isListening)
        XCTAssertEqual(app.transcript.last?.kind, .error)
        XCTAssertTrue(harness.calls.isEmpty)

        // The hold was released by the denial: the trigger's release is a no-op.
        controller.onButtonUp?(.r2)
        XCTAssertTrue(harness.calls.isEmpty)
    }

    // MARK: Dictate to the prompt box

    func testDraftHoldDeliversTheTranscriptToThePromptBoxInstead() async {
        let controller = ControllerService()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "add a regression test."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)
        app.draftText = "Please"

        controller.onButtonDown?(.l2)
        XCTAssertTrue(app.isDraftDictation)
        await settle(until: speech.isListening)

        engine.emitPartial("add a")
        XCTAssertEqual(app.draftText, "Please add a", "partials are mirrored live after the typed text")

        controller.onButtonUp?(.l2)

        XCTAssertFalse(app.isPTTActive)
        XCTAssertFalse(app.isDraftDictation)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertEqual(app.draftText, "Please add a regression test.")
        XCTAssertTrue(harness.calls.isEmpty, "a draft hold never sends anything")
        XCTAssertFalse(app.transcript.contains(where: { $0.kind == .user }))
    }

    func testDraftHoldWithNothingHeardRestoresThePromptBox() async {
        let controller = ControllerService()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = nil
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)
        app.draftText = "Keep me"

        controller.onButtonDown?(.l2)
        await settle(until: speech.isListening)
        controller.onButtonUp?(.l2)
        engine.endRecognition()

        XCTAssertEqual(app.draftText, "Keep me")
        XCTAssertTrue(harness.calls.isEmpty)
    }
}

private extension FakeHarnessAdapter.Call {
    var isStart: Bool {
        if case .start = self { return true }
        return false
    }
}
