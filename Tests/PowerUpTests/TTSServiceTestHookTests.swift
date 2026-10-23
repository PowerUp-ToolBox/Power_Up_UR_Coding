import XCTest
@testable import PowerUp

/// The TTS output recorder (#124): with `recordsOutput` on, `speak` and `stop`
/// are recorded instead of reaching the synthesizer, so an AppState scenario
/// can have a reply "spoken" without a sound and check what was stopped when.
@MainActor
final class TTSServiceTestHookTests: XCTestCase {

    func testRecordedSpeakMarksSpeakingWithoutTheSynthesizer() {
        let tts = TTSService()
        tts.recordsOutput = true

        tts.speak("All tests pass.", voiceID: nil, rate: 0.5)

        XCTAssertTrue(tts.isSpeaking, "a recorded utterance counts as speaking")
        XCTAssertEqual(tts.recordedOutput, [.speak("All tests pass.")],
                       "speak's own internal stop is not a separate call")
    }

    func testRecordedStopEndsSpeakingAndIsRecorded() {
        let tts = TTSService()
        tts.recordsOutput = true
        tts.speak("Hello there.", voiceID: nil, rate: 0.5)

        tts.stop()

        XCTAssertFalse(tts.isSpeaking)
        XCTAssertEqual(tts.recordedOutput, [.speak("Hello there."), .stop])
    }

    func testStopDoesNotFireOnFinished() {
        // Same as production: only the synthesizer finishing (or cancelling
        // the CURRENT utterance) fires onFinished; stop() clears it first.
        let tts = TTSService()
        tts.recordsOutput = true
        var finished = 0
        tts.onFinished = { finished += 1 }
        tts.speak("Hello there.", voiceID: nil, rate: 0.5)

        tts.stop()

        XCTAssertEqual(finished, 0)
    }

    func testFinishRecordedSpeechEndsItLikeTheSynthesizerFinishing() {
        let tts = TTSService()
        tts.recordsOutput = true
        var finished = 0
        tts.onFinished = { finished += 1 }
        tts.speak("Hello there.", voiceID: nil, rate: 0.5)

        tts.finishRecordedSpeech()

        XCTAssertFalse(tts.isSpeaking)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(tts.recordedOutput, [.speak("Hello there.")], "finishing is not a stop")

        tts.finishRecordedSpeech()
        XCTAssertEqual(finished, 1, "nothing left to finish")
    }

    func testEmptyTextIsRecordedButNeverSpeaks() {
        let tts = TTSService()
        tts.recordsOutput = true

        tts.speak("", voiceID: nil, rate: 0.5)

        XCTAssertFalse(tts.isSpeaking)
        XCTAssertEqual(tts.recordedOutput, [.speak("")])
    }

    func testOffByDefaultAndClearable() {
        let tts = TTSService()
        XCTAssertFalse(tts.recordsOutput)
        tts.stop()
        XCTAssertTrue(tts.recordedOutput.isEmpty, "production records nothing")

        tts.recordsOutput = true
        tts.stop()
        XCTAssertEqual(tts.recordedOutput, [.stop])
        tts.clearRecordedOutput()
        XCTAssertTrue(tts.recordedOutput.isEmpty)
    }
}
