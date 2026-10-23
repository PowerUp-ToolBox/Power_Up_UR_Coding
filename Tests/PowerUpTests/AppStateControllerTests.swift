import XCTest
@testable import PowerUp

/// Controller connection rules driven through the AppState seam (#113), with
/// a simulated pad (`ControllerService.simulateConnect/-Button/-Disconnect`)
/// and its light and haptic writes recorded instead of lost.
///
/// The v2.6 rules pinned here: a pad that drops mid-hold releases the hold it
/// owned, and a capture started from the keyboard has nothing to do with the
/// pad and survives it dropping.
@MainActor
final class AppStateControllerTests: XCTestCase {

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    private static let idleBlue = ControllerOutput.light(r: 0.0, g: 0.25, b: 1.0)
    private static let listeningRed = ControllerOutput.light(r: 1.0, g: 0.0, b: 0.0)
    private static let off = ControllerOutput.light(r: 0.0, g: 0.0, b: 0.0)
    private static let tick = ControllerOutput.rumble(intensity: 0.5, duration: 0.05)
    private static let buzz = ControllerOutput.rumble(intensity: 0.9, duration: 0.06)

    override func setUpWithError() throws {
        try makeEnvironment()
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
        if let projectDir { try? FileManager.default.removeItem(at: projectDir) }
        projectDir = nil
    }

    private func makeEnvironment(_ adjust: (inout AppConfig) -> Void = { _ in }) throws {
        env?.tearDown()
        if let projectDir { try? FileManager.default.removeItem(at: projectDir) }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false            // TTS is real in the seam; keep it silent.
        config.projectDir = sandbox.path     // somewhere for a prompt to go
        config.mapping[.r2] = .pushToTalk
        config.mapping[.l2] = .pushToTalkDraft
        adjust(&config)
        env = try AppStateTestEnvironment(config: config)
    }

    private func makeRecordingController() -> ControllerService {
        let controller = ControllerService()
        controller.recordsOutput = true
        return controller
    }

    // MARK: Disconnect during a pad hold

    func testPadDroppingMidHoldEndsTheCaptureAndClearsTheHold() async {
        let controller = makeRecordingController()
        controller.simulateConnect()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "Run the tests."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        controller.simulateButton(.r2, pressed: true)
        XCTAssertTrue(app.isPTTActive)
        await settle(until: speech.isListening)
        XCTAssertTrue(engine.isCapturing)

        controller.simulateDisconnect()

        XCTAssertFalse(app.isPTTActive, "the hold the pad owned was released")
        XCTAssertFalse(speech.isListening)
        XCTAssertFalse(engine.isCapturing, "the capture ended with the pad")
        // A dropped push-to-talk hold ends like a release: what was heard is sent.
        XCTAssertEqual(harness.calls.last, .send("Run the tests."))

        // The hold is cleared: a fresh hold from a reconnected pad works.
        harness.clearCalls()
        engine.finalTranscript = "Again."
        controller.simulateConnect()
        controller.simulateButton(.r2, pressed: true)
        XCTAssertTrue(app.isPTTActive, "a new hold can start after the drop")
        await settle(until: speech.isListening)
        controller.simulateButton(.r2, pressed: false)
        XCTAssertFalse(app.isPTTActive)
        XCTAssertEqual(harness.calls.last, .send("Again."))
    }

    /// The safety net alone: the release never arrives (the service did not
    /// see the press), only the disconnect does. `forceReleaseHold` still ends
    /// the controller-owned hold, and the trigger's late release is a no-op.
    func testDisconnectAloneReleasesAControllerOwnedHold() async {
        let controller = makeRecordingController()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "Ship it."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        controller.onButtonDown?(.r2)
        await settle(until: speech.isListening)

        controller.onDisconnect?()

        XCTAssertFalse(app.isPTTActive)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertEqual(harness.calls.last, .send("Ship it."))

        let callsAfterDrop = harness.calls
        controller.onButtonUp?(.r2)
        XCTAssertEqual(harness.calls, callsAfterDrop, "the late release changes nothing")
    }

    func testPadDroppingMidDraftHoldKeepsWhatWasDictatedInThePromptBox() async {
        let controller = makeRecordingController()
        controller.simulateConnect()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "rename the module."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        controller.simulateButton(.l2, pressed: true)
        await settle(until: speech.isListening)
        controller.simulateDisconnect()

        XCTAssertFalse(app.isPTTActive)
        XCTAssertFalse(app.isDraftDictation)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertEqual(app.draftText, "rename the module.")
        XCTAssertTrue(harness.calls.isEmpty, "a draft hold never sends, even on a drop")
    }

    // MARK: Keyboard capture survives a pad drop

    func testKeyboardToggleCaptureSurvivesAPadDisconnect() async {
        let controller = makeRecordingController()
        controller.simulateConnect()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "Explain the failure."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        app.toggleVoiceCapture(.send)          // ⇧⌘D
        XCTAssertTrue(app.isPTTActive)
        await settle(until: speech.isListening)

        controller.simulateDisconnect()

        XCTAssertFalse(controller.isConnected)
        XCTAssertTrue(app.isPTTActive, "the keyboard capture is not the pad's to end")
        XCTAssertTrue(speech.isListening)
        XCTAssertTrue(engine.isCapturing)
        XCTAssertTrue(harness.calls.isEmpty, "nothing half-finished is sent on the drop")

        app.toggleVoiceCapture(.send)          // ⇧⌘D again stops it

        XCTAssertFalse(app.isPTTActive)
        XCTAssertFalse(engine.isCapturing)
        XCTAssertEqual(harness.calls.last, .send("Explain the failure."))
    }

    func testKeyboardDraftCaptureSurvivesAPadDisconnect() async {
        let controller = makeRecordingController()
        controller.simulateConnect()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "draft this."
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)

        app.toggleVoiceCapture(.draft)         // ⌘D
        await settle(until: speech.isListening)
        engine.emitPartial("draft")

        controller.simulateDisconnect()

        XCTAssertTrue(app.isPTTActive)
        XCTAssertTrue(app.isDraftDictation)
        XCTAssertTrue(engine.isCapturing)
        XCTAssertEqual(app.draftText, "draft")

        app.toggleVoiceCapture(.draft)

        XCTAssertFalse(app.isPTTActive)
        XCTAssertEqual(app.draftText, "draft this.")
        XCTAssertTrue(harness.calls.isEmpty)
    }

    // MARK: Light and haptic writes

    func testLightFollowsTheConnectionAndTheHold() async {
        let controller = makeRecordingController()
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "   "      // nothing heard: no turn starts
        let speech = SpeechService(engine: engine)
        let app = env.makeAppState(controller: controller, speech: speech, harness: FakeHarnessAdapter())

        XCTAssertEqual(app.status, .noController)
        XCTAssertEqual(controller.recordedOutput, [Self.off], "no pad: the light is pushed off")

        controller.clearRecordedOutput()
        controller.simulateConnect()
        await settle(until: app.status == .idle)
        XCTAssertEqual(controller.recordedOutput, [Self.idleBlue], "a fresh pad gets the idle color")

        controller.clearRecordedOutput()
        controller.simulateButton(.r2, pressed: true)
        XCTAssertEqual(app.status, .listening)
        XCTAssertEqual(controller.recordedOutput, [Self.listeningRed, Self.tick],
                       "a hold turns the light red and ticks the pad")
        await settle(until: speech.isListening)

        controller.clearRecordedOutput()
        controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(app.status, .idle)
        XCTAssertEqual(controller.recordedOutput, [Self.buzz, Self.idleBlue],
                       "nothing heard: the first error buzz, then back to the idle color")

        controller.clearRecordedOutput()
        controller.simulateDisconnect()
        await settle(until: app.status == .noController)
        // errorHaptic's second buzz waits on the injected clock, which this
        // test never advances, so the light is the only output.
        XCTAssertEqual(controller.recordedOutput, [Self.off],
                       "a dropped pad's light is pushed off")
    }

    func testLightAndHapticsOffInSettingsWriteNoColorAndNoRumble() async throws {
        try makeEnvironment { config in
            config.lightEnabled = false
            config.hapticsEnabled = false
        }
        let controller = makeRecordingController()
        controller.simulateConnect()
        let speech = SpeechService(engine: ScriptedSpeechEngine())
        let app = env.makeAppState(controller: controller, speech: speech, harness: FakeHarnessAdapter())

        controller.simulateButton(.r2, pressed: true)
        XCTAssertEqual(app.status, .listening)
        await settle(until: speech.isListening)
        controller.simulateButton(.r2, pressed: false)

        XCTAssertFalse(controller.recordedOutput.isEmpty)
        XCTAssertTrue(controller.recordedOutput.allSatisfy { $0 == Self.off },
                      "with the light off in Settings only 'off' is written: \(controller.recordedOutput)")
    }
}

private extension ControllerOutput {
    var isLight: Bool {
        if case .light = self { return true }
        return false
    }
}
