import XCTest
@testable import PowerUp

/// Toggle, mode and speaking scenarios (#124, spec #94 step 1.4.3), driven
/// through the AppState seam with a connected simulated pad, the scripted
/// speech engine, the fake harness and a TTS service that records instead of
/// speaking:
///
/// 1. A keyboard (or mic-button) stop while a hold trigger is still physically
///    held: the trigger's later release does nothing — and above all cannot
///    end the NEXT capture.
/// 2. Delivery by mode: a draft capture lands in the prompt box (partials live,
///    the final on release) and sends nothing; a send capture goes to the
///    harness and never touches the prompt box. Pad holds and keyboard toggles
///    deliver the same way.
/// 3. A capture started while a reply is being spoken stops the speech first:
///    the TTS stop is already recorded when the recognizer is first touched.
///
/// Observable facts only: published state, transcript entries, what the fake
/// harness received, what the engine was asked to do, what the TTS service
/// was asked to do and the recorded pad output. The only asynchronous hop is
/// AppState's permission check (a main-actor Task) and its coalesced status
/// refresh, awaited with the bounded `settle(until:)`. No sleeps.
@MainActor
final class AppStateVoiceModeScenarioTests: XCTestCase {

    /// AppState's one-short-buzz feedback when a hold begins.
    private static let holdBuzz = ControllerOutput.rumble(intensity: 0.5, duration: 0.05)

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    override func setUpWithError() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-voice-mode-scenarios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox

        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        // Spoken replies ON: the rig's TTS service records instead of
        // speaking (`recordsOutput`), so nothing is ever heard.
        config.ttsEnabled = true
        // Never a model-written summary: that would spawn a real `claude`.
        config.speakSummaries = false
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

    /// Table-driven tests build one rig per row on the same sandboxed
    /// environment; each rig has its own pad, engine, TTS and harness.
    private struct Rig {
        let app: AppState
        let controller: ControllerService
        let engine: ScriptedSpeechEngine
        let speech: SpeechService
        let tts: TTSService
        let harness: FakeHarnessAdapter
        /// Entries already in the transcript when the rig was built: a later
        /// row reloads the earlier rows' history from the shared sandbox.
        let transcriptBaseline: Int
    }

    /// An AppState with a connected (simulated) pad and a silent, recording
    /// TTS service, settled at `.idle` with the connect-time output flushed.
    private func makeRig(_ script: (ScriptedSpeechEngine) -> Void = { _ in }) async -> Rig {
        let controller = ControllerService()
        controller.recordsOutput = true
        let engine = ScriptedSpeechEngine()
        script(engine)
        let speech = SpeechService(engine: engine)
        let tts = TTSService()
        // Before AppState exists, so not even a start-up phrase reaches the speaker.
        tts.recordsOutput = true
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech, tts: tts, harness: harness)
        controller.simulateConnect()
        await settle(until: app.status == .idle)
        controller.clearRecordedOutput()
        tts.clearRecordedOutput()
        return Rig(app: app, controller: controller, engine: engine, speech: speech, tts: tts, harness: harness,
                   transcriptBaseline: app.transcript.count)
    }

    /// Everything a stale release could disturb, captured at one moment.
    private struct Snapshot: Equatable {
        let isPTTActive: Bool
        let isDraftDictation: Bool
        let status: AppStatus
        let draftText: String
        let transcript: [String]
        let harnessCalls: [FakeHarnessAdapter.Call]
        let engineCalls: [ScriptedSpeechEngine.Call]
        let isCapturing: Bool
        let padOutput: [ControllerOutput]
    }

    private func snapshot(_ rig: Rig) -> Snapshot {
        Snapshot(isPTTActive: rig.app.isPTTActive,
                 isDraftDictation: rig.app.isDraftDictation,
                 status: rig.app.status,
                 draftText: rig.app.draftText,
                 transcript: rig.app.transcript.map { "\($0.kind):\($0.text)" },
                 harnessCalls: rig.harness.calls,
                 engineCalls: rig.engine.calls,
                 isCapturing: rig.engine.isCapturing,
                 padOutput: rig.controller.recordedOutput)
    }

    /// Gives any main-actor Task a stale release might have scheduled a
    /// bounded chance to run (the same 100 yields `settle` allows), so a
    /// "nothing changed" check is not passing just because it looked too early.
    private func letPendingTasksRun() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func userEntries(_ rig: Rig) -> [String] {
        rig.app.transcript.dropFirst(rig.transcriptBaseline).filter { $0.kind == .user }.map(\.text)
    }

    private func sends(_ rig: Rig) -> [String] {
        rig.harness.calls.compactMap { if case .send(let text) = $0 { return text } else { return nil } }
    }

    private func startCaptureCount(_ rig: Rig) -> Int {
        rig.engine.calls.filter { if case .startCapture = $0 { return true } else { return false } }.count
    }

    // MARK: - 1. Keyboard stop while the trigger is still held

    func testKeyboardStopWhileTriggerHeldThenReleaseIsANoOp() async {
        let rig = await makeRig { $0.finalTranscript = "Run the linter." }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isCapturing)
        rig.engine.emitPartial("run the")

        // ⇧⌘D with R2 still physically down: the keyboard ends the capture
        // and the capture delivers as what it is — a send.
        rig.app.toggleVoiceCapture(.send)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.engine.isCapturing)
        XCTAssertEqual(sends(rig), ["Run the linter."])
        XCTAssertEqual(userEntries(rig), ["Run the linter."])
        await settle(until: rig.app.status == .thinking)

        let before = snapshot(rig)
        rig.controller.simulateButton(.r2, pressed: false)
        await letPendingTasksRun()

        XCTAssertEqual(snapshot(rig), before, "the late release changes nothing at all")
        XCTAssertEqual(sends(rig), ["Run the linter."], "never a second send")
    }

    func testLateReleaseCannotEndTheNextKeyboardCapture() async {
        let rig = await makeRig { $0.finalTranscript = "First thought." }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isCapturing)
        rig.app.toggleVoiceCapture(.send)                  // stop from the keyboard
        XCTAssertEqual(sends(rig), ["First thought."])

        // Next capture from the keyboard, R2 still held from before.
        rig.engine.finalTranscript = "Second thought."
        rig.app.toggleVoiceCapture(.send)
        XCTAssertTrue(rig.app.isPTTActive)
        await settle(until: self.startCaptureCount(rig) == 2)
        rig.engine.emitPartial("second")

        let engineCallsBefore = rig.engine.calls
        rig.controller.simulateButton(.r2, pressed: false)

        XCTAssertTrue(rig.app.isPTTActive, "R2's late release must not end a capture it did not start")
        XCTAssertEqual(rig.app.status, .listening)
        XCTAssertTrue(rig.engine.isCapturing)
        XCTAssertEqual(rig.engine.calls, engineCallsBefore, "the recognizer is not told to stop")
        XCTAssertEqual(sends(rig), ["First thought."], "half a sentence never goes out on a stale release")

        rig.app.toggleVoiceCapture(.send)                  // the real stop
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(sends(rig), ["First thought.", "Second thought."])
    }

    func testLateReleaseCannotEndTheOtherTriggersHold() async {
        let rig = await makeRig { $0.finalTranscript = "Send this." }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isCapturing)
        rig.app.toggleVoiceCapture(.send)
        XCTAssertEqual(sends(rig), ["Send this."])

        // L2 is pressed while R2 is still down: the keyboard stop released
        // R2's ownership, so L2 starts its own hold.
        rig.engine.finalTranscript = "draft this"
        rig.controller.simulateButton(.l2, pressed: true)
        XCTAssertTrue(rig.app.isPTTActive, "L2 is not blocked by R2's stopped hold")
        XCTAssertTrue(rig.app.isDraftDictation)
        await settle(until: self.startCaptureCount(rig) == 2)

        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertTrue(rig.app.isPTTActive, "R2's release doesn't end L2's hold")
        XCTAssertTrue(rig.engine.isCapturing)

        rig.controller.simulateButton(.l2, pressed: false)
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(rig.app.draftText, "draft this")
        XCTAssertEqual(sends(rig), ["Send this."])
    }

    func testKeyboardStopOfADraftHoldLandsInThePromptBoxAndTheReleaseIsANoOp() async {
        let rig = await makeRig { $0.finalTranscript = "rename the module." }
        rig.app.draftText = "Please"

        rig.controller.simulateButton(.l2, pressed: true)
        await settle(until: rig.engine.isCapturing)
        rig.engine.emitPartial("rename the")
        XCTAssertEqual(rig.app.draftText, "Please rename the")

        rig.app.toggleVoiceCapture(.draft)                 // ⌘D, L2 still held

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertEqual(rig.app.draftText, "Please rename the module.")
        XCTAssertTrue(rig.harness.calls.isEmpty)
        await settle(until: rig.app.status == .idle)

        let before = snapshot(rig)
        rig.controller.simulateButton(.l2, pressed: false)
        await letPendingTasksRun()

        XCTAssertEqual(snapshot(rig), before)
        XCTAssertEqual(rig.app.draftText, "Please rename the module.", "the box is not rewritten or restored")
    }

    /// The stop affordance ends whatever capture is live: a ⌘D (draft key)
    /// press stops an R2 SEND hold, and the capture still delivers as a send.
    func testTheStoppingKeysModeDoesNotChangeHowTheCaptureDelivers() async {
        let rig = await makeRig { $0.finalTranscript = "Deploy to staging." }
        rig.app.draftText = "Typed by hand"

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isCapturing)
        rig.app.toggleVoiceCapture(.draft)

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertEqual(sends(rig), ["Deploy to staging."])
        XCTAssertEqual(rig.app.draftText, "Typed by hand")

        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(sends(rig), ["Deploy to staging."])
        XCTAssertFalse(rig.app.isPTTActive)
    }

    // MARK: - 2. Draft versus send delivery

    private enum Starter: CaseIterable {
        case padHold, keyboardToggle
    }

    private func begin(_ rig: Rig, _ mode: VoiceCaptureMode, via starter: Starter) {
        switch starter {
        case .padHold:
            rig.controller.simulateButton(mode == .draft ? .l2 : .r2, pressed: true)
        case .keyboardToggle:
            rig.app.toggleVoiceCapture(mode)
        }
    }

    private func end(_ rig: Rig, _ mode: VoiceCaptureMode, via starter: Starter) {
        switch starter {
        case .padHold:
            rig.controller.simulateButton(mode == .draft ? .l2 : .r2, pressed: false)
        case .keyboardToggle:
            rig.app.toggleVoiceCapture(mode)
        }
    }

    func testDraftDeliveryMirrorsPartialsAndLandsTheFinalInThePromptBox() async {
        for starter in Starter.allCases {
            let rig = await makeRig { $0.finalTranscript = "Add a regression test." }
            rig.app.draftText = "Then"

            begin(rig, .draft, via: starter)
            XCTAssertTrue(rig.app.isDraftDictation, "\(starter)")
            await settle(until: rig.engine.isCapturing)
            XCTAssertEqual(rig.app.status, .listening, "\(starter)")

            rig.engine.emitPartial("add a")
            XCTAssertEqual(rig.app.draftText, "Then add a", "\(starter): partials appear as spoken")
            rig.engine.emitPartial("add a regression")
            XCTAssertEqual(rig.app.draftText, "Then add a regression", "\(starter): each partial replaces the last")

            end(rig, .draft, via: starter)

            XCTAssertFalse(rig.app.isPTTActive, "\(starter)")
            XCTAssertFalse(rig.engine.isCapturing, "\(starter)")
            XCTAssertEqual(rig.app.draftText, "Then Add a regression test.",
                           "\(starter): the recognizer's final replaces the partial, after the typed text")
            XCTAssertTrue(rig.harness.calls.isEmpty, "\(starter): a draft capture never sends")
            XCTAssertTrue(userEntries(rig).isEmpty, "\(starter)")
            await settle(until: rig.app.status == .idle)
        }
    }

    func testDraftDeliveryFallsBackToTheLastPartialWhenNoFinalArrives() async {
        for starter in Starter.allCases {
            let rig = await makeRig { $0.finalTranscript = nil }

            begin(rig, .draft, via: starter)
            await settle(until: rig.engine.isCapturing)
            rig.engine.emitPartial("check the logs")
            end(rig, .draft, via: starter)
            rig.engine.endRecognition()           // the recognizer goes quiet without a final

            XCTAssertEqual(rig.app.draftText, "check the logs", "\(starter)")
            XCTAssertTrue(rig.harness.calls.isEmpty, "\(starter)")
        }
    }

    func testSendDeliveryGoesToTheHarnessAndNeverTouchesThePromptBox() async {
        for starter in Starter.allCases {
            let rig = await makeRig { $0.finalTranscript = "Open a pull request." }
            rig.app.draftText = "Half-typed note"

            begin(rig, .send, via: starter)
            XCTAssertFalse(rig.app.isDraftDictation, "\(starter)")
            await settle(until: rig.engine.isCapturing)

            rig.engine.emitPartial("open a pull")
            XCTAssertEqual(rig.app.draftText, "Half-typed note", "\(starter): partials never reach the box")
            XCTAssertTrue(rig.harness.calls.isEmpty, "\(starter): nothing is sent mid-capture")

            end(rig, .send, via: starter)

            XCTAssertFalse(rig.app.isPTTActive, "\(starter)")
            XCTAssertEqual(rig.harness.calls.first.map { if case .start = $0 { return true } else { return false } },
                           true, "\(starter): the first prompt starts the session")
            XCTAssertEqual(sends(rig), ["Open a pull request."], "\(starter)")
            XCTAssertEqual(userEntries(rig), ["Open a pull request."], "\(starter)")
            XCTAssertEqual(rig.app.draftText, "Half-typed note", "\(starter): the box is left as typed")
            await settle(until: rig.app.status == .thinking)
        }
    }

    // MARK: - 3. A capture started while a reply is spoken stops the speech first

    /// Gets the rig to "a reply is being spoken": a prompt goes out and the
    /// turn completes with a short reply, which AppState reads aloud.
    private func speakAReply(_ rig: Rig, _ reply: String) async {
        rig.app.sendUserText("What changed?")
        rig.harness.emit(.turnCompleted(resultText: reply, costUSD: nil, isError: false, detail: "success"))
        await settle(until: rig.app.status == .speaking)
        rig.tts.clearRecordedOutput()
        rig.controller.clearRecordedOutput()
    }

    private enum CaptureStart: CaseIterable {
        case padSendHold, padDraftHold, keyboardSend, keyboardDraft
    }

    private func start(_ rig: Rig, _ how: CaptureStart) {
        switch how {
        case .padSendHold: rig.controller.simulateButton(.r2, pressed: true)
        case .padDraftHold: rig.controller.simulateButton(.l2, pressed: true)
        case .keyboardSend: rig.app.toggleVoiceCapture(.send)
        case .keyboardDraft: rig.app.toggleVoiceCapture(.draft)
        }
    }

    func testCaptureStartedWhileSpeakingStopsTheSpeechBeforeTheCaptureBegins() async {
        for how in CaptureStart.allCases {
            let rig = await makeRig { $0.authorization = .authorized }
            await speakAReply(rig, "All tests pass.")
            XCTAssertTrue(rig.tts.isSpeaking, "\(how)")

            // What the TTS service had been asked to do, at the moment the
            // recognizer was first touched.
            var ttsAtFirstEngineCall: [TTSOutput]?
            var speakingAtFirstEngineCall: Bool?
            rig.engine.onCall = { [tts = rig.tts] _ in
                guard ttsAtFirstEngineCall == nil else { return }
                ttsAtFirstEngineCall = tts.recordedOutput
                speakingAtFirstEngineCall = tts.isSpeaking
            }

            start(rig, how)

            // Synchronously, before the capture's permission hop runs.
            XCTAssertEqual(rig.tts.recordedOutput, [.stop], "\(how): speech is stopped on the press itself")
            XCTAssertFalse(rig.tts.isSpeaking, "\(how)")
            XCTAssertTrue(rig.engine.calls.isEmpty, "\(how): the recognizer has not been touched yet")
            XCTAssertEqual(rig.controller.recordedOutput.filter(\.isRumble), [Self.holdBuzz], "\(how)")
            await settle(until: rig.app.status == .listening)

            await settle(until: rig.engine.isCapturing)
            XCTAssertEqual(ttsAtFirstEngineCall, [.stop], "\(how): the TTS stop is recorded before the capture begins")
            XCTAssertEqual(speakingAtFirstEngineCall, false, "\(how)")
            XCTAssertFalse(rig.tts.recordedOutput.contains { if case .speak = $0 { return true } else { return false } },
                           "\(how): nothing starts speaking during the capture")
            rig.engine.onCall = nil

            // The reply never resumes on its own while recording.
            rig.engine.emitPartial("and now")
            XCTAssertEqual(rig.app.status, .listening, "\(how)")
            XCTAssertFalse(rig.tts.isSpeaking, "\(how)")
        }
    }

    /// The permission prompt comes after the stop too: the speech does not
    /// talk over the system's "allow speech recognition?" moment.
    func testSpeechIsStoppedBeforeThePermissionPromptIsShown() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }
        await speakAReply(rig, "Done.")

        var ttsAtPrompt: [TTSOutput]?
        rig.engine.onCall = { [tts = rig.tts] call in
            if call == .requestAuthorization { ttsAtPrompt = tts.recordedOutput }
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)

        XCTAssertEqual(ttsAtPrompt, [.stop])
        XCTAssertEqual(rig.app.status, .listening)

        rig.engine.answerPermissionPrompt(true)
        await settle(until: rig.engine.isCapturing)
        rig.controller.simulateButton(.r2, pressed: false)
        rig.engine.endRecognition()
    }

    /// Sanity check of the rig: with no capture, a spoken reply simply plays
    /// out and the status returns to idle when the synthesizer finishes.
    func testWithoutACaptureTheReplyPlaysOutAndStatusReturnsToIdle() async {
        let rig = await makeRig()
        await speakAReply(rig, "All tests pass.")

        XCTAssertEqual(rig.app.status, .speaking)
        rig.tts.finishRecordedSpeech()
        await settle(until: rig.app.status == .idle)
        XCTAssertTrue(rig.tts.recordedOutput.isEmpty, "nothing stopped it")
    }

    func testTheSpokenReplyIsTheTurnsResult() async {
        let rig = await makeRig()
        rig.app.sendUserText("What changed?")
        rig.harness.emit(.turnCompleted(resultText: "All tests pass.", costUSD: nil, isError: false, detail: "success"))

        XCTAssertEqual(rig.tts.recordedOutput, [.speak("All tests pass.")])
    }
}

private extension ControllerOutput {
    var isRumble: Bool {
        if case .rumble = self { return true }
        return false
    }
}
