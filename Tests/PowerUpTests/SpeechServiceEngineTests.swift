import XCTest
import CoreAudio
@testable import PowerUp

/// SpeechService's capture lifecycle (DESIGN.md "Module: Speech", v2.5 C)
/// driven through its speech engine seam (#112) with a `ScriptedSpeechEngine`:
/// no microphone, no recognizer, no permission prompt, no waits.
@MainActor
final class SpeechServiceEngineTests: XCTestCase {

    // MARK: Permission

    func testAlreadyAuthorizedNeverPrompts() async {
        let engine = ScriptedSpeechEngine()
        engine.authorization = .authorized
        let speech = SpeechService(engine: engine)

        let granted = await speech.requestPermissionsIfNeeded()

        XCTAssertTrue(granted)
        XCTAssertEqual(speech.authState, .authorized)
        XCTAssertFalse(engine.calls.contains(.requestAuthorization))
    }

    func testDeniedNeverPrompts() async {
        let engine = ScriptedSpeechEngine()
        engine.authorization = .denied
        let speech = SpeechService(engine: engine)

        let granted = await speech.requestPermissionsIfNeeded()

        XCTAssertFalse(granted)
        XCTAssertEqual(speech.authState, .denied)
        XCTAssertFalse(engine.calls.contains(.requestAuthorization))
    }

    func testUndeterminedAsksAndTakesTheAnswer() async {
        let engine = ScriptedSpeechEngine()
        engine.authorization = .notDetermined
        engine.permissionAnswer = false
        let speech = SpeechService(engine: engine)

        let granted = await speech.requestPermissionsIfNeeded()

        XCTAssertFalse(granted)
        XCTAssertEqual(speech.authState, .denied)
        XCTAssertEqual(engine.calls, [.requestAuthorization])
    }

    // MARK: Start

    func testStartUsesTheConfiguredLocaleAndChosenMicrophone() {
        let engine = ScriptedSpeechEngine()
        let speech = SpeechService(engine: engine)
        speech.configure(localeID: "fr-FR", onDevice: true)
        speech.preferredInputDeviceID = { AudioDeviceID(42) }

        speech.startListening()

        XCTAssertTrue(speech.isListening)
        XCTAssertEqual(speech.partialTranscript, "")
        XCTAssertEqual(engine.calls, [.prepareRecognizer(localeID: "fr-FR"),
                                      .startCapture(localeID: "fr-FR", onDevice: true, inputDeviceID: 42)])
    }

    func testUnavailableRecognizerLeavesAHintAndDoesNotListen() {
        let engine = ScriptedSpeechEngine()
        engine.isRecognizerAvailable = false
        let speech = SpeechService(engine: engine)

        speech.startListening()

        XCTAssertFalse(speech.isListening)
        XCTAssertEqual(speech.partialTranscript, "Speech recognition unavailable for this locale.")
        XCTAssertFalse(engine.isCapturing)
    }

    func testStartWithoutPermissionLeavesAHintAndMarksDenied() {
        let engine = ScriptedSpeechEngine()
        engine.authorization = .notDetermined
        let speech = SpeechService(engine: engine)

        speech.startListening()

        XCTAssertFalse(speech.isListening)
        XCTAssertEqual(speech.authState, .denied)
        XCTAssertEqual(speech.partialTranscript, "Speech recognition permission not granted.")
        XCTAssertFalse(engine.isCapturing)
    }

    func testCaptureStartFailuresLeaveFriendlyHints() {
        let cases: [(SpeechEngineStartFailure, String)] = [
            (.noMicrophoneInput, "No microphone input is available — check System Settings → Sound → Input."),
            (.audioEngineFailed, "Could not start audio engine.")
        ]
        for (failure, hint) in cases {
            let engine = ScriptedSpeechEngine()
            engine.startFailure = failure
            let speech = SpeechService(engine: engine)

            speech.startListening()

            XCTAssertFalse(speech.isListening, "\(failure)")
            XCTAssertEqual(speech.partialTranscript, hint)
        }
    }

    // MARK: Partials and stop

    func testPartialsAreLiveAndTheFinalResultResolvesTheStop() {
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "  Run the tests.  "
        let speech = SpeechService(engine: engine)

        speech.startListening()
        engine.emitPartial("run the")
        XCTAssertEqual(speech.partialTranscript, "run the")

        var results: [String?] = []
        speech.stopListening { results.append($0) }

        XCTAssertEqual(results, ["Run the tests."], "trimmed, delivered exactly once")
        XCTAssertFalse(speech.isListening)
        XCTAssertEqual(speech.partialTranscript, "")
        XCTAssertFalse(engine.isCapturing, "the capture is torn down on every stop")
        XCTAssertEqual(Array(engine.calls.suffix(2)), [.endAudio, .stopCapture])
    }

    func testRecognizerFinalizingMidHoldResolvesTheReleaseImmediately() {
        let engine = ScriptedSpeechEngine()
        let speech = SpeechService(engine: engine)

        speech.startListening()
        engine.emitFinal("Already final.")
        XCTAssertTrue(speech.isListening, "a final result while still held keeps listening")

        var results: [String?] = []
        speech.stopListening { results.append($0) }

        XCTAssertEqual(results, ["Already final."])
        XCTAssertFalse(engine.calls.contains(.endAudio), "nothing more is coming, so the audio is not ended first")
        XCTAssertFalse(engine.isCapturing)
    }

    func testRecognitionEndingWithoutAFinalUsesTheLastPartial() {
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = nil
        let speech = SpeechService(engine: engine)

        speech.startListening()
        engine.emitPartial("half a thought")
        var results: [String?] = []
        speech.stopListening { results.append($0) }
        XCTAssertTrue(results.isEmpty, "still waiting on the recognizer")

        engine.endRecognition()
        engine.endRecognition()

        XCTAssertEqual(results, ["half a thought"], "completion fires exactly once")
        XCTAssertFalse(speech.isListening)
    }

    func testSilenceResolvesToNil() {
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "   "
        let speech = SpeechService(engine: engine)

        speech.startListening()
        var results: [String?] = []
        speech.stopListening { results.append($0) }

        XCTAssertEqual(results, [nil])
    }

    func testStopWhileNotListeningCompletesWithNil() {
        let engine = ScriptedSpeechEngine()
        let speech = SpeechService(engine: engine)

        var results: [String?] = []
        speech.stopListening { results.append($0) }

        XCTAssertEqual(results, [nil])
        XCTAssertTrue(engine.calls.isEmpty)
    }

    // MARK: Overlapping sessions

    func testANewPressResolvesADrainingStopWithItsLastPartial() {
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = nil
        let speech = SpeechService(engine: engine)

        speech.startListening()
        engine.emitPartial("first words")
        var results: [String?] = []
        speech.stopListening { results.append($0) }
        XCTAssertTrue(results.isEmpty)

        speech.startListening()

        XCTAssertEqual(results, ["first words"])
        XCTAssertTrue(speech.isListening)
        XCTAssertEqual(engine.captureHandlers.count, 2)
    }

    func testLateCallbacksFromAnEarlierCaptureAreDropped() {
        let engine = ScriptedSpeechEngine()
        engine.finalTranscript = "first"
        let speech = SpeechService(engine: engine)

        speech.startListening()
        speech.stopListening { _ in }
        speech.startListening()

        engine.emit(.transcript("stale words", isFinal: false), toCapture: 0)
        XCTAssertEqual(speech.partialTranscript, "")

        engine.emitPartial("fresh")
        XCTAssertEqual(speech.partialTranscript, "fresh")
    }
}
