import Foundation
import CoreAudio
@testable import PowerUp

/// Test-only `SpeechRecognitionEngine` (#112): stands in for the system
/// recognizer so a test can "hear" a transcript without a microphone or a
/// permission prompt.
///
/// Script it before the capture starts — the authorization status, the answer
/// a permission request gets, whether a recognizer is available, whether the
/// capture start fails, and the final transcript the recognizer returns once
/// the audio ends. During a capture, `emitPartial(_:)`, `emitFinal(_:)` and
/// `endRecognition()` deliver recognizer callbacks synchronously, on demand.
/// Every call the service makes is recorded in `calls`.
///
/// Unlike the system recognizer, which always calls back later, the fake
/// delivers `finalTranscript` synchronously from inside `endAudio()`, so a
/// release resolves within the same call — no waits in tests.
@MainActor
final class ScriptedSpeechEngine: SpeechRecognitionEngine {

    enum Call: Equatable {
        case requestAuthorization
        case prepareRecognizer(localeID: String)
        case startCapture(localeID: String, onDevice: Bool, inputDeviceID: AudioDeviceID?)
        case endAudio
        case stopCapture
    }

    // MARK: Script

    /// What `authorizationStatus()` reports. A granted/denied request updates
    /// it, the way the system remembers the person's answer.
    var authorization: SpeechEngineAuthorization = .authorized
    /// The person's answer when a permission request is shown.
    var permissionAnswer: Bool = true
    /// When true, a permission request stays on screen (the request suspends)
    /// until the test calls `answerPermissionPrompt(_:)`, so a test can act
    /// while the prompt is up: release the trigger, or answer with the hold
    /// already live. `permissionAnswer` is ignored while this is set.
    /// A test that shows a held prompt must answer it before it ends.
    var holdsPermissionPrompt: Bool = false
    /// Whether a recognizer exists and is available for the locale.
    var isRecognizerAvailable: Bool = true
    /// When set, `startCapture` fails with this instead of starting.
    var startFailure: SpeechEngineStartFailure?
    /// Delivered as the recognizer's final result when the audio ends (the
    /// release). Nil: nothing more is delivered, as if the recognizer went
    /// quiet — the service then falls back to its last partial after its own
    /// timeout, so a test leaving this nil should call `endRecognition()`.
    var finalTranscript: String?

    // MARK: Recording

    private(set) var calls: [Call] = []
    /// Called with each call as it is recorded, so a test can line the
    /// engine's calls up against another fake's record (#124: the TTS stop
    /// must already be recorded when the capture begins).
    var onCall: ((Call) -> Void)?
    /// One update handler per capture started, oldest first, so a test can
    /// deliver a late callback to an earlier (torn-down) capture.
    private(set) var captureHandlers: [@MainActor (SpeechEngineUpdate) -> Void] = []
    /// True between a successful `startCapture` and the next `stopCapture`.
    private(set) var isCapturing: Bool = false
    /// The locale the last `prepareRecognizer` readied; the next capture uses it.
    private var preparedLocaleID: String = ""
    /// The suspended request behind a held permission prompt.
    private var pendingPermission: CheckedContinuation<Bool, Never>?

    /// True while a held permission prompt is waiting for an answer.
    var isPermissionPromptShowing: Bool { pendingPermission != nil }

    /// Answers the held permission prompt, the way the person clicks
    /// "OK" or "Don't Allow". Remembered like a real answer. No-op when no
    /// prompt is showing.
    func answerPermissionPrompt(_ granted: Bool) {
        guard let pending = pendingPermission else { return }
        pendingPermission = nil
        authorization = granted ? .authorized : .denied
        pending.resume(returning: granted)
    }

    func clearCalls() { calls.removeAll() }

    private func record(_ call: Call) {
        calls.append(call)
        onCall?(call)
    }

    // MARK: Driving a capture

    /// A partial result for the current capture.
    func emitPartial(_ text: String) {
        emit(.transcript(text, isFinal: false))
    }

    /// A final result for the current capture (the recognizer finalizing on
    /// its own, e.g. after a long pause).
    func emitFinal(_ text: String) {
        emit(.transcript(text, isFinal: true))
    }

    /// The recognition task ended (error or cancellation) without a final result.
    func endRecognition() {
        emit(.ended)
    }

    /// Delivers `update` to the newest capture, or to the capture at `index`.
    func emit(_ update: SpeechEngineUpdate, toCapture index: Int? = nil) {
        let handler: (@MainActor (SpeechEngineUpdate) -> Void)?
        if let index {
            handler = captureHandlers.indices.contains(index) ? captureHandlers[index] : nil
        } else {
            handler = captureHandlers.last
        }
        handler?(update)
    }

    // MARK: SpeechRecognitionEngine

    func authorizationStatus() -> SpeechEngineAuthorization {
        authorization
    }

    func requestAuthorization() async -> Bool {
        record(.requestAuthorization)
        if holdsPermissionPrompt {
            return await withCheckedContinuation { continuation in
                MainActor.assumeIsolated { pendingPermission = continuation }
            }
        }
        authorization = permissionAnswer ? .authorized : .denied
        return permissionAnswer
    }

    func prepareRecognizer(localeID: String) -> Bool {
        record(.prepareRecognizer(localeID: localeID))
        preparedLocaleID = localeID
        return isRecognizerAvailable
    }

    func startCapture(onDevice: Bool,
                      inputDeviceID: AudioDeviceID?,
                      onUpdate: @escaping @MainActor (SpeechEngineUpdate) -> Void) throws {
        record(.startCapture(localeID: preparedLocaleID, onDevice: onDevice, inputDeviceID: inputDeviceID))
        if let startFailure { throw startFailure }
        captureHandlers.append(onUpdate)
        isCapturing = true
    }

    func endAudio() {
        record(.endAudio)
        if let finalTranscript {
            emitFinal(finalTranscript)
        }
    }

    func stopCapture() {
        record(.stopCapture)
        isCapturing = false
    }
}
