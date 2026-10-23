import XCTest
@testable import PowerUp

/// Voice capture scenarios (#122, spec #94 step 1.4.1), driven through the
/// AppState seam with a connected simulated pad, the scripted speech engine
/// and the fake harness:
///
/// 1. Permission granted: the hold records and the release sends.
/// 2. Permission denied before start (the answer was already "no"): the pad
///    goes back to idle with a clear message, and the recognizer is never touched.
/// 3. Permission denied after start (the prompt was answered while the hold
///    was already listening): the hold is cleared, so nothing is stranded.
/// 4. Empty final transcript: nothing is sent and the error haptic is recorded.
///
/// Observable facts only: published state, transcript entries, what the fake
/// harness received, what the engine was asked to do and the recorded pad
/// output. The only asynchronous hop is AppState's permission check, a
/// main-actor Task, awaited with the bounded `settle(until:)`. No sleeps.
@MainActor
final class AppStateCaptureScenarioTests: XCTestCase {

    /// AppState's one-short-buzz feedback when a hold begins.
    private static let holdBuzz = ControllerOutput.rumble(intensity: 0.5, duration: 0.05)
    /// The first of errorHaptic's two buzzes. The second follows 140ms later
    /// in a Task, which these tests deliberately never wait for.
    private static let errorBuzz = ControllerOutput.rumble(intensity: 0.9, duration: 0.06)

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    override func setUpWithError() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-capture-scenarios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        // TTS is real in the seam; keep it silent.
        config.ttsEnabled = false
        // A project is needed for a prompt to start (and reach) the session.
        config.projectDir = sandbox.path
        config.hapticsEnabled = true
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

    // MARK: - Fixture

    private struct Rig {
        let app: AppState
        let controller: ControllerService
        let engine: ScriptedSpeechEngine
        let speech: SpeechService
        let harness: FakeHarnessAdapter
    }

    /// An AppState with a connected (simulated) pad that records its output,
    /// settled at `.idle` with the connect-time light already flushed.
    private func makeRig(_ script: (ScriptedSpeechEngine) -> Void = { _ in }) async -> Rig {
        let controller = ControllerService()
        controller.recordsOutput = true
        let engine = ScriptedSpeechEngine()
        script(engine)
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)
        controller.simulateConnect()
        await settle(until: app.status == .idle)
        controller.clearRecordedOutput()
        return Rig(app: app, controller: controller, engine: engine, speech: speech, harness: harness)
    }

    private func rumbles(_ rig: Rig) -> [ControllerOutput] {
        rig.controller.recordedOutput.filter { if case .rumble = $0 { return true } else { return false } }
    }

    private func errorEntries(_ rig: Rig) -> [TranscriptEntry] {
        rig.app.transcript.filter { $0.kind == .error }
    }

    private func userEntries(_ rig: Rig) -> [TranscriptEntry] {
        rig.app.transcript.filter { $0.kind == .user }
    }

    private func isStartCapture(_ call: ScriptedSpeechEngine.Call) -> Bool {
        if case .startCapture = call { return true }
        return false
    }

    // MARK: - 1. Permission granted → records and sends

    func testGrantedAtThePromptRecordsAndTheReleaseSends() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)

        // The hold is live while the person reads the prompt — but nothing records yet.
        XCTAssertTrue(rig.app.isPTTActive)
        XCTAssertEqual(rig.app.status, .listening)
        XCTAssertEqual(rig.engine.calls, [.requestAuthorization])
        XCTAssertFalse(rig.engine.isCapturing)

        rig.engine.finalTranscript = "Run the test suite."
        rig.engine.answerPermissionPrompt(true)
        await settle(until: rig.speech.isListening)

        XCTAssertTrue(rig.engine.isCapturing, "a granted prompt starts the recording")
        XCTAssertTrue(rig.harness.calls.isEmpty, "nothing is sent while the trigger is held")
        rig.engine.emitPartial("run the")
        XCTAssertEqual(rig.speech.partialTranscript, "run the")

        rig.controller.simulateButton(.r2, pressed: false)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.engine.isCapturing)
        XCTAssertEqual(rig.harness.calls.last, .send("Run the test suite."))
        XCTAssertEqual(userEntries(rig).map(\.text), ["Run the test suite."])
        XCTAssertTrue(errorEntries(rig).isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz], "a successful capture never buzzes an error")
        XCTAssertEqual(rig.engine.calls.filter { $0 == .requestAuthorization }.count, 1)
    }

    func testAlreadyGrantedRecordsWithoutAskingAndTheReleaseSends() async {
        let rig = await makeRig {
            $0.authorization = .authorized
            $0.finalTranscript = "Open a pull request."
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)

        XCTAssertFalse(rig.engine.calls.contains(.requestAuthorization), "no prompt when already granted")
        XCTAssertTrue(rig.engine.calls.contains(where: isStartCapture))

        rig.controller.simulateButton(.r2, pressed: false)

        XCTAssertEqual(rig.harness.calls.last, .send("Open a pull request."))
        XCTAssertEqual(userEntries(rig).map(\.text), ["Open a pull request."])
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz])
    }

    // MARK: - 2. Permission denied before start → idle with a clear message

    func testDeniedBeforeStartLeavesThePadIdleWithAClearMessage() async {
        let rig = await makeRig { $0.authorization = .denied }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: !rig.app.isPTTActive)
        await settle(until: rig.app.status == .idle)

        XCTAssertEqual(rig.app.status, .idle, "the pad goes back to resting, not listening")
        XCTAssertTrue(rig.engine.calls.isEmpty, "an earlier 'no' is final: never asked again, never started")
        XCTAssertFalse(rig.speech.isListening)
        XCTAssertTrue(rig.harness.calls.isEmpty)

        let errors = errorEntries(rig)
        XCTAssertEqual(errors.count, 1)
        let message = errors.first?.text ?? ""
        XCTAssertTrue(message.contains("Speech Recognition"), "the message names the permission: \(message)")
        XCTAssertTrue(message.contains("System Settings"), "the message says where to fix it: \(message)")
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        // The physical release afterwards changes nothing.
        let transcriptCount = rig.app.transcript.count
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(rig.app.transcript.count, transcriptCount)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertEqual(rig.app.status, .idle)
    }

    func testDeniedBeforeStartDraftHoldLeavesThePromptBoxAlone() async {
        let rig = await makeRig { $0.authorization = .denied }
        rig.app.draftText = "Typed by hand"

        rig.controller.simulateButton(.l2, pressed: true)
        await settle(until: !rig.app.isPTTActive)

        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertEqual(rig.app.draftText, "Typed by hand")
        XCTAssertEqual(errorEntries(rig).count, 1)
        XCTAssertTrue(rig.engine.calls.isEmpty)
        XCTAssertTrue(rig.harness.calls.isEmpty)
    }

    // MARK: - 3. Permission denied after start → hold cleared

    func testDeniedAfterStartClearsTheHoldAndStrandsNothing() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)
        XCTAssertTrue(rig.app.isPTTActive, "the hold had started when the prompt went up")
        XCTAssertEqual(rig.app.status, .listening)

        // The person answers "Don't Allow" with the trigger still held.
        rig.engine.answerPermissionPrompt(false)
        await settle(until: !rig.app.isPTTActive)
        await settle(until: rig.app.status == .idle)

        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertEqual(rig.app.status, .idle)
        XCTAssertEqual(rig.engine.calls, [.requestAuthorization], "asked once, never started recording")
        XCTAssertFalse(rig.speech.isListening)
        XCTAssertEqual(errorEntries(rig).count, 1)
        XCTAssertTrue(errorEntries(rig).first?.text.contains("Speech Recognition") ?? false)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        // The person fixes the permission in System Settings and starts a
        // capture from the keyboard — with R2 STILL physically held.
        rig.engine.authorization = .authorized
        rig.engine.holdsPermissionPrompt = false
        rig.engine.finalTranscript = "Try again."
        rig.app.toggleVoiceCapture(.send)
        XCTAssertTrue(rig.app.isPTTActive)
        await settle(until: rig.speech.isListening)

        // No stranded hold, part 1: the denied hold no longer owns R2, so its
        // late release cannot end a capture it never started.
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertTrue(rig.app.isPTTActive, "R2's late release must not end the keyboard capture")
        XCTAssertTrue(rig.engine.isCapturing)
        XCTAssertTrue(rig.harness.calls.isEmpty, "half a sentence never goes out on a stale release")
        XCTAssertEqual(errorEntries(rig).count, 1)

        rig.app.toggleVoiceCapture(.send)
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rig.harness.calls.last, .send("Try again."))

        // No stranded hold, part 2: the next trigger press begins a fresh hold
        // that works end to end.
        rig.engine.finalTranscript = "Once more."
        rig.controller.simulateButton(.r2, pressed: true)
        XCTAssertTrue(rig.app.isPTTActive, "a new press is not swallowed by a leftover hold")
        await settle(until: rig.speech.isListening)
        rig.controller.simulateButton(.r2, pressed: false)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rig.harness.calls.last, .send("Once more."))
        XCTAssertEqual(errorEntries(rig).count, 1)
    }

    /// The same strand, seen from the pad: after a denial with R2 still held,
    /// the other hold trigger must be able to start its own hold.
    func testDeniedAfterStartLetsTheOtherHoldTriggerStartWhileTheFirstIsStillHeld() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)
        rig.engine.answerPermissionPrompt(false)
        await settle(until: !rig.app.isPTTActive)

        rig.engine.authorization = .authorized
        rig.engine.holdsPermissionPrompt = false
        rig.engine.finalTranscript = "draft this"
        rig.controller.simulateButton(.l2, pressed: true)
        XCTAssertTrue(rig.app.isPTTActive, "L2 is not blocked by R2's denied hold")
        XCTAssertTrue(rig.app.isDraftDictation)
        await settle(until: rig.speech.isListening)

        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertTrue(rig.app.isPTTActive, "R2's release doesn't end L2's hold")

        rig.controller.simulateButton(.l2, pressed: false)
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rig.app.draftText, "draft this")
        XCTAssertTrue(rig.harness.calls.isEmpty)
    }

    func testDeniedAfterStartDraftHoldRestoresThePromptBox() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }
        rig.app.draftText = "Half a thought"

        rig.controller.simulateButton(.l2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)
        XCTAssertTrue(rig.app.isDraftDictation)

        rig.engine.answerPermissionPrompt(false)
        await settle(until: !rig.app.isPTTActive)

        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertEqual(rig.app.draftText, "Half a thought")
        XCTAssertEqual(errorEntries(rig).count, 1)

        rig.controller.simulateButton(.l2, pressed: false)
        XCTAssertEqual(rig.app.draftText, "Half a thought")
        XCTAssertTrue(rig.harness.calls.isEmpty)
    }

    /// The other order: the trigger comes up while the prompt is still on
    /// screen. The release wins — a grant that arrives afterwards must not
    /// start a recording nobody is holding.
    func testReleaseWhilePromptIsUpThenLateGrantRecordsNothing() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertFalse(rig.app.isPTTActive)

        rig.engine.answerPermissionPrompt(true)
        // Let the permission Task finish; it has nothing left to do.
        await settle(until: !rig.engine.isPermissionPromptShowing)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(rig.engine.calls.contains(where: isStartCapture), "no recording without a hold")
        XCTAssertFalse(rig.speech.isListening)
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertTrue(userEntries(rig).isEmpty)
    }

    // MARK: - 4. Empty final transcript → nothing sent, error haptic

    func testEmptyFinalTranscriptSendsNothingAndBuzzesAnError() async {
        for (label, heard) in [("empty", ""), ("whitespace", "  \n "), ("unset", nil as String?)] {
            let rig = await makeRig { $0.finalTranscript = heard }

            rig.controller.simulateButton(.r2, pressed: true)
            await settle(until: rig.speech.isListening)
            XCTAssertEqual(rumbles(rig), [Self.holdBuzz], label)

            rig.controller.simulateButton(.r2, pressed: false)
            // With no final result scripted, the recognizer just ends.
            if heard == nil { rig.engine.endRecognition() }

            XCTAssertFalse(rig.app.isPTTActive, label)
            XCTAssertFalse(rig.engine.isCapturing, label)
            XCTAssertTrue(rig.harness.calls.isEmpty, "\(label): silence never becomes a prompt")
            XCTAssertTrue(userEntries(rig).isEmpty, label)
            XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz],
                           "\(label): the error haptic is the only feedback")
            await settle(until: rig.app.status == .idle)
            XCTAssertEqual(rig.app.status, .idle, label)
        }
    }

    func testEmptyFinalTranscriptOnADraftHoldBuzzesAndKeepsThePromptBox() async {
        let rig = await makeRig { $0.finalTranscript = "" }
        rig.app.draftText = "Keep me"

        rig.controller.simulateButton(.l2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.controller.simulateButton(.l2, pressed: false)

        XCTAssertEqual(rig.app.draftText, "Keep me")
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])
    }
}
