import XCTest
import CoreAudio
@testable import PowerUp

/// Audio device scenarios (#123, spec #94 step 1.4.2), driven through the
/// AppState seam with a scripted device list (`AudioDeviceStore`'s
/// `simulateDevices` / `simulateHotPlug` hooks), the scripted speech engine,
/// the fake harness and a simulated pad that records its output.
///
/// 1. The chosen microphone disappears mid-hold: the capture ends with the
///    error haptic and nothing reaches the agent (or the prompt box), even
///    when the recognizer still produces the half sentence.
/// 2. The chosen device disappears while idle: the next capture (and the next
///    utterance) uses the system default, and the transcript says so.
/// 3. It returns: the next capture switches back to it, under its new
///    transient id. The persisted choice never changes along the way.
///
/// Device hot-plug is delivered synchronously through the same path the
/// CoreAudio listener uses. The only asynchronous hop is AppState's
/// permission check (a main-actor Task), awaited with `settle(until:)`.
@MainActor
final class AppStateAudioDeviceScenarioTests: XCTestCase {

    private static let holdBuzz = ControllerOutput.rumble(intensity: 0.5, duration: 0.05)
    /// The first of errorHaptic's two buzzes; the second (140ms later) is never awaited.
    private static let errorBuzz = ControllerOutput.rumble(intensity: 0.9, duration: 0.06)

    // The Mac's devices, as the store would enumerate them.
    private static let builtInMic = AudioDevice(id: 10, uid: "BuiltInMicrophoneDevice",
                                                name: "MacBook Pro Microphone",
                                                inputChannels: 1, outputChannels: 0)
    private static let builtInSpeaker = AudioDevice(id: 11, uid: "BuiltInSpeakerDevice",
                                                    name: "MacBook Pro Speakers",
                                                    inputChannels: 0, outputChannels: 2)
    private static let usbMic = AudioDevice(id: 41, uid: "usb-mic-uid", name: "USB Mic",
                                            inputChannels: 1, outputChannels: 0)
    /// The same USB mic after a replug: same UID, new transient id.
    private static let usbMicReplugged = AudioDevice(id: 57, uid: "usb-mic-uid", name: "USB Mic",
                                                     inputChannels: 1, outputChannels: 0)
    private static let headphones = AudioDevice(id: 42, uid: "headphones-uid", name: "Headphones",
                                                inputChannels: 0, outputChannels: 2)
    private static let headphonesReplugged = AudioDevice(id: 58, uid: "headphones-uid", name: "Headphones",
                                                         inputChannels: 0, outputChannels: 2)
    private static let webcam = AudioDevice(id: 43, uid: "webcam-mic-uid", name: "Webcam",
                                            inputChannels: 1, outputChannels: 0)

    private var env: AppStateTestEnvironment!
    private var projectDir: URL!

    override func setUpWithError() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("powerup-audio-device-scenarios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        projectDir = sandbox
        env = try AppStateTestEnvironment(config: Self.config(projectDir: sandbox.path,
                                                              inputUID: Self.usbMic.uid,
                                                              outputUID: Self.headphones.uid))
    }

    override func tearDownWithError() throws {
        env.tearDown()
        env = nil
        if let projectDir { try? FileManager.default.removeItem(at: projectDir) }
        projectDir = nil
    }

    private static func config(projectDir: String, inputUID: String?, outputUID: String?) -> AppConfig {
        var config = AppConfig.defaultConfig()
        config.listenerToken = "test-token"
        // TTS is real in the seam; keep it silent.
        config.ttsEnabled = false
        config.projectDir = projectDir
        config.hapticsEnabled = true
        config.mapping[.r2] = .pushToTalk
        config.mapping[.l2] = .pushToTalkDraft
        config.audioInputUID = inputUID
        config.audioOutputUID = outputUID
        return config
    }

    // MARK: - Fixture

    private struct Rig {
        let app: AppState
        let controller: ControllerService
        let engine: ScriptedSpeechEngine
        let speech: SpeechService
        let harness: FakeHarnessAdapter
        let devices: AudioDeviceStore
    }

    /// An AppState whose device store starts with `devices` (what start()'s
    /// first enumeration would find), with a connected simulated pad that
    /// records its output, settled at `.idle`.
    private func makeRig(devices initial: [AudioDevice] = [builtInMic, builtInSpeaker, usbMic, headphones],
                         _ script: (ScriptedSpeechEngine) -> Void = { _ in }) async -> Rig {
        let devices = AudioDeviceStore()
        devices.simulateDevices(initial)
        let controller = ControllerService()
        controller.recordsOutput = true
        let engine = ScriptedSpeechEngine()
        script(engine)
        let speech = SpeechService(engine: engine)
        let harness = FakeHarnessAdapter()
        let app = env.makeAppState(controller: controller, speech: speech,
                                   harness: harness, audioDevices: devices)
        controller.simulateConnect()
        await settle(until: app.status == .idle)
        controller.clearRecordedOutput()
        return Rig(app: app, controller: controller, engine: engine, speech: speech,
                   harness: harness, devices: devices)
    }

    private func rumbles(_ rig: Rig) -> [ControllerOutput] {
        rig.controller.recordedOutput.filter { if case .rumble = $0 { return true } else { return false } }
    }

    private func entries(_ rig: Rig, _ kind: TranscriptEntry.Kind) -> [String] {
        rig.app.transcript.filter { $0.kind == kind }.map(\.text)
    }

    /// The input device id each capture was started with, oldest first.
    private func captureDevices(_ rig: Rig) -> [AudioDeviceID?] {
        rig.engine.calls.compactMap {
            if case .startCapture(_, _, let deviceID) = $0 { return .some(deviceID) }
            return nil
        }
    }

    /// The persisted choice as it is on disk right now.
    private func persistedConfig() throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: env.configURL))
    }

    /// One full R2 hold that hears `text` and is released.
    private func holdAndRelease(_ rig: Rig, hearing text: String) async {
        rig.engine.finalTranscript = text
        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.controller.simulateButton(.r2, pressed: false)
    }

    // MARK: - 1. The chosen microphone disappears mid-hold

    func testChosenMicUnpluggedMidHoldEndsTheCaptureWithAnErrorAndSendsNothing() async throws {
        let rig = await makeRig()

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        XCTAssertEqual(captureDevices(rig), [Self.usbMic.id], "the hold records from the chosen mic")
        rig.engine.emitPartial("delete the")
        // Whatever the recognizer still makes of the cut-off audio…
        rig.engine.finalTranscript = "Delete the"

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])

        // …the capture is over, and none of it goes anywhere.
        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.speech.isListening)
        XCTAssertFalse(rig.engine.isCapturing, "the recognizer is torn down")
        XCTAssertEqual(rig.app.status, .idle)
        XCTAssertTrue(rig.harness.calls.isEmpty, "a half sentence never reaches the agent")
        XCTAssertTrue(entries(rig, .user).isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        let errors = entries(rig, .error)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue((errors.first ?? "").contains("nothing was sent"), "says what happened: \(errors)")
        XCTAssertTrue(entries(rig, .system).contains { $0.contains("microphone disconnected") },
                      "the fallback is still announced")

        // The physical release afterwards is a no-op.
        let transcriptCount = rig.app.transcript.count
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(rig.app.transcript.count, transcriptCount)
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        // The next hold records from the system default and works end to end.
        await holdAndRelease(rig, hearing: "Run the tests.")
        XCTAssertEqual(captureDevices(rig), [Self.usbMic.id, nil])
        XCTAssertEqual(rig.harness.calls.last, .send("Run the tests."))

        XCTAssertEqual(rig.app.configStore.config.audioInputUID, Self.usbMic.uid)
        XCTAssertEqual(try persistedConfig().audioInputUID, Self.usbMic.uid)
    }

    func testChosenMicUnpluggedMidHoldSendsNothingWhenTheRecognizerEndsOnItsOwn() async {
        let rig = await makeRig()

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.engine.emitPartial("force push to")

        // The recognizer gives no final for the dead audio; it just ends.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])
        XCTAssertFalse(rig.app.isPTTActive)
        rig.engine.endRecognition()

        XCTAssertFalse(rig.speech.isListening)
        XCTAssertFalse(rig.engine.isCapturing)
        XCTAssertTrue(rig.harness.calls.isEmpty, "the last partial is not sent either")
        XCTAssertTrue(entries(rig, .user).isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz], "one error, not two")
    }

    func testTriggerStillHeldAfterAnUnplugCannotEndTheNextCapture() async {
        let rig = await makeRig()

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])
        XCTAssertFalse(rig.app.isPTTActive)

        // R2 is still down. A keyboard capture starts on the default… (The
        // aborted capture is still draining, so wait for the new start, not
        // for `isListening`.)
        rig.engine.finalTranscript = "From the keyboard."
        rig.app.toggleVoiceCapture(.send)
        await settle(until: self.captureDevices(rig).count == 2)
        XCTAssertEqual(captureDevices(rig), [Self.usbMic.id, nil])

        // …and R2's late release does not end it.
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertTrue(rig.app.isPTTActive)
        XCTAssertTrue(rig.harness.calls.isEmpty)

        rig.app.toggleVoiceCapture(.send)
        XCTAssertEqual(rig.harness.calls.last, .send("From the keyboard."))
    }

    func testChosenMicUnpluggedMidDraftHoldRestoresThePromptBox() async {
        let rig = await makeRig()
        rig.app.draftText = "Typed by hand"

        rig.controller.simulateButton(.l2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.engine.emitPartial("and then rewrite")
        XCTAssertEqual(rig.app.draftText, "Typed by hand and then rewrite", "partials mirror live")
        rig.engine.finalTranscript = "and then rewrite"

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.app.isDraftDictation)
        XCTAssertFalse(rig.engine.isCapturing)
        XCTAssertEqual(rig.app.draftText, "Typed by hand", "the half sentence is taken back out of the box")
        XCTAssertTrue(rig.harness.calls.isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        rig.controller.simulateButton(.l2, pressed: false)
        XCTAssertEqual(rig.app.draftText, "Typed by hand")
    }

    func testChosenMicUnpluggedDuringAKeyboardCaptureEndsItToo() async {
        let rig = await makeRig()

        rig.app.toggleVoiceCapture(.send)
        await settle(until: rig.speech.isListening)
        rig.engine.emitPartial("ship it")
        rig.engine.finalTranscript = "Ship it"

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])

        XCTAssertFalse(rig.app.isPTTActive)
        XCTAssertFalse(rig.engine.isCapturing)
        XCTAssertTrue(rig.harness.calls.isEmpty)
        // Every capture start buzzes once, keyboard ones too.
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz, Self.errorBuzz])

        // The next toggle starts a fresh capture rather than "stopping" the dead one.
        rig.engine.finalTranscript = "Ship it now."
        rig.app.toggleVoiceCapture(.send)
        await settle(until: rig.speech.isListening)
        XCTAssertTrue(rig.app.isPTTActive)
        rig.app.toggleVoiceCapture(.send)
        XCTAssertEqual(captureDevices(rig), [Self.usbMic.id, nil])
        XCTAssertEqual(rig.harness.calls.last, .send("Ship it now."))
    }

    func testAnotherDeviceUnpluggedMidHoldLeavesTheCaptureAlone() async {
        let rig = await makeRig(devices: [Self.builtInMic, Self.builtInSpeaker, Self.usbMic,
                                          Self.headphones, Self.webcam])

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        rig.engine.finalTranscript = "Keep going."

        // The webcam and the chosen headphones go; the chosen mic stays.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.usbMic])

        XCTAssertTrue(rig.app.isPTTActive)
        XCTAssertTrue(rig.speech.isListening)
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(rig.harness.calls.last, .send("Keep going."))
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz])
        XCTAssertTrue(entries(rig, .error).isEmpty)
    }

    func testSystemDefaultCaptureIsLeftAloneWhenDevicesChange() async throws {
        env.tearDown()
        env = try AppStateTestEnvironment(config: Self.config(projectDir: projectDir.path,
                                                              inputUID: nil, outputUID: nil))
        let rig = await makeRig()

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        XCTAssertEqual(captureDevices(rig), [nil])
        rig.engine.finalTranscript = "Still here."

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker])

        XCTAssertTrue(rig.app.isPTTActive, "no chosen mic, nothing to lose")
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(rig.harness.calls.last, .send("Still here."))
        XCTAssertTrue(entries(rig, .error).isEmpty)
        XCTAssertTrue(entries(rig, .system).isEmpty, "nothing chosen, nothing announced")
    }

    func testChosenMicUnpluggedWhileThePermissionPromptIsUpRecordsFromTheDefault() async {
        let rig = await makeRig {
            $0.authorization = .notDetermined
            $0.holdsPermissionPrompt = true
        }

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.engine.isPermissionPromptShowing)

        // Nothing was recording yet, so there is nothing to lose: the hold
        // goes on and starts on the system default once allowed.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])
        XCTAssertTrue(rig.app.isPTTActive)

        rig.engine.finalTranscript = "Hello."
        rig.engine.answerPermissionPrompt(true)
        await settle(until: rig.speech.isListening)
        XCTAssertEqual(captureDevices(rig), [nil])

        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(rig.harness.calls.last, .send("Hello."))
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz])
    }

    // MARK: - 2 & 3. Fallback while idle, and switching back on return

    func testChosenMicFallsBackToTheDefaultWhileGoneAndSwitchesBackOnReturn() async throws {
        let rig = await makeRig()

        await holdAndRelease(rig, hearing: "One.")
        XCTAssertEqual(captureDevices(rig).last, Self.usbMic.id)

        // Unplugged while idle: announced once, and the next capture uses the default.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones])
        XCTAssertEqual(entries(rig, .system).filter { $0.hasPrefix("🎤") },
                       ["🎤 Your chosen microphone disconnected — using the system default until it returns."])
        XCTAssertTrue(entries(rig, .error).isEmpty, "an idle unplug is not an error")
        XCTAssertTrue(rumbles(rig).allSatisfy { $0 == Self.holdBuzz }, "and does not buzz")

        // A second change that doesn't bring it back stays quiet.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones, Self.webcam])
        XCTAssertEqual(entries(rig, .system).filter { $0.hasPrefix("🎤") }.count, 1)

        await holdAndRelease(rig, hearing: "Two.")
        XCTAssertEqual(captureDevices(rig).last, .some(nil), "the system default")
        XCTAssertEqual(rig.harness.calls.last, .send("Two."))

        // Back, under a new transient id: announced, and used again.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones,
                                     Self.usbMicReplugged])
        XCTAssertEqual(entries(rig, .system).filter { $0.hasPrefix("🎤") }.last,
                       "🎤 USB Mic is back — using it again.")

        await holdAndRelease(rig, hearing: "Three.")
        XCTAssertEqual(captureDevices(rig), [Self.usbMic.id, nil, Self.usbMicReplugged.id])
        XCTAssertEqual(rig.harness.calls.last, .send("Three."))

        // The persisted choice never moved: in memory and on disk.
        XCTAssertEqual(rig.app.configStore.config.audioInputUID, Self.usbMic.uid)
        XCTAssertEqual(try persistedConfig().audioInputUID, Self.usbMic.uid)
        XCTAssertTrue(entries(rig, .error).isEmpty)
    }

    func testChosenSpeakerFallsBackToTheDefaultWhileGoneAndSwitchesBackOnReturn() async throws {
        let rig = await makeRig()
        let resolveOutput = { rig.app.tts.preferredOutputDeviceID?() }
        XCTAssertEqual(resolveOutput(), Self.headphones.id)

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.usbMic])
        XCTAssertNil(resolveOutput(), "nil routes speech through the system default")
        XCTAssertEqual(entries(rig, .system).filter { $0.hasPrefix("🔊") },
                       ["🔊 Your chosen speaker disconnected — speaking through the system default until it returns."])

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.usbMic,
                                     Self.headphonesReplugged])
        XCTAssertEqual(resolveOutput(), Self.headphonesReplugged.id)
        XCTAssertEqual(entries(rig, .system).filter { $0.hasPrefix("🔊") }.last,
                       "🔊 Headphones is back — speaking through it again.")

        XCTAssertEqual(rig.app.configStore.config.audioOutputUID, Self.headphones.uid)
        XCTAssertEqual(try persistedConfig().audioOutputUID, Self.headphones.uid)
        XCTAssertTrue(entries(rig, .error).isEmpty)
        XCTAssertTrue(rumbles(rig).isEmpty, "a speaker coming and going never buzzes")
    }

    func testChosenMicMissingAtLaunchRecordsFromTheDefaultWithoutAnAnnouncement() async throws {
        let rig = await makeRig(devices: [Self.builtInMic, Self.builtInSpeaker, Self.headphones])

        XCTAssertTrue(entries(rig, .system).isEmpty, "launch baselines silently")
        await holdAndRelease(rig, hearing: "Hi.")
        XCTAssertEqual(captureDevices(rig), [nil])

        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones, Self.usbMic])
        XCTAssertEqual(entries(rig, .system), ["🎤 USB Mic is back — using it again."])
        await holdAndRelease(rig, hearing: "Hi again.")
        XCTAssertEqual(captureDevices(rig), [nil, Self.usbMic.id])
        XCTAssertEqual(try persistedConfig().audioInputUID, Self.usbMic.uid)
    }

    func testCaptureOnTheDefaultWhileTheChosenMicIsGoneSurvivesOtherChanges() async {
        let rig = await makeRig(devices: [Self.builtInMic, Self.builtInSpeaker, Self.headphones])

        rig.controller.simulateButton(.r2, pressed: true)
        await settle(until: rig.speech.isListening)
        XCTAssertEqual(captureDevices(rig), [nil])
        rig.engine.finalTranscript = "Carry on."

        // The chosen mic is still missing, but this capture never used it.
        rig.devices.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker, Self.headphones, Self.webcam])

        XCTAssertTrue(rig.app.isPTTActive)
        rig.controller.simulateButton(.r2, pressed: false)
        XCTAssertEqual(rig.harness.calls.last, .send("Carry on."))
        XCTAssertTrue(entries(rig, .error).isEmpty)
        XCTAssertEqual(rumbles(rig), [Self.holdBuzz])
    }

    // MARK: - The device-list hook itself

    func testHooksUpdateTheListsAndOnlyHotPlugNotifies() {
        let store = AudioDeviceStore()
        var notified = 0
        store.onDevicesChanged = {
            notified += 1
            // The lists are already updated when the callback runs.
            XCTAssertEqual(store.inputDevices.map(\.uid), [Self.builtInMic.uid])
        }

        store.simulateDevices([Self.builtInMic, Self.builtInSpeaker, Self.usbMic])
        XCTAssertEqual(notified, 0, "the first enumeration (start) fires no change")
        XCTAssertEqual(store.inputDevices.map(\.uid), [Self.builtInMic.uid, Self.usbMic.uid])
        XCTAssertEqual(store.outputDevices.map(\.uid), [Self.builtInSpeaker.uid])
        XCTAssertEqual(store.inputDeviceID(forUID: Self.usbMic.uid), Self.usbMic.id)

        store.simulateHotPlug([Self.builtInMic, Self.builtInSpeaker])
        XCTAssertEqual(notified, 1)
        XCTAssertNil(store.inputDeviceID(forUID: Self.usbMic.uid))
        XCTAssertFalse(store.didStart, "the hooks never start the CoreAudio listener")
    }
}
