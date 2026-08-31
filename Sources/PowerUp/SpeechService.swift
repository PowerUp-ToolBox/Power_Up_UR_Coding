import Foundation
import Speech
import AVFAudio
import AudioToolbox

/// Push-to-talk speech-to-text service. Owns the audio engine tap and the
/// SFSpeechRecognizer request/task lifecycle, tearing both down fully on
/// every stop so each press starts from a clean slate.
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

    /// The device id the engine's input unit was last pointed at, so the
    /// override is only rewritten when the choice actually changed.
    private var appliedInputDeviceID: AudioDeviceID?

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var lastPartialResult: String = ""
    /// True once the recognizer delivered `isFinal` for this listening session
    /// — no further results will come, so a later stop can resolve instantly.
    private var hasFinalResult: Bool = false
    private var didHaveTapInstalled: Bool = false

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

    // MARK: - Configuration

    func configure(localeID: String, onDevice: Bool) {
        self.localeID = localeID
        self.onDevice = onDevice
    }

    // MARK: - Permissions

    func requestPermissionsIfNeeded() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized:
            authState = .authorized
            return true
        case .denied, .restricted:
            authState = .denied
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            authState = granted ? .authorized : .denied
            return granted
        @unknown default:
            authState = .denied
            return false
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

        let locale = Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            partialTranscript = "Speech recognition unavailable for this locale."
            return
        }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            partialTranscript = "Speech recognition permission not granted."
            authState = .denied
            return
        }

        self.recognizer = recognizer

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
        applyPreferredInputDevice(to: inputNode)
        let format = inputNode.outputFormat(forBus: 0)

        // No usable input device leaves the node reporting a 0 Hz / 0-channel
        // format, and installTap would raise an uncatchable NSException.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            partialTranscript = "No microphone input is available — check System Settings → Sound → Input."
            return
        }

        inputNode.removeTap(onBus: 0)
        // The tap fires on the realtime audio thread — capture the request
        // directly rather than reading main-actor state from that thread.
        // Removing the tap (finishStop) is what stops the feed.
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
            partialTranscript = "Could not start audio engine."
            return
        }

        lastPartialResult = ""
        hasFinalResult = false
        finished = false
        partialTranscript = ""
        isListening = true

        sessionGeneration += 1
        let generation = sessionGeneration

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, generation == self.sessionGeneration else { return }
                if let result {
                    self.lastPartialResult = result.bestTranscription.formattedString
                    self.partialTranscript = self.lastPartialResult
                    if result.isFinal {
                        self.hasFinalResult = true
                        // Only auto-resolve when a stop is actually pending.
                        // The recognizer finalizes on its own (a sustained
                        // pause, its ~1-minute cap) while the trigger may
                        // still be held — keep the text and let stopListening
                        // resolve with it on release.
                        if self.stopCompletion != nil {
                            self.finishStop(with: self.lastPartialResult)
                        }
                    }
                }
                if error != nil {
                    // Recognition ended (error or cancellation). If we're still
                    // waiting on a stop completion, resolve with whatever we have.
                    if self.stopCompletion != nil {
                        self.finishStop(with: self.lastPartialResult)
                    }
                }
            }
        }
    }

    /// Points the engine's input unit at the user's chosen microphone before
    /// the tap goes in — the tap format follows the device. When nothing is
    /// chosen and nothing was ever pinned, the unit is left alone so it keeps
    /// tracking live system-default changes (pinning the default explicitly
    /// would freeze it); after a pin, "no choice" re-applies the CURRENT
    /// default each press, which both undoes the pin and self-heals a unit
    /// reset out from under us. Best-effort: a failed set leaves the current
    /// device, and the 0 Hz format guard below still protects.
    private func applyPreferredInputDevice(to inputNode: AVAudioInputNode) {
        let preferred = preferredInputDeviceID?()
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

        request?.endAudio()

        stopTimeoutTask?.cancel()
        stopTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.finished else { return }
            self.finishStop(with: self.lastPartialResult)
        }
    }

    /// Resolves the pending stop completion exactly once and tears down engine/tap/task/request.
    private func finishStop(with text: String) {
        guard !finished else { return }
        finished = true

        // Anything the outgoing task still delivers after this point is stale.
        sessionGeneration += 1

        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil

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

        isListening = false
        partialTranscript = ""

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: String? = trimmed.isEmpty ? nil : trimmed

        let completion = stopCompletion
        stopCompletion = nil
        completion?(result)
    }
}
