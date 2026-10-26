import Foundation
import Speech
import AVFAudio
import AudioToolbox

// MARK: - Speech engine seam (#112)

/// The recognizer's answer to "may PowerUp transcribe speech?".
enum SpeechEngineAuthorization: Equatable {
    case notDetermined, authorized, denied
}

/// Why a capture could not start after the recognizer was readied.
enum SpeechEngineStartFailure: Error, Equatable {
    /// No usable input device: the input node reports a 0 Hz / 0-channel format.
    case noMicrophoneInput
    /// The audio engine refused to start.
    case audioEngineFailed
}

/// One recognizer callback for the current capture.
enum SpeechEngineUpdate: Equatable {
    /// The best transcription so far; `isFinal` once the recognizer is done.
    case transcript(String, isFinal: Bool)
    /// Recognition ended (error or cancellation) without a further result.
    case ended
}

/// The framework surface SpeechService drives: permission, availability,
/// starting a capture, ending its audio, tearing it down, and the partial /
/// final results in between. Internal to the Speech module — SpeechService's
/// public contract (DESIGN.md "Module: Speech") is unchanged; the system
/// recognizer is the default and tests inject a scripted engine so they can
/// "hear" a transcript without a microphone or a permission prompt.
///
/// SpeechService owns every rule (one capture at a time, completion exactly
/// once, the stop timeout, stale-callback filtering, trimming); the engine
/// only does what the framework does. Deliberately minimal — widen it when a
/// test needs more of the recognizer, not before.
@MainActor
protocol SpeechRecognitionEngine: AnyObject {
    /// The current authorization, without prompting.
    func authorizationStatus() -> SpeechEngineAuthorization
    /// Shows the permission prompt; true when granted.
    func requestAuthorization() async -> Bool
    /// Readies a recognizer for `localeID` and reports whether it is
    /// available; the next `startCapture` uses it.
    func prepareRecognizer(localeID: String) -> Bool
    /// Starts capturing audio from `inputDeviceID` (nil: leave the device
    /// alone / system default) into the prepared recognizer. Results arrive
    /// through `onUpdate` on the main actor, never synchronously from here.
    func startCapture(onDevice: Bool,
                      inputDeviceID: AudioDeviceID?,
                      onUpdate: @escaping @MainActor (SpeechEngineUpdate) -> Void) throws
    /// No more audio is coming; the recognizer should finalize.
    func endAudio()
    /// Tears the capture down fully (tap, audio engine, task, request). Safe
    /// to call when nothing is capturing.
    func stopCapture()
}

/// Push-to-talk speech-to-text service. Owns the capture lifecycle — the
/// recognizer itself sits behind `SpeechRecognitionEngine` — tearing the
/// capture down fully on every stop so each press starts from a clean slate.
@MainActor
final class SpeechService: ObservableObject {
    enum AuthState: Equatable { case unknown, authorized, denied }

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var isListening: Bool = false
    @Published private(set) var partialTranscript: String = ""

    private var localeID: String = "en-US"
    private var onDevice: Bool = false

    /// Resolves the user's chosen microphone to a live device id at press
    /// time; nil (or an unplugged pick) means the system default. Set by
    /// AppState so this service never has to know about config or the
    /// device store.
    var preferredInputDeviceID: (() -> AudioDeviceID?)?

    /// The recognizer and audio capture (the system one in production).
    private let engine: any SpeechRecognitionEngine

    private var lastPartialResult: String = ""
    /// True once the recognizer delivered `isFinal` for this listening session
    /// — no further results will come, so a later stop can resolve instantly.
    private var hasFinalResult: Bool = false

    /// Fired at most once per listening session, guarding stopListening's
    /// "completion exactly once" contract against overlapping callbacks.
    private var stopCompletion: ((String?) -> Void)?
    private var stopTimeoutTask: Task<Void, Never>?
    private var finished: Bool = false

    /// Monotonically increasing id of the listening session. Recognition
    /// callbacks stamp the generation they were created under and are dropped
    /// once it moves on — a cancelled task can keep delivering results for a
    /// beat after teardown, and those must never leak partials (or resolve a
    /// stop) belonging to a *newer* session.
    private var sessionGeneration: Int = 0

    /// - Parameter engine: nil (production) uses the system recognizer.
    init(engine: (any SpeechRecognitionEngine)? = nil) {
        self.engine = engine ?? SystemSpeechRecognitionEngine()
    }

    // MARK: - Configuration

    func configure(localeID: String, onDevice: Bool) {
        self.localeID = localeID
        self.onDevice = onDevice
    }

    // MARK: - Permissions

    func requestPermissionsIfNeeded() async -> Bool {
        switch engine.authorizationStatus() {
        case .authorized:
            authState = .authorized
            return true
        case .denied:
            authState = .denied
            return false
        case .notDetermined:
            let granted = await engine.requestAuthorization()
            authState = granted ? .authorized : .denied
            return granted
        }
    }

    // MARK: - Start

    func startListening() {
        // A new press must always begin from a torn-down engine. The previous
        // stop can still be draining here — stopListening waits up to 1.5s for
        // a final result before finishStop runs — so resolve it right now with
        // whatever it had (its completion fires with the last partial) instead
        // of silently refusing to start and leaving a dead hold.
        if isListening || stopCompletion != nil {
            finishStop(with: lastPartialResult)
        }

        guard engine.prepareRecognizer(localeID: localeID) else {
            partialTranscript = "Speech recognition unavailable for this locale."
            return
        }
        if engine.authorizationStatus() != .authorized {
            partialTranscript = "Speech recognition permission not granted."
            authState = .denied
            return
        }

        // Stamp this capture before it starts: anything a torn-down capture
        // still delivers carries an older generation and is dropped.
        sessionGeneration += 1
        let generation = sessionGeneration

        do {
            try engine.startCapture(onDevice: onDevice,
                                    inputDeviceID: preferredInputDeviceID?()) { [weak self] update in
                guard let self, generation == self.sessionGeneration else { return }
                self.handle(update)
            }
        } catch SpeechEngineStartFailure.noMicrophoneInput {
            partialTranscript = "No microphone input is available — check System Settings → Sound → Input."
            return
        } catch {
            partialTranscript = "Could not start audio engine."
            return
        }

        lastPartialResult = ""
        hasFinalResult = false
        finished = false
        partialTranscript = ""
        isListening = true
    }

    private func handle(_ update: SpeechEngineUpdate) {
        switch update {
        case .transcript(let text, let isFinal):
            lastPartialResult = text
            partialTranscript = lastPartialResult
            if isFinal {
                hasFinalResult = true
                // Only auto-resolve when a stop is actually pending.
                // The recognizer finalizes on its own (a sustained
                // pause, its ~1-minute cap) while the trigger may
                // still be held — keep the text and let stopListening
                // resolve with it on release.
                if stopCompletion != nil {
                    finishStop(with: lastPartialResult)
                }
            }
        case .ended:
            // Recognition ended (error or cancellation). If we're still
            // waiting on a stop completion, resolve with whatever we have.
            if stopCompletion != nil {
                finishStop(with: lastPartialResult)
            }
        }
    }

    // MARK: - Stop

    func stopListening(completion: @escaping (String?) -> Void) {
        guard isListening else {
            completion(nil)
            return
        }

        stopCompletion = completion
        finished = false

        // The recognizer may have already finalized mid-hold; nothing more is
        // coming, so resolve immediately with what it gave us.
        if hasFinalResult {
            finishStop(with: lastPartialResult)
            return
        }

        engine.endAudio()
        // An engine that answers synchronously has already resolved the stop.
        guard stopCompletion != nil else { return }

        stopTimeoutTask?.cancel()
        stopTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // finishStop cancels this timeout, and a cancelled sleep returns
            // at once — by then a new press may have reset `finished`, so
            // without this check the timeout would end that new capture.
            guard !Task.isCancelled, let self, !self.finished else { return }
            self.finishStop(with: self.lastPartialResult)
        }
    }

    /// Resolves the pending stop completion exactly once and tears the capture down.
    private func finishStop(with text: String) {
        guard !finished else { return }
        finished = true

        // Anything the outgoing task still delivers after this point is stale.
        sessionGeneration += 1

        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil

        engine.stopCapture()

        isListening = false
        partialTranscript = ""

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: String? = trimmed.isEmpty ? nil : trimmed

        let completion = stopCompletion
        stopCompletion = nil
        completion?(result)
    }
}

// MARK: - System recognizer

/// The production engine: SFSpeechRecognizer fed from an AVAudioEngine input
/// tap (DESIGN.md "Module: Speech" implementation requirements, v2.5 C for
/// the chosen microphone). Fresh request and task per capture.
@MainActor
private final class SystemSpeechRecognitionEngine: SpeechRecognitionEngine {

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var didHaveTapInstalled: Bool = false

    /// The device id the engine's input unit was last pointed at, so the
    /// override is only rewritten when the choice actually changed.
    private var appliedInputDeviceID: AudioDeviceID?

    func authorizationStatus() -> SpeechEngineAuthorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func prepareRecognizer(localeID: String) -> Bool {
        let locale = Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return false
        }
        self.recognizer = recognizer
        return true
    }

    func startCapture(onDevice: Bool,
                      inputDeviceID: AudioDeviceID?,
                      onUpdate: @escaping @MainActor (SpeechEngineUpdate) -> Void) throws {
        // Only reachable after a successful prepareRecognizer.
        guard let recognizer else { throw SpeechEngineStartFailure.audioEngineFailed }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            newRequest.addsPunctuation = true
        }
        if onDevice && recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        self.request = newRequest

        let inputNode = audioEngine.inputNode
        applyInputDevice(inputDeviceID, to: inputNode)
        let format = inputNode.outputFormat(forBus: 0)

        // No usable input device leaves the node reporting a 0 Hz / 0-channel
        // format, and installTap would raise an uncatchable NSException.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            throw SpeechEngineStartFailure.noMicrophoneInput
        }

        inputNode.removeTap(onBus: 0)
        // The tap fires on the realtime audio thread — capture the request
        // directly rather than reading main-actor state from that thread.
        // Removing the tap (stopCapture) is what stops the feed.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            newRequest.append(buffer)
        }
        didHaveTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            didHaveTapInstalled = false
            self.request = nil
            throw SpeechEngineStartFailure.audioEngineFailed
        }

        task = recognizer.recognitionTask(with: newRequest) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let ended = error != nil
            Task { @MainActor in
                if let text {
                    onUpdate(.transcript(text, isFinal: isFinal))
                }
                if ended {
                    onUpdate(.ended)
                }
            }
        }
    }

    func endAudio() {
        request?.endAudio()
    }

    func stopCapture() {
        if didHaveTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            didHaveTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        task?.cancel()
        task = nil
        request = nil
    }

    /// Points the engine's input unit at the user's chosen microphone before
    /// the tap goes in — the tap format follows the device. When nothing is
    /// chosen and nothing was ever pinned, the unit is left alone so it keeps
    /// tracking live system-default changes (pinning the default explicitly
    /// would freeze it); after a pin, "no choice" re-applies the CURRENT
    /// default each press, which both undoes the pin and self-heals a unit
    /// reset out from under us. Best-effort: a failed set leaves the current
    /// device, and the 0 Hz format guard still protects.
    private func applyInputDevice(_ preferred: AudioDeviceID?, to inputNode: AVAudioInputNode) {
        if preferred == nil && appliedInputDeviceID == nil { return }
        let target = preferred ?? AudioDeviceStore.systemDefaultInputDeviceID()
        guard var deviceID = target, let audioUnit = inputNode.audioUnit else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            appliedInputDeviceID = deviceID
        }
    }
}
