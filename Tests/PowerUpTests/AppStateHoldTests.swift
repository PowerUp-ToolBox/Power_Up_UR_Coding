import XCTest
@testable import PowerUp

/// AppState consuming the hold tracker's effects (ticket #131, DESIGN.md v2.7
/// addendum §C), driven through the seam with simulated pads that record
/// their output, the scripted speech engine and the fake harness:
///
/// - Two holds on the active controller cancel both: the partial capture is
///   discarded (nothing sent, nothing drafted), the pad gets the error
///   haptic, and neither release does anything afterwards.
/// - A hold press during a toggle-started capture (⌘D, the mic button) is
///   ignored, not a cancel.
/// - A Controller slot change releases a hold the outgoing pad owned.
///
/// Observable facts only: published state, the prompt box, transcript
/// entries, what the harness received, what the engine was asked to do and
/// the recorded pad output. No sleeps; the permission hop is awaited with the
/// bounded `settle(until:)`.
@MainActor
final class AppStateHoldTests: XCTestCase {

    /// AppState's one-short-buzz feedback when a capture begins.
    private static let holdBuzz = ControllerOutput.rumble(intensity: 0.5, duration: 0.05)
    /// The first of errorHaptic's two buzzes (0.9 / 60 ms). The second
    /// follows 140 ms later on AppState's injected clock, so it lands only
    /// when a test advances that clock (the environment's default clock is a
    /// `ManualRemoteTurnClock` nobody advances).
    private static let errorBuzz = ControllerOutput.rumble(intensity: 0.9, duration: 0.06)

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    override func setUpWithError() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-hold-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        config.ttsEnabled = false            // TTS is real in the seam; keep it silent.
        config.projectDir = sandbox.path     // a send needs somewhere to go
        config.hapticsEnabled = true
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
        let transcriptBaseline: Int
    }

    /// An AppState with one connected (simulated) pad recording its output,
    /// settled at `.idle` with the connect-time output flushed.
    private func makeRig(clock: (any RemoteTurnClock)? = nil,
                         _ script: (ScriptedSpeechEngine) -> Void = { _ in }) async -> Rig {
        let controller = ControllerService()
        controller.recordsOutput = true
        let engine = ScriptedSpeechEngine()
        script(engine)
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness, clock: clock)
        controller.simulateConnect()
        await settle(until: app.status == .idle)
        controller.clearRecordedOutput()
        return Rig(app: app, controller: controller, engine: engine, speech: speech,
                   harness: harness, transcriptBaseline: app.transcript.count)
    }

    private func rumbles(_ rig: Rig) -> [ControllerOutput] {
        rig.controller.recordedOutput.filter { if case .rumble = $0 { return true } else { return false } }
    }

    private func newEntries(_ rig: Rig, _ kind: TranscriptEntry.Kind) -> [String] {
        rig.app.transcript.dropFirst(rig.transcriptBaseline).filter { $0.kind == kind }.map(\.text)
    }

    private func startCaptures(_ rig: Rig) -> Int {
        rig.engine.calls.filter { if case .startCapture = $0 { return true } else { return false } }.count
    }

    /// Everything a stale release could change.
    private struct Snapshot: Equatable {
        let isPTTActive: Bool
        let isDraftDictation: Bool
        let status: AppStatus
        let draftText: String
        let transcript: [String]
        let harnessCalls: [FakeHarnessAdapter.Call]
        let engineCalls: [ScriptedSpeechEngine.Call]
        let output: [ControllerOutput]
    }

    private func snapshot(_ rig: Rig) -> Snapshot {
        Snapshot(isPTTActive: rig.app.isPTTActive,
                 isDraftDictation: rig.app.isDraftDictation,
                 status: rig.app.status,
                 draftText: rig.app.draftText,
                 transcript: rig.app.transcript.map(\.text),
                 harnessCalls: rig.harness.calls,
                 engineCalls: rig.engine.calls,
                 output: rig.controller.recordedOutput)
    }

    // MARK: - Cancel both

    func testR2ThenL2CancelsTheSendHoldWithNothingSentAndTheErrorHaptic() async {
        let rig = await makeRig {
            // The recognizer would hand this over on stop; the cancel must
            // never consult it.
            $0.finalTranscript = "Delete the whole branch."
        }
        rig.app.draftText = "typed by hand"

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.engine.emitPartial("delete the")

        rig.controller.simulateButton(.l2, pressed: true)

        XCTAssertFalse(rig.app.isPTTActive, "the second hold press ends the capture")
        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertFalse(rig.engine.isCapturing, "the recognizer is stopped")
        XCTAssertEqual(rig.app.status, .idle)
        XCTAssertTrue(rig.harness.calls.isEmpty, "nothing is sent")
        XCTAssertTrue(newEntries(rig, .user).isEmpty)
        XCTAssertEqual(rig.app.draftText, "typed by hand", "nothing is drafted")
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz], "the pad gets the error haptic")

        // Neither control's later release does anything.
        let afterCancel = snapshot(rig)
        rig.controller.simulateButton(.l2, pressed: false)
        rig.controller.simulateButton(.r2, pressed: false)
        await letPendingTasksRun()
        XCTAssertEqual(snapshot(rig), afterCancel)
        withExtendedLifetime(rig.app) {}
    }

    func testTheErrorHapticSecondBuzzLandsOnlyWhenTheClockAdvances() async {
        let clock = ManualRemoteTurnClock()
        let rig = await makeRig(clock: clock)

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.controller.simulateButton(.l2, pressed: true)
        await letPendingTasksRun()
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz],
                       "however long the main actor runs, the second buzz waits for the clock")

        clock.advance(by: 0.13)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz], "not before 140 ms")
        clock.advance(by: 0.01)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz, Self.errorBuzz],
                       "the second buzz of \"that didn't work\" lands 140 ms after the first")
        withExtendedLifetime(rig.app) {}
    }

    func testL2ThenR2CancelsTheDraftHoldAndPutsThePromptBoxBack() async {
        let rig = await makeRig { $0.finalTranscript = "rename everything." }
        rig.app.draftText = "Please"

        rig.controller.simulateButton(.l2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.engine.emitPartial("rename")
        XCTAssertEqual(rig.app.draftText, "Please rename", "partials are mirrored while the hold runs")

        rig.controller.simulateButton(.r2, pressed: true)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertFalse(rig.engine.isCapturing)
        XCTAssertEqual(rig.app.draftText, "Please", "the partial is discarded, not left in the box")
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        let afterCancel = snapshot(rig)
        rig.controller.simulateButton(.r2, pressed: false)
        rig.controller.simulateButton(.l2, pressed: false)
        // A late recognizer callback for the cancelled capture changes nothing.
        rig.engine.emitPartial("rename everything")
        await letPendingTasksRun()
        XCTAssertEqual(snapshot(rig), afterCancel)
        XCTAssertEqual(rig.app.draftText, "Please")
        withExtendedLifetime(rig.app) {}
    }

    func testTheSameTriggerPressedAgainAfterACancelStartsAFreshHold() async {
        let rig = await makeRig { $0.finalTranscript = "Run the linter." }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.controller.simulateButton(.l2, pressed: true)      // cancel
        rig.controller.simulateButton(.l2, pressed: false)
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertTrue(rig.harness.calls.isEmpty)

        rig.controller.simulateButton(.r2, pressed: true)
        XCTAssertTrue(rig.app.isPTTActive, "the owner was cleared, so the next press is a new hold")
        await settle(until: self.startCaptures(rig) == 2)
        rig.controller.simulateButton(.r2, pressed: false)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rig.harness.calls.last, .send("Run the linter."))
        XCTAssertEqual(newEntries(rig, .user), ["Run the linter."])
        withExtendedLifetime(rig.app) {}
    }

    func testCancelWhileThePermissionPromptIsUpNeverStartsRecording() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)
        rig.controller.simulateButton(.l2, pressed: true)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        rig.engine.answerPermissionPrompt(true)
        await letPendingTasksRun()

        XCTAssertEqual(startCaptures(rig), 0, "a grant after the cancel records nothing")
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertTrue(rig.harness.calls.isEmpty)
        withExtendedLifetime(rig.app) {}
    }

    // MARK: - Toggle-started capture

    func testAKeyboardDraftCaptureSurvivesAnR2Press() async {
        let rig = await makeRig { $0.finalTranscript = "explain the stack trace" }
        rig.app.draftText = "Hi"

        rig.app.toggleVoiceCapture(.draft)                    // ⌘D
        await settle(until: rig.speech.isListening)
        rig.engine.emitPartial("explain")
        rig.controller.clearRecordedOutput()

        rig.controller.simulateButton(.r2, pressed: true)
        rig.controller.simulateButton(.l2, pressed: true)

        XCTAssertTrue(rig.app.isPTTActive, "the pad never owned the keyboard capture")
        XCTAssertTrue(rig.app.isDraftDictation)
        XCTAssertTrue(rig.engine.isCapturing)
        XCTAssertEqual(rig.app.draftText, "Hi explain")
        XCTAssertTrue(rumbles(rig).isEmpty, "no cancel, so no error haptic")

        rig.controller.simulateButton(.l2, pressed: false)
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertTrue(rig.app.isPTTActive, "the releases do not end it either")
        XCTAssertTrue(rig.engine.isCapturing)

        rig.app.toggleVoiceCapture(.draft)                    // ⌘D again stops it

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rig.app.draftText, "Hi explain the stack trace")
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertTrue(rumbles(rig).isEmpty)
        withExtendedLifetime(rig.app) {}
    }

    // MARK: - Slot change

    private struct TwoPadRig {
        let rig: Rig
        let desk: ConnectedController
        let couch: ConnectedController
    }

    /// Two pads, desk first and couch second, so Automatic puts the couch in
    /// the slot.
    private func makeTwoPadRig(finalTranscript: String) async -> TwoPadRig {
        let controller = ControllerService()
        controller.recordsOutput = true
        let desk = controller.simulateConnect(name: "Desk Pad")
        let couch = controller.simulateConnect(name: "Couch Pad")
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = finalTranscript
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, harness: harness)
        await settle(until: app.status == .idle)
        XCTAssertEqual(controller.active, couch)
        controller.clearRecordedOutput()
        let rig = Rig(app: app, controller: controller, engine: engine, speech: speech,
                      harness: harness, transcriptBaseline: app.transcript.count)
        return TwoPadRig(rig: rig, desk: desk, couch: couch)
    }

    func testPinningTheOtherPadReleasesAHoldOnTheOutgoingPad() async {
        let pads = await makeTwoPadRig(finalTranscript: "Summarize the diff.")
        let rig = pads.rig

        rig.controller.simulateButton(.r2, pressed: true, on: pads.couch.id)
        await settle(until: rig.speech.isListening)

        rig.app.configStore.config.controllerDeviceID = pads.desk.id
        await settle(until: rig.controller.active == pads.desk)

        XCTAssertFalse(rig.app.isPTTActive, "the outgoing pad's hold is released")
        XCTAssertFalse(rig.engine.isCapturing, "the recognizer is not left running")
        XCTAssertEqual(rig.harness.calls.last, .send("Summarize the diff."),
                       "released as a disconnect releases it: what was heard is sent")

        // The old pad's late release is inert, and the new pad's own R2 press
        // starts a fresh hold rather than being taken for a second hold.
        let afterRelease = snapshot(rig)
        rig.controller.simulateButton(.r2, pressed: false, on: pads.couch.id)
        XCTAssertEqual(snapshot(rig), afterRelease)

        rig.controller.clearRecordedOutput()
        rig.controller.simulateButton(.r2, pressed: true, on: pads.desk.id)
        XCTAssertTrue(rig.app.isPTTActive)
        XCTAssertFalse(rumbles(rig).contains(Self.errorBuzz), "no stale owner, so no cancel")
        await settle(until: self.startCaptures(rig) == 2)
        rig.controller.simulateButton(.r2, pressed: false, on: pads.desk.id)
        XCTAssertFalse(rig.app.isPTTActive)
        withExtendedLifetime(rig.app) {}
    }

    func testASlotChangeLeavesAKeyboardCaptureAlone() async {
        let pads = await makeTwoPadRig(finalTranscript: "Why did CI fail?")
        let rig = pads.rig

        rig.app.toggleVoiceCapture(.send)                     // ⇧⌘D
        await settle(until: rig.speech.isListening)

        rig.app.configStore.config.controllerDeviceID = pads.desk.id
        await settle(until: rig.controller.active == pads.desk)

        XCTAssertTrue(rig.app.isPTTActive, "the pad never owned the keyboard capture")
        XCTAssertTrue(rig.engine.isCapturing)
        XCTAssertTrue(rig.harness.calls.isEmpty, "nothing is sent uninvited")

        rig.app.toggleVoiceCapture(.send)
        XCTAssertEqual(rig.harness.calls.last, .send("Why did CI fail?"))
        withExtendedLifetime(rig.app) {}
    }

    // MARK: - Helpers

    /// For "nothing changed" checks: `settle(until: true)` would return at once.
    private func letPendingTasksRun() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
