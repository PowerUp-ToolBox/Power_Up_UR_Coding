import Foundation
import Combine
import AppKit

/// Central glue between the controller, speech, TTS and the Claude CLI session.
///
/// Everything here runs on the main actor: the services publish their state from
/// the main actor and hand their callbacks back on it, so this class can wire them
/// together without any locking.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Services

    let configStore: ConfigStore
    let controller: ControllerService
    let speech: SpeechService
    let tts: TTSService
    let claude: ClaudeService

    /// The session driver, seen strictly through the harness contract. All
    /// session logic in this class goes through `harness` + `HarnessEvent`;
    /// which adapter that is follows Settings → General → Harness. `claude`
    /// stays exposed for the views until the UI fully generalizes.
    var harness: any HarnessAdapter {
        AppState.normalizedHarnessKind(configStore.config.harnessKind) == "acp"
            ? acpAdapterInstance()
            : claude
    }

    /// Lazily created ACP adapter (opencode, the Claude bridge, or a custom
    /// agent command), wired into the same event handler as the Claude adapter.
    private var acpAdapter: ACPAdapter?

    /// What the active harness reports as its model, for the model chip.
    var harnessReportedModel: String? { harness.modelName }

    private func acpAdapterInstance() -> ACPAdapter {
        if let acpAdapter { return acpAdapter }
        let adapter = ACPAdapter()
        adapter.onHarnessEvent = { [weak self] event in
            self?.handleHarnessEvent(event)
        }
        adapter.objectWillChange
            .sink { [weak self] _ in self?.scheduleDerivedUpdate() }
            .store(in: &cancellables)
        acpAdapter = adapter
        return adapter
    }

    private static func normalizedHarnessKind(_ raw: String) -> String {
        raw == "acp" ? "acp" : "claude"
    }

    /// Delivers input to somebody else's Claude session (cmux surface, or any app
    /// via keystroke injection) when `config.controlMode` is "remote".
    let remote: RemoteControlService
    /// Writes 1-2 sentence spoken conclusions of long replies (Settings → Voice).
    private let summary = SummaryService()
    /// Local HTTP endpoint the Claude Code hooks post replies back to.
    let listener: RemoteListener

    // MARK: - Published state

    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var status: AppStatus = .noController
    @Published private(set) var lastAssistantReply: String?
    @Published private(set) var liveAssistantText: String = ""
    @Published private(set) var isPTTActive: Bool = false

    /// True while the active push-to-talk hold is a dictate-to-draft one, so
    /// the UI can say "release to drop the text in the prompt box" instead of
    /// "release to send" — a draft hold never sends anything.
    @Published private(set) var isDraftDictation: Bool = false

    /// True while at least one remote session has a turn in flight — remote
    /// mode's stand-in for `claude.state == .working` (no process of ours is
    /// running, so the light bar and status pill lean on this). Derived from
    /// `remoteActiveTurns`; never write it directly.
    @Published private(set) var remoteTurnActive: Bool = false

    /// Text of the main window's prompt box. It lives here rather than in the
    /// view so dictation (`.pushToTalkDraft`) and the keyboard write to the same
    /// place, and so a controller button can send it (`.sendDraft`).
    @Published var draftText: String = ""

    // MARK: - Private state

    /// Keeps the transcript from growing without bound during very long sessions.
    private static let maxTranscriptEntries = 800

    /// Per-project transcript history on disk, so the conversation a resumed
    /// session (`--resume`) continues is actually visible after a relaunch.
    private let transcriptStore = TranscriptStore()

    private var cancellables: Set<AnyCancellable> = []
    private var statusUpdateScheduled = false

    /// Colour last pushed to the light bar, so we only talk to the controller on change.
    private var lastLightKey: String?
    /// Speech settings last pushed to `SpeechService`, same idea.
    private var lastSpeechConfigKey: String?
    /// Port/token the listener was last started with, so it only rebinds on change.
    private var lastListenerKey: String?
    /// Control mode we last reacted to, so switching modes (from the controller
    /// button *or* from Settings) runs its side effects exactly once.
    private var lastControlMode: String = "builtin"

    /// The button currently held down for push-to-talk (nil when not holding).
    private var pttHoldButton: ControllerButton?
    /// Mode of the hold `pttHoldButton` started; only meaningful while holding.
    private var pttMode: VoiceCaptureMode = .send
    /// True when the active draft hold belongs to remote mode: the transcript
    /// is typed into the remote target (without Enter) instead of the local
    /// prompt box. Captured at hold START so a mode toggle mid-hold can't mix
    /// the two paths.
    private var pttDraftTargetsRemote = false

    /// For the UI: the active draft hold will land in the remote session, not
    /// the prompt box. Derived from published state, so views re-evaluate.
    var draftDictationTargetsRemote: Bool { isPTTActive && isDraftDictation && pttDraftTargetsRemote }

    /// Live-dictation bookkeeping for a `.draft` hold.
    /// `draftOriginal` is the box exactly as it was before the hold (restored if
    /// nothing usable was heard); `draftBase` is that text plus the separator the
    /// dictated words get appended to; `draftLastShown` is the most recent partial
    /// we displayed, used when the recognizer ends without a final result.
    private var draftCancellable: AnyCancellable?
    private var draftOriginal: String = ""
    private var draftBase: String = ""
    private var draftLastShown: String = ""

    /// True while the currently running session was started with `--resume`.
    private var startedWithResume = false
    /// The resume-retry rule fires at most once per resumed session id.
    private var hasRetriedWithoutResume = false
    /// Terminations we caused ourselves (restart / quit) must not trigger recovery.
    private var expectedTerminations = 0

    /// Effort can only change by restarting the CLI, which would abandon a turn
    /// in flight — so a mid-turn change waits here until the turn completes.
    private var pendingEffortRestart = false

    /// The model / permission mode the CLI last confirmed, so a rejected live
    /// change can be rolled back instead of leaving the UI lying about state.
    /// Seeded at session start (those values went in on the command line).
    private var lastConfirmedModel: String = "default"
    private var lastConfirmedPermissionMode: String = "acceptEdits"

    /// "Session started" is logged once per launch: the CLI emits further
    /// `system/init` events mid-session (e.g. after a live `set_model`), and
    /// those must only refresh fields, not fake a new session start.
    private var didLogSessionStart = false

    /// Turn state per remote session (session id → when its turn last showed
    /// life). Hooks fire for EVERY Claude session on this machine, several of
    /// which can be mid-turn at once — one global Bool interleaved them into
    /// nonsense, and a session that closed mid-turn (its Stop hook never
    /// fires) pinned the light on amber forever. Entries leave on Stop, on
    /// SessionEnd, or by expiring.
    private var remoteActiveTurns: [String: Date] = [:]

    /// A remote turn with no hook activity for this long is presumed dead
    /// (missed Stop: killed terminal, crashed CLI, Escape pressed directly in
    /// the session). Long legitimate turns can exceed it — the tradeoff is a
    /// too-early idle that self-corrects on the next hook, versus an amber
    /// light no event will ever clear.
    private static let remoteTurnExpiry: TimeInterval = 15 * 60

    /// Bumped whenever the thing worth speaking changes (new turn, interrupt,
    /// PTT start) so a summary that arrives late speaks into the right moment
    /// or not at all.
    private var speechTurnGeneration = 0

    /// Harness selection last acted on (kind|agent|custom command), so a
    /// Settings change stops the old session exactly once.
    private var lastHarnessKey = ""

    /// The permission request currently awaiting ✕ (allow) / ○ (deny).
    /// Built-in mode only — remote mode's Approve/Reject already mean
    /// Enter/Escape in the target session.
    private var pendingPermissionID: String?

    private var willTerminateObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        let store = ConfigStore()
        configStore = store
        controller = ControllerService()
        speech = SpeechService()
        tts = TTSService()
        claude = ClaudeService()
        remote = RemoteControlService()
        listener = RemoteListener()

        // ConfigStore mints a token on first launch; adopt whatever mode the
        // config already holds without running the mode-switch side effects.
        lastControlMode = AppState.normalizedControlMode(store.config.controlMode)
        lastHarnessKey = AppState.harnessKey(for: store.config)

        transcriptStore.setProject(store.config.projectDir)
        restorePersistedTranscript()
        seedProjectBookkeeping()

        wireController()
        wireClaude()
        wireTTS()
        wireListener()
        observeServices()

        controller.start()
        syncSpeechConfiguration()
        syncListener()
        RemoteControlService.updateCmuxPassword(configStore.config.remoteCmuxPassword)
        if lastControlMode == "remote" {
            // Populate the cmux availability / workspace list for the UI. All of
            // these probes are read-only.
            remote.refreshStatus()
        }
        updateStatus()

        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willTerminate is posted synchronously from -[NSApplication
            // terminate:]; the run loop never turns again, so an enqueued Task
            // would never execute. The block already runs on the main thread —
            // call straight through.
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
    }

    // MARK: - Wiring

    private func wireController() {
        controller.onButtonDown = { [weak self] button in
            self?.handleButtonDown(button)
        }
        controller.onButtonUp = { [weak self] button in
            self?.handleButtonUp(button)
        }
        // A pad that drops mid-hold would otherwise strand the recorder (mic +
        // status wedged): the button's release event never comes. Release any
        // active hold the moment the controller disconnects.
        controller.onDisconnect = { [weak self] in
            self?.forceReleaseHold()
        }
    }

    private func wireClaude() {
        claude.onHarnessEvent = { [weak self] event in
            self?.handleHarnessEvent(event)
        }
    }

    private func wireTTS() {
        tts.onFinished = { [weak self] in
            self?.updateStatus()
        }
    }

    private func wireListener() {
        listener.onEvent = { [weak self] event in
            self?.handleRemoteEvent(event)
        }
        listener.onIntent = { [weak self] intent in
            self?.handleProtocolIntent(intent)
        }
        listener.welcomeSnapshot = { [weak self] in
            self?.protocolSnapshot() ?? []
        }
    }

    /// Intents from protocol clients (docs/protocol.md). Voice capture can't
    /// arrive over the wire (the protocol vocabulary omits it), but the gate
    /// stays anyway — defense in depth for a networked input source.
    private func handleProtocolIntent(_ intent: Intent) {
        switch intent {
        case .beginVoiceCapture, .endVoiceCapture:
            return
        default:
            handle(intent)
        }
    }

    /// What a freshly authenticated protocol client is told first.
    private func protocolSnapshot() -> [[String: Any]] {
        [PowerUpProtocol.status(status), currentSessionMessage()]
    }

    private func currentSessionMessage() -> [String: Any] {
        PowerUpProtocol.session(model: configStore.config.model,
                                liveModel: harness.modelName,
                                effort: configStore.config.effort,
                                permissionMode: configStore.config.permissionMode,
                                controlMode: AppState.normalizedControlMode(configStore.config.controlMode),
                                sessionID: harness.sessionID,
                                costUSD: harness.totalCostUSD)
    }

    /// Session facts protocol clients last heard, so `scheduleDerivedUpdate`
    /// only broadcasts real changes.
    private var lastSessionBroadcastKey: String?

    private func broadcastSessionIfChanged() {
        let key = [configStore.config.model,
                   harness.modelName ?? "",
                   configStore.config.effort,
                   configStore.config.permissionMode,
                   AppState.normalizedControlMode(configStore.config.controlMode),
                   harness.sessionID ?? "",
                   String(harness.totalCostUSD)].joined(separator: "|")
        guard key != lastSessionBroadcastKey else { return }
        lastSessionBroadcastKey = key
        listener.broadcast(currentSessionMessage())
    }

    /// The services are separate observable objects; mirror their changes into the
    /// derived status (and into anything else that depends on the config).
    private func observeServices() {
        let publishers: [ObservableObjectPublisher] = [
            controller.objectWillChange,
            tts.objectWillChange,
            claude.objectWillChange,
            speech.objectWillChange,
            configStore.objectWillChange,
            remote.objectWillChange,
            listener.objectWillChange
        ]
        for publisher in publishers {
            publisher.sink { [weak self] _ in
                self?.scheduleDerivedUpdate()
            }
            .store(in: &cancellables)
        }
    }

    // MARK: - Button dispatch (device layer → intents)

    private func handleButtonDown(_ button: ControllerButton) {
        let action = configStore.config.mapping[button] ?? .none
        if action.isHoldAction {
            // One hold at a time: a second hold press of either kind while one is
            // already running is ignored, so the button that started the recorder
            // stays the button that can stop it.
            guard pttHoldButton == nil, !isPTTActive else { return }
            pttHoldButton = button
        }
        guard let intent = IntentMapper.intent(for: action, phase: .began) else { return }
        handle(intent)
    }

    private func handleButtonUp(_ button: ControllerButton) {
        // Only hold actions care about the release. Use the button we recorded on
        // the way down so a mapping edit mid-hold can't strand the recorder — and
        // so the release of any other button is ignored outright. The end intent
        // is emitted unconditionally for the recorded button for the same reason:
        // whatever the mapping says *now*, this button started a capture.
        guard pttHoldButton == button else { return }
        pttHoldButton = nil
        handle(.endVoiceCapture)
    }

    /// Safety net for a hold that can no longer be released the normal way —
    /// e.g. the controller disconnected between the button's down and up events.
    /// Ends any active push-to-talk so the mic and status can never stay wedged.
    func forceReleaseHold() {
        guard isPTTActive || pttHoldButton != nil else { return }
        pttHoldButton = nil
        stopPushToTalk()
    }

    // MARK: - Intent dispatch

    /// The single dispatcher every input source funnels into: controller
    /// buttons (via the mapping), and protocol clients (via the listener).
    func handle(_ intent: Intent) {
        switch intent {
        case .beginVoiceCapture(let mode):
            startPushToTalk(mode: mode)
        case .endVoiceCapture:
            stopPushToTalk()
        case .sendDraft:
            sendDraft()
        case .sendPrompt(let prompt):
            sendUserText(prompt)
        case .approve:
            approve()
        case .reject:
            reject()
        case .interrupt:
            interruptClaude()
        case .stopSpeaking:
            cancelPendingSummary()
            tts.stop()
            updateStatus()
        case .replayLastReply:
            speakLastReply()
        case .toggleTTS:
            let enabled = !configStore.config.ttsEnabled
            configStore.config.ttsEnabled = enabled
            if !enabled { tts.stop() }
            appendEntry(.system, enabled ? "Spoken replies on." : "Spoken replies off.")
            haptic(intensity: 0.5, duration: 0.05)
            updateStatus()
        case .newSession:
            newSession()
        case .showWindow:
            showWindow()
        case .cycleModel:
            cycleModel()
        case .cycleEffort:
            cycleEffort()
        case .cyclePermissionMode:
            cyclePermissionMode()
        case .cycleProject:
            cycleProject()
        case .toggleControlMode:
            toggleControlMode()
        }
    }

    /// "Yes" to Claude. A pending harness permission request takes priority:
    /// ✕ answers it. In remote mode the target session is showing its own
    /// prompt, where Enter is the accept key — typing "Yes" there would answer
    /// a permission dialog with a word instead of a choice.
    private func approve() {
        if !isRemoteMode, let id = pendingPermissionID {
            pendingPermissionID = nil
            harness.respondToPermission(id: id, allow: true)
            appendEntry(.system, "Approved.")
            haptic(intensity: 0.5, duration: 0.05)
            updateStatus()
            return
        }
        guard isRemoteMode else {
            sendUserText("Yes")
            return
        }
        appendEntry(.system, "Approved (Enter).")
        sendRemoteKey(.enter)
    }

    /// "No" to Claude — answers a pending permission request first; Escape in
    /// remote mode, which both dismisses a prompt and stops a turn in flight.
    private func reject() {
        if !isRemoteMode, let id = pendingPermissionID {
            pendingPermissionID = nil
            harness.respondToPermission(id: id, allow: false)
            appendEntry(.system, "Denied.")
            haptic(intensity: 0.5, duration: 0.05)
            updateStatus()
            return
        }
        guard isRemoteMode else {
            sendUserText("No")
            return
        }
        // Escape also stops a turn in flight, and an Escape-interrupted turn
        // never emits a Stop hook — without this the status pill and light bar
        // would claim "Claude is working…" forever (interruptClaude does the same).
        clearRemoteTurns()
        appendEntry(.system, "Rejected (Esc).")
        sendRemoteKey(.escape)
        updateStatus()
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Session-setting cycles

    /// Steps `config.model` through the user's model cycle. The CLI accepts a
    /// live `set_model`, so a running session switches without losing context.
    private func cycleModel() {
        var cycle = configStore.config.modelCycle
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cycle.isEmpty { cycle = AppConfig.defaultModelCycle }

        let next = AppState.nextValue(after: configStore.config.model, in: cycle)
        configStore.config.model = next
        haptic(intensity: 0.5, duration: 0.05)
        appendEntry(.system, "Model → \(next)")

        if isRemoteMode {
            // The remote session takes its orders as slash commands.
            sendRemoteText("/model \(next)", submit: true)
            announce("Model: \(AppState.spokenName(for: next))")
            updateStatus()
            return
        }

        switch harness.state {
        case .ready, .working, .starting:
            // `.starting` is fine too: the CLI buffers stdin while it boots and
            // answers the request right after init, so writing the change now
            // guarantees it lands *ahead* of any turn sent before the first
            // `system/init` (queueing it until `.ready` did not — the turn got
            // there first and ran on the old command-line model).
            harness.setModel(next)
        case .stopped:
            // The next launch picks config.model up from the command line.
            break
        }

        announce("Model: \(AppState.spokenName(for: next))")
        updateStatus()
    }

    /// Steps `config.effort` through the fixed low → medium → high → xhigh cycle.
    /// There is no live effort switch, so this restarts the CLI with `--resume`
    /// (the conversation is preserved) — deferred if a turn is in flight.
    private func cycleEffort() {
        if !isRemoteMode, !harness.supportsEffort {
            appendEntry(.system, "This harness doesn't have an effort setting.")
            errorHaptic()
            return
        }
        let next = AppState.nextValue(after: configStore.config.effort, in: AppConfig.effortCycle)
        configStore.config.effort = next
        haptic(intensity: 0.5, duration: 0.05)

        if isRemoteMode {
            // No process of ours to restart — hand the change to the session as a
            // slash command. A CLI without /effort just prints an error there.
            pendingEffortRestart = false
            appendEntry(.system, "Effort → \(AppConfig.effortDisplayName(next))")
            sendRemoteText("/effort \(next)", submit: true)
            announce("Effort: \(AppConfig.effortDisplayName(next))")
            updateStatus()
            return
        }

        let display = AppConfig.effortDisplayName(next)
        if harness.state == .working {
            pendingEffortRestart = true
            appendEntry(.system, "Effort → \(display) (applies when this turn finishes)")
        } else if harness.state == .stopped {
            pendingEffortRestart = false
            appendEntry(.system, "Effort → \(display) (applies when the session starts)")
        } else {
            pendingEffortRestart = false
            appendEntry(.system, "Effort → \(display)")
            restartForEffort()
        }

        announce("Effort: \(display)")
        updateStatus()
    }

    /// Steps `config.permissionMode` through the fixed cycle. `bypassPermissions`
    /// is not in it on purpose — a stray press must never auto-approve everything.
    private func cyclePermissionMode() {
        if isRemoteMode {
            // Interactive Claude Code cycles permission modes with Shift+Tab.
            // Which mode that lands on depends on where the session already was,
            // and nothing reports it back — so config.permissionMode is left
            // alone rather than made to claim a mode we can't verify.
            haptic(intensity: 0.5, duration: 0.05)
            appendEntry(.system, "Permission mode cycled (see session)")
            sendRemoteKey(.shiftTab)
            announce("Permission mode cycled")
            updateStatus()
            return
        }

        let next = AppState.nextValue(after: configStore.config.permissionMode,
                                      in: AppConfig.permissionModeCycle)
        configStore.config.permissionMode = next
        haptic(intensity: 0.5, duration: 0.05)
        appendEntry(.system, "Permissions → \(next)")

        switch harness.state {
        case .ready, .working, .starting:
            // Same as cycleModel: the CLI buffers stdin during `.starting`, so
            // writing now puts the change ahead of any turn sent before init.
            harness.setPermissionMode(next)
        case .stopped:
            // The next launch picks config.permissionMode up from the command line.
            break
        }

        announce("Permissions: \(next)")
        updateStatus()
    }

    /// Relaunches the CLI so the new `--effort` takes hold, resuming the session
    /// so nothing said so far is lost.
    private func restartForEffort() {
        guard harness.state != .stopped else { return }
        guard let dir = configStore.config.projectDir, !dir.isEmpty else { return }

        let resumeID = harness.sessionID ?? configStore.config.lastSessionID
        appendEntry(.system, "Resuming the session with effort \(configStore.config.effort)…")
        startSession(resumeSessionID: resumeID)
    }

    /// Short spoken confirmation of a setting change. Deliberately NOT run
    /// through `speechText` — these phrases are already plain and short. The
    /// language is pinned to English: these are app-generated English
    /// constants, and statistical detection on strings this short misfiles
    /// them ("Model: Sonnet" → German) onto foreign voices.
    private func announce(_ phrase: String) {
        guard configStore.config.ttsEnabled else { return }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tts.speak(trimmed,
                  voiceID: configStore.config.ttsVoiceID,
                  rate: configStore.config.ttsRate,
                  language: "en")
    }

    /// Next entry after `current`, wrapping around; falls back to the first entry
    /// when the current value isn't part of the cycle at all.
    private static func nextValue(after current: String, in cycle: [String]) -> String {
        guard let first = cycle.first else { return current }
        guard let index = cycle.firstIndex(of: current) else { return first }
        return cycle[(index + 1) % cycle.count]
    }

    /// "sonnet" → "Sonnet", so the announcement doesn't sound clipped.
    private static func spokenName(for alias: String) -> String {
        guard let initial = alias.first else { return alias }
        return initial.uppercased() + alias.dropFirst()
    }

    // MARK: - Push to talk

    private func startPushToTalk(mode: VoiceCaptureMode = .send) {
        guard !isPTTActive else { return }

        pttMode = mode
        isDraftDictation = (mode == .draft)
        // In remote mode the "review" place is the target's own input box —
        // the local prompt box (probably in a hidden window) stays untouched.
        pttDraftTargetsRemote = (mode == .draft) && isRemoteMode
        if mode == .draft, !pttDraftTargetsRemote { beginDraftCapture() }

        // Never talk over ourselves: the mic would just hear the synthesizer —
        // and a summary still cooking must not start speaking mid-recording.
        cancelPendingSummary()
        tts.stop()
        isPTTActive = true
        updateStatus()
        haptic(intensity: 0.5, duration: 0.05)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.speech.requestPermissionsIfNeeded()
            // The user may have released the trigger while the prompt was up.
            guard self.isPTTActive else { return }
            guard granted else {
                self.isPTTActive = false
                self.isDraftDictation = false
                self.pttHoldButton = nil
                // Only a local draft hold has a mirror to tear down — and only
                // it may touch the prompt box (a .send hold never wrote to it,
                // and a remote draft hold never began capturing).
                if self.pttMode == .draft, !self.pttDraftTargetsRemote {
                    self.endDraftCapture(restoringDraft: true)
                }
                self.appendEntry(.error, "Speech recognition isn't allowed yet. Enable PowerUp in System Settings → Privacy & Security → Speech Recognition (and Microphone).")
                self.errorHaptic()
                self.updateStatus()
                return
            }
            self.syncSpeechConfiguration()
            self.speech.startListening()
        }
    }

    private func stopPushToTalk() {
        guard isPTTActive else { return }
        isPTTActive = false
        isDraftDictation = false

        if pttMode == .draft {
            if pttDraftTargetsRemote {
                stopRemoteDraftDictation()
            } else {
                stopDraftDictation()
            }
            return
        }

        speech.stopListening { [weak self] text in
            guard let self else { return }
            let spoken = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if spoken.isEmpty {
                // Nothing usable — buzz twice so the user knows without looking.
                self.errorHaptic()
                self.updateStatus()
            } else {
                self.sendUserText(spoken)
            }
        }
        updateStatus()
    }

    // MARK: - Dictate to the prompt box

    /// Starts mirroring the recognizer's partial results into `draftText`, so the
    /// words appear in the prompt box as they're spoken. Anything already typed
    /// there is kept and dictation is appended after it.
    private func beginDraftCapture() {
        draftOriginal = draftText
        if draftText.isEmpty {
            draftBase = ""
        } else if draftText.hasSuffix(" ") || draftText.hasSuffix("\n") {
            draftBase = draftText
        } else {
            draftBase = draftText + " "
        }
        draftLastShown = ""

        draftCancellable?.cancel()
        // `dropFirst()` skips the value @Published replays on subscribe — only
        // partials produced by *this* hold should reach the prompt box.
        draftCancellable = speech.$partialTranscript
            .dropFirst()
            .sink { [weak self] partial in
                self?.applyDraftPartial(partial)
            }
    }

    private func applyDraftPartial(_ partial: String) {
        guard isPTTActive, pttMode == .draft else { return }
        // SpeechService also uses `partialTranscript` for one-line error hints
        // (set while not listening) and clears it on teardown; neither belongs in
        // the user's prompt box, and both happen with `isListening` already false.
        guard speech.isListening else { return }
        draftLastShown = partial
        // The recognizer frequently repeats an identical transcription between
        // callbacks; `draftText` is @Published, so a redundant store would
        // invalidate every observing view (and yank the TextField's insertion
        // point to the end while the user edits). Only publish real changes.
        let updated = draftBase + partial
        guard updated != draftText else { return }
        draftText = updated
    }

    /// Tears the partial-transcript mirror down, optionally putting the prompt box
    /// back exactly as the user left it before the hold.
    private func endDraftCapture(restoringDraft: Bool) {
        draftCancellable?.cancel()
        draftCancellable = nil
        if restoringDraft {
            draftText = draftOriginal
        }
    }

    /// Release of a dictate-to-draft hold: the final transcript lands in the
    /// prompt box for review. Nothing is ever sent from here.
    private func stopDraftDictation() {
        endDraftCapture(restoringDraft: false)

        let base = draftBase
        let original = draftOriginal
        let lastShown = draftLastShown

        speech.stopListening { [weak self] text in
            guard let self else { return }
            let heard = (text ?? lastShown).trimmingCharacters(in: .whitespacesAndNewlines)
            // Same no-op guard as applyDraftPartial: don't republish a value
            // the box already shows.
            if heard.isEmpty {
                // Nothing usable — leave the box exactly as it was and buzz twice.
                if self.draftText != original { self.draftText = original }
                self.errorHaptic()
            } else {
                let updated = base + heard
                if self.draftText != updated { self.draftText = updated }
            }
            self.updateStatus()
        }
        updateStatus()
    }

    /// Release of a dictate-to-draft hold while in remote mode: the final
    /// transcript is TYPED into the remote target — cmux input box, terminal
    /// prompt — without pressing Enter, so it can be reviewed right where the
    /// session lives and sent from there (Enter in the app, or ✕/Approve).
    /// Nothing is submitted from here, and the local prompt box is untouched.
    private func stopRemoteDraftDictation() {
        // Fallback if the recognizer ends without a final result (mirrors
        // stopDraftDictation's lastShown, which the remote path doesn't track).
        let lastShown = speech.partialTranscript

        speech.stopListening { [weak self] text in
            guard let self else { return }
            let heard = (text ?? lastShown).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty else {
                // Nothing usable — buzz twice, type nothing.
                self.errorHaptic()
                self.updateStatus()
                return
            }
            self.appendEntry(.system, "Dictated into the remote session — send it with L1, ✕, or Enter there: \(heard)")
            self.sendRemoteText(heard, submit: false)
            self.haptic(intensity: 0.5, duration: 0.05)
            self.updateStatus()
        }
        updateStatus()
    }

    /// Sends whatever is in the prompt box right now — the shared path for the
    /// Send button, the keyboard, and the `.sendDraft` controller action.
    ///
    /// In remote mode the "prompt box" is really the target's own input line —
    /// that's where L2 dictation lands (v1.8) — so an empty local box means
    /// "submit what's typed over there": press Enter in the target. That keeps
    /// the L2 → L1 dictate-review-send flow working in both modes.
    func sendDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard isRemoteMode else {
                errorHaptic()
                return
            }
            appendEntry(.system, "Sent the remote input (Enter).")
            haptic(intensity: 0.5, duration: 0.05)
            sendRemoteKey(.enter)
            updateStatus()
            return
        }
        sendUserText(trimmed)
        draftText = ""
    }

    // MARK: - Session control

    func startSessionIfNeeded() {
        // Remote mode drives a session somebody else is running; spawning ours
        // would duplicate the work and echo its own hooks back at us.
        guard !isRemoteMode else { return }
        guard harness.state == .stopped else { return }
        guard let dir = configStore.config.projectDir, !dir.isEmpty else { return }
        startSession(resumeSessionID: savedSessionID(for: dir) ?? configStore.config.lastSessionID)
    }

    func newSession() {
        cancelPendingSummary()
        tts.stop()
        liveAssistantText = ""

        if isRemoteMode {
            // We don't own the remote session, so "new session" means clearing
            // the conversation it's holding.
            clearRemoteTurns()
            appendEntry(.system, "Clearing the remote session.")
            sendRemoteText("/clear", submit: true)
            updateStatus()
            return
        }

        hasRetriedWithoutResume = false
        startedWithResume = false
        pendingEffortRestart = false
        configStore.config.lastSessionID = nil
        if let dir = configStore.config.projectDir, !dir.isEmpty {
            configStore.config.sessionIDsByProject.removeValue(forKey: dir)
        }
        appendEntry(.system, "Starting a new Claude session.")

        if let dir = configStore.config.projectDir, !dir.isEmpty {
            startSession(resumeSessionID: nil)
        } else {
            stopClaude()
            appendEntry(.system, "Choose a project folder to begin.")
        }
        updateStatus()
    }

    func sendUserText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendEntry(.user, trimmed)
        cancelPendingSummary()
        liveAssistantText = ""

        if isRemoteMode {
            sendRemoteText(trimmed, submit: configStore.config.remoteAutoSubmit)
            updateStatus()
            return
        }

        startSessionIfNeeded()

        guard harness.state != .stopped else {
            appendEntry(.error, "No Claude session is running. Choose a project folder to start one.")
            errorHaptic()
            updateStatus()
            return
        }

        harness.send(outgoingText(for: trimmed))
        updateStatus()
    }

    /// In Ultra effort ("max") on the built-in Claude harness, outgoing
    /// prompts opt into dynamic multi-agent workflows via Claude Code's
    /// documented `ultracode` keyword. The transcript keeps the user's own
    /// words; the wire-level prefix is recorded in DESIGN.md v2.1. Other
    /// harnesses and remote mode are never prefixed.
    private func outgoingText(for text: String) -> String {
        guard configStore.config.effort == "max",
              AppState.normalizedHarnessKind(configStore.config.harnessKind) == "claude" else {
            return text
        }
        return "ultracode\n\n" + text
    }

    func interruptClaude() {
        if isRemoteMode {
            // Escape is the interactive CLI's stop key.
            clearRemoteTurns()
            appendEntry(.system, "Interrupt sent (Esc).")
            haptic(intensity: 0.6, duration: 0.08)
            sendRemoteKey(.escape)
            updateStatus()
            return
        }

        // ClaudeService.interrupt() silently no-ops without a live process —
        // don't confirm an interrupt that was never written.
        guard harness.state != .stopped else {
            appendEntry(.error, "No Claude session is running — nothing to interrupt.")
            errorHaptic()
            updateStatus()
            return
        }
        harness.interrupt()
        appendEntry(.system, "Interrupt sent.")
        haptic(intensity: 0.6, duration: 0.08)
        updateStatus()
    }

    func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder Claude Code should work in."
        if let current = configStore.config.projectDir, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptProject(url.path, movingToFrontOfRecents: true)
    }

    /// Switches the app onto a project folder: per-project session id (each
    /// folder is its own conversation), per-project transcript history, and —
    /// in built-in mode — a session restart resuming THAT project's
    /// conversation. Shared by the folder picker, the Settings recents list,
    /// and the Cycle Project action.
    private func adoptProject(_ path: String, movingToFrontOfRecents: Bool) {
        let changedProject = (path != configStore.config.projectDir)
        configStore.config.projectDir = path
        if changedProject {
            // Each project keeps its own conversation: resume ITS session id
            // (nil = this folder starts fresh), never another folder's.
            configStore.config.lastSessionID = savedSessionID(for: path)
        }
        hasRetriedWithoutResume = false
        addToRecents(path, front: movingToFrontOfRecents)

        // Transcript history is per project: switch the store over and swap the
        // window's scrollback for the new project's restored history.
        transcriptStore.setProject(path)
        if changedProject {
            transcript = []
            restorePersistedTranscript()
        }

        appendEntry(.system, "Project folder: \((path as NSString).lastPathComponent)")

        // In remote mode PowerUp runs no session of its own — the folder is then
        // only used to label read-back from other directories.
        if !isRemoteMode {
            startSession(resumeSessionID: savedSessionID(for: path))
        }
        updateStatus()
    }

    /// Switch to a specific known project (Settings recents list).
    func switchProject(to path: String) {
        guard path != configStore.config.projectDir else { return }
        cancelPendingSummary()
        tts.stop()
        liveAssistantText = ""
        pendingPermissionID = nil
        adoptProject(path, movingToFrontOfRecents: false)
        announce("Project: \((path as NSString).lastPathComponent)")
    }

    /// The Cycle Project action: steps through the recents IN LIST ORDER
    /// (cycling deliberately doesn't reorder the list — reordering on every
    /// press would make the next press ping-pong back).
    private func cycleProject() {
        let recents = configStore.config.recentProjectDirs.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard recents.count > 1 else {
            appendEntry(.system, "Only one project in the recent list — add more with the folder picker.")
            errorHaptic()
            return
        }
        let current = configStore.config.projectDir ?? ""
        let index = recents.firstIndex(of: current) ?? -1
        let next = recents[(index + 1) % recents.count]
        haptic(intensity: 0.5, duration: 0.05)
        switchProject(to: next)
    }

    private func addToRecents(_ path: String, front: Bool) {
        var recents = configStore.config.recentProjectDirs
        if front {
            recents.removeAll { $0 == path }
            recents.insert(path, at: 0)
        } else if !recents.contains(path) {
            recents.insert(path, at: 0)
        }
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        if recents != configStore.config.recentProjectDirs {
            configStore.config.recentProjectDirs = recents
        }
    }

    private func savedSessionID(for path: String) -> String? {
        configStore.config.sessionIDsByProject[path]
    }

    /// Migrates pre-multi-project configs: the single lastSessionID becomes
    /// the current folder's entry, and the current folder joins the recents.
    private func seedProjectBookkeeping() {
        guard let dir = configStore.config.projectDir, !dir.isEmpty else { return }
        if !configStore.config.recentProjectDirs.contains(dir) {
            configStore.config.recentProjectDirs.insert(dir, at: 0)
        }
        if configStore.config.sessionIDsByProject[dir] == nil,
           let last = configStore.config.lastSessionID {
            configStore.config.sessionIDsByProject[dir] = last
        }
    }

    /// Minimum reply length before a summary is worth a model call — anything
    /// shorter is faster to just speak in full.
    private static let summaryMinimumReplyLength = 350

    /// Speaks a completed reply. Normally that's the reply itself
    /// (markdown-stripped, truncated per settings). With Spoken Summaries on
    /// and a long reply, a lightweight model writes a 1-2 sentence conclusion
    /// and THAT is spoken instead — the full reply stays in the transcript,
    /// `lastAssistantReply`, and Replay. Every summary failure falls back to
    /// the full reply; a summary that arrives after the moment has passed
    /// (new turn, interrupt, an active recording) is dropped.
    private func speakReply(_ reply: String) {
        guard configStore.config.ttsEnabled, !reply.isEmpty else { return }

        let config = configStore.config
        guard config.speakSummaries, reply.count >= AppState.summaryMinimumReplyLength else {
            speakFullReply(reply)
            return
        }

        speechTurnGeneration += 1
        let generation = speechTurnGeneration
        summary.summarize(reply,
                          model: config.summaryModel,
                          claudePathOverride: config.claudePath) { [weak self] text in
            guard let self, generation == self.speechTurnGeneration, !self.isPTTActive else { return }
            guard let text else {
                self.speakFullReply(reply)
                return
            }
            self.appendEntry(.system, "Summary: \(text)")
            let spoken = TTSService.spokenReply(fromMarkdown: text, maxChars: 0)
            guard !spoken.text.isEmpty else {
                self.speakFullReply(reply)
                return
            }
            self.tts.speak(spoken.text,
                           voiceID: self.configStore.config.ttsVoiceID,
                           rate: self.configStore.config.ttsRate,
                           language: spoken.language)
            self.updateStatus()
        }
    }

    private func speakFullReply(_ reply: String) {
        let spoken = TTSService.spokenReply(fromMarkdown: reply, maxChars: configStore.config.maxSpokenChars)
        guard !spoken.text.isEmpty else { return }
        tts.speak(spoken.text,
                  voiceID: configStore.config.ttsVoiceID,
                  rate: configStore.config.ttsRate,
                  language: spoken.language)
    }

    /// A pending summary belongs to a moment that's over — drop it.
    private func cancelPendingSummary() {
        speechTurnGeneration += 1
        summary.cancel()
    }

    func speakLastReply() {
        guard let reply = lastAssistantReply, !reply.isEmpty else {
            errorHaptic()
            return
        }
        let spoken = TTSService.spokenReply(fromMarkdown: reply, maxChars: configStore.config.maxSpokenChars)
        guard !spoken.text.isEmpty else {
            errorHaptic()
            return
        }
        tts.speak(spoken.text,
                  voiceID: configStore.config.ttsVoiceID,
                  rate: configStore.config.ttsRate,
                  language: spoken.language)
        updateStatus()
    }

    // MARK: - Remote control mode

    /// True when input goes to somebody else's Claude session instead of one we
    /// spawned. Read straight from the config so a change from Settings, from the
    /// controller button, or from a hand-edited file all agree instantly.
    var isRemoteMode: Bool {
        AppState.normalizedControlMode(configStore.config.controlMode) == "remote"
    }

    private static func normalizedControlMode(_ raw: String) -> String {
        raw == "remote" ? "remote" : "builtin"
    }

    /// The `.toggleControlMode` action. It only flips the config value — the side
    /// effects live in `syncControlMode()` so the Settings picker gets them too.
    private func toggleControlMode() {
        configStore.config.controlMode = isRemoteMode ? "builtin" : "remote"
        haptic(intensity: 0.5, duration: 0.05)
        syncControlMode()
    }

    private static func harnessKey(for config: AppConfig) -> String {
        [normalizedHarnessKind(config.harnessKind), config.acpAgent, config.acpCustomCommand]
            .joined(separator: "|")
    }

    /// Stops the outgoing session when the harness selection changes (kind,
    /// agent, or custom command); the new harness starts lazily on next send.
    private func syncHarnessSelection() {
        let key = AppState.harnessKey(for: configStore.config)
        guard key != lastHarnessKey else { return }
        lastHarnessKey = key

        pendingPermissionID = nil
        cancelPendingSummary()
        acpAdapter?.stop()
        if claude.state != .stopped {
            expectedTerminations += 1
            claude.stop()
        }

        let kind = AppState.normalizedHarnessKind(configStore.config.harnessKind)
        appendEntry(.system, kind == "acp"
            ? "Harness → \(AppConfig.acpAgentDisplayName(configStore.config.acpAgent)) (ACP). The session starts with your next message."
            : "Harness → built-in Claude Code. The session starts with your next message.")
        updateStatus()
    }

    /// Runs the switch-over work once per actual mode change, whoever caused it.
    private func syncControlMode() {
        let mode = AppState.normalizedControlMode(configStore.config.controlMode)
        guard mode != lastControlMode else { return }
        lastControlMode = mode

        clearRemoteTurns()
        liveAssistantText = ""

        if mode == "remote" {
            // Our own session would otherwise sit there burning a subscription
            // seat and echoing hook events back at us.
            stopClaude()
            remote.refreshStatus()
            appendEntry(.system, "Remote control mode — buttons and voice now drive your existing Claude session.")
            announce("Remote control")
        } else {
            appendEntry(.system, "Built-in session mode — PowerUp runs its own Claude session again.")
            announce("Built-in session")
        }
        updateStatus()
    }

    /// Types text into the remote target, reporting a failure in the transcript
    /// rather than silently doing nothing.
    private func sendRemoteText(_ text: String, submit: Bool) {
        remote.sendText(text, submit: submit, config: configStore.config) { [weak self] error in
            guard let self else { return }
            self.reportRemoteFailure(error)
        }
    }

    private func sendRemoteKey(_ key: RemoteControlService.RemoteKey) {
        remote.sendKey(key, config: configStore.config) { [weak self] error in
            guard let self else { return }
            self.reportRemoteFailure(error)
        }
    }

    private func reportRemoteFailure(_ error: String?) {
        guard let error else {
            updateStatus()
            return
        }
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        appendEntry(.error, trimmed.isEmpty ? "Couldn't reach the remote session." : trimmed)
        errorHaptic()
        updateStatus()
    }

    // MARK: - Hook read-back

    /// Binds (or rebinds) the listener whenever the port or token changes.
    private func syncListener() {
        let config = configStore.config
        let token = config.listenerToken
        // No token means no way to tell a hook post from anything else that finds
        // the port — better to stay off than to listen unauthenticated.
        guard !token.isEmpty else { return }

        let port = AppState.sanitizedPort(config.listenerPort)
        let key = "\(port)|\(token)"
        guard key != lastListenerKey else { return }
        lastListenerKey = key
        listener.start(port: port, token: token)

        // Keep the installed hook script pointing at what we just bound. The
        // script bakes the port/token into its curl command; without this,
        // changing the port would leave every hook POSTing to a dead port while
        // both status indicators stay green. The script is PowerUp's own file —
        // rewriting it never touches ~/.claude/settings.json.
        if HookInstaller.isInstalled(),
           HookInstaller.installState(port: Int(port), token: token) != .installed {
            try? HookInstaller.writeHookScript(port: Int(port), token: token)
        }
    }

    /// Forces the listener to rebind — used after installing the hook script, so
    /// the script and the listener are guaranteed to agree on port and token.
    func restartListener() {
        lastListenerKey = nil
        listener.stop()
        syncListener()
    }

    /// Ports below 1024 need root to bind, so they can only ever fail here.
    static func sanitizedPort(_ port: Int) -> UInt16 {
        guard port >= 1024, port <= 65535 else { return UInt16(AppConfig.defaultListenerPort) }
        return UInt16(port)
    }

    /// Writes the hook script and registers it in ~/.claude/settings.json.
    /// Returns nil on success, or a user-facing message to show in Settings.
    func installRemoteHooks() -> String? {
        let config = configStore.config
        guard !config.listenerToken.isEmpty else {
            return "PowerUp has no listener token yet — reopen Settings and try again."
        }
        let port = Int(AppState.sanitizedPort(config.listenerPort))
        do {
            try HookInstaller.install(port: port, token: config.listenerToken)
        } catch {
            return error.localizedDescription
        }
        restartListener()
        appendEntry(.system, "Claude Code hooks installed — replies from any terminal session will be read back.")
        return nil
    }

    /// Removes only PowerUp's own hook entries. Returns nil on success.
    func uninstallRemoteHooks() -> String? {
        do {
            try HookInstaller.uninstall()
        } catch {
            return error.localizedDescription
        }
        appendEntry(.system, "Claude Code hooks removed.")
        return nil
    }

    /// A hook fired somewhere on this machine. Only remote mode cares, and events
    /// from the session we spawned ourselves are always dropped — otherwise the
    /// built-in session's own replies would come back around as remote read-back.
    private func handleRemoteEvent(_ event: RemoteHookEvent) {
        guard isRemoteMode else { return }
        if let sessionID = event.sessionID, let ours = harness.sessionID, sessionID == ours { return }

        let turnKey = event.sessionID ?? "unknown-session"

        switch event.kind {
        case .userPromptSubmit:
            beginRemoteTurn(key: turnKey)

        case .sessionEnd:
            // The only signal a session that dies mid-turn ever sends. Only a
            // session we believed was working is worth a note — sessions end
            // on this machine all the time.
            if remoteActiveTurns.removeValue(forKey: turnKey) != nil {
                appendEntry(.system, remoteCwdPrefix(event.cwd) + "Claude session ended before replying.")
            }
            refreshRemoteTurnActive()

        case .stop:
            remoteActiveTurns.removeValue(forKey: turnKey)
            refreshRemoteTurnActive()
            let reply = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { break }
            appendEntry(.assistant, remoteCwdPrefix(event.cwd) + reply)
            // Unprefixed, so Replay Last Reply speaks the reply and not the label.
            lastAssistantReply = reply
            haptic(intensity: 0.8, duration: 0.1)
            speakReply(reply)

        case .notification:
            // Sign of life from a turn that's waiting on the user — keep its
            // expiry clock fresh, but a notification alone doesn't start one.
            if remoteActiveTurns[turnKey] != nil {
                remoteActiveTurns[turnKey] = Date()
            }
            let message = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            appendEntry(.system, message.isEmpty ? "Claude needs your attention." : message)
            announce("Claude needs your attention")
        }

        updateStatus()
    }

    /// Records a remote turn starting and schedules the expiry check that
    /// clears it if every ending signal (Stop, SessionEnd) is missed.
    private func beginRemoteTurn(key: String) {
        remoteActiveTurns[key] = Date()
        refreshRemoteTurnActive()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((AppState.remoteTurnExpiry + 1) * 1_000_000_000))
            guard let self else { return }
            self.refreshRemoteTurnActive()
            self.updateStatus()
        }
    }

    /// Recomputes `remoteTurnActive` from the per-session table, dropping
    /// entries whose sessions have gone silent past the expiry.
    private func refreshRemoteTurnActive() {
        let cutoff = Date().addingTimeInterval(-AppState.remoteTurnExpiry)
        remoteActiveTurns = remoteActiveTurns.filter { $0.value > cutoff }
        let active = !remoteActiveTurns.isEmpty
        if remoteTurnActive != active {
            remoteTurnActive = active
        }
    }

    /// Hard reset of remote turn state — the user's escape hatch (Interrupt /
    /// Reject / New Session) and every mode switch land here.
    private func clearRemoteTurns() {
        remoteActiveTurns.removeAll()
        if remoteTurnActive { remoteTurnActive = false }
    }

    /// Labels read-back that came from a different folder than the configured
    /// project, so replies from several sessions stay tellable apart.
    private func remoteCwdPrefix(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let eventPath = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        let project = configStore.config.projectDir ?? ""
        if !project.isEmpty {
            let projectPath = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL.path
            if eventPath == projectPath { return "" }
        }
        let name = URL(fileURLWithPath: eventPath, isDirectory: true).lastPathComponent
        return name.isEmpty ? "" : "[\(name)] "
    }

    // MARK: - Session plumbing

    private func startSession(resumeSessionID: String?) {
        guard let dir = configStore.config.projectDir, !dir.isEmpty else { return }

        // ClaudeService.start() retires any running process by bumping its launch
        // generation, so a replaced process never delivers `.terminated`. Any
        // still-pending expected termination can therefore never arrive — clear
        // the counter so it can't swallow a future real crash (and so the
        // resume-retry-once rule still fires when `--resume` fails).
        expectedTerminations = 0

        startedWithResume = (resumeSessionID != nil)
        liveAssistantText = ""
        // A queued effort change is satisfied by this launch.
        pendingEffortRestart = false
        // The next `system/init` belongs to a fresh launch again.
        didLogSessionStart = false

        let config = configStore.config
        // These go in on the command line, so the CLI is running them by definition.
        lastConfirmedModel = config.model
        lastConfirmedPermissionMode = config.permissionMode

        let isACP = AppState.normalizedHarnessKind(config.harnessKind) == "acp"
        var agentCommand: [String]?
        if isACP {
            guard let command = ACPAdapter.agentCommand(for: config) else {
                appendEntry(.error, "Couldn't find the \(AppConfig.acpAgentDisplayName(config.acpAgent)) command — install it, or pick another harness in Settings → General.")
                updateStatus()
                return
            }
            agentCommand = command
        }

        harness.start(HarnessConfiguration(
            projectDir: URL(fileURLWithPath: dir, isDirectory: true),
            model: config.model,
            permissionMode: config.permissionMode,
            effort: config.effort,
            resumeSessionID: isACP ? nil : resumeSessionID,   // ACP sessions start fresh
            binaryPathOverride: config.claudePath,
            agentCommand: agentCommand
        ))
        updateStatus()
    }

    private func stopClaude() {
        guard harness.state != .stopped else { return }
        expectedTerminations += 1
        harness.stop()
    }

    private func shutdown() {
        tts.stop()
        listener.stop()
        stopClaude()
    }

    // MARK: - Harness events

    private func handleHarnessEvent(_ event: HarnessEvent) {
        switch event {
        case .sessionReady(let sessionID, let model):
            // Only the built-in Claude adapter's ids are resumable with --resume;
            // an ACP session id must never overwrite the stored one.
            if AppState.normalizedHarnessKind(configStore.config.harnessKind) == "claude" {
                configStore.config.lastSessionID = sessionID
                if let dir = configStore.config.projectDir, !dir.isEmpty {
                    configStore.config.sessionIDsByProject[dir] = sessionID
                }
            }
            if !didLogSessionStart {
                didLogSessionStart = true
                // Resuming worked (or we started clean): later exits aren't the id's fault.
                startedWithResume = false
                hasRetriedWithoutResume = false
                appendEntry(.system, "Session started (\(model))")
            }

        case .replyDelta(let chunk):
            liveAssistantText += chunk

        case .reply(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            liveAssistantText = ""
            guard !trimmed.isEmpty else { break }
            appendEntry(.assistant, trimmed)

        case .toolUse(let name, let detail):
            let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            appendEntry(.tool, trimmedDetail.isEmpty ? name : "\(name) — \(trimmedDetail)")

        case .turnCompleted(let resultText, _, let isError, let subtype):
            pendingPermissionID = nil
            liveAssistantText = ""
            let result = (resultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isError {
                let detail = result.isEmpty ? "" : "\n\(result)"
                appendEntry(.error, "Claude ended the turn with an error (\(subtype)).\(detail)")
                errorHaptic()
            } else {
                if !result.isEmpty {
                    lastAssistantReply = result
                }
                haptic(intensity: 0.8, duration: 0.1)
                speakReply(result)
            }
            if pendingEffortRestart {
                // The effort button was pressed mid-turn; the turn is over now.
                // Hop off this event delivery before tearing the process down so
                // the rest of the batch still reaches the session that produced it.
                pendingEffortRestart = false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.harness.state != .working else {
                        // A queued turn started already — wait for that one too.
                        self.pendingEffortRestart = true
                        return
                    }
                    self.restartForEffort()
                }
            }

        case .controlResult(let action, let ok, let detail, let value):
            handleControlResult(action: action, ok: ok, detail: detail, value: value)

        case .permissionRequest(let id, let name, let detail):
            pendingPermissionID = id
            let what = detail.isEmpty ? name : "\(name) — \(detail)"
            appendEntry(.system, "The agent wants to: \(what). Press ✕ to allow or ○ to deny.")
            haptic(intensity: 0.8, duration: 0.1)
            announce("Approval needed")

        case .notification(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            appendEntry(.system, trimmed.isEmpty ? "Claude needs your attention." : trimmed)
            announce("Claude needs your attention")

        case .runtimeError(let message):
            appendEntry(.error, message)

        case .ended(let exitCode):
            pendingPermissionID = nil
            handleTermination(exitCode: exitCode)
        }

        updateStatus()
    }

    /// Answer to one of our control requests. A success needs no announcement —
    /// the optimistic transcript entry already told the user. A failure has to be
    /// rolled back, or the app would keep showing a setting the CLI never took.
    ///
    /// `value` is what the acknowledged request asked for — the confirmed
    /// snapshot must come from it, not from the current config, because with two
    /// requests in flight the config already holds the *newer* value when the
    /// older ack arrives. Likewise a failure only rolls back when the rejected
    /// value is still the one showing; otherwise a newer request owns the field
    /// and its own ack will settle it.
    private func handleControlResult(action: String, ok: Bool, detail: String, value: String?) {
        guard !ok else {
            switch action {
            case "set_model":
                lastConfirmedModel = value ?? configStore.config.model
            case "set_permission_mode":
                lastConfirmedPermissionMode = value ?? configStore.config.permissionMode
            default:
                break
            }
            return
        }

        let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        appendEntry(.error, reason.isEmpty ? "Couldn't apply \(action)." : "Couldn't apply \(action): \(reason)")
        errorHaptic()

        switch action {
        case "set_model":
            let rejected = value ?? configStore.config.model
            if configStore.config.model == rejected, configStore.config.model != lastConfirmedModel {
                configStore.config.model = lastConfirmedModel
                appendEntry(.system, "Model stays \(lastConfirmedModel).")
            }
        case "set_permission_mode":
            let rejected = value ?? configStore.config.permissionMode
            if configStore.config.permissionMode == rejected,
               configStore.config.permissionMode != lastConfirmedPermissionMode {
                configStore.config.permissionMode = lastConfirmedPermissionMode
                appendEntry(.system, "Permissions stay \(lastConfirmedPermissionMode).")
            }
        default:
            break
        }
    }

    private func handleTermination(exitCode: Int32) {
        if expectedTerminations > 0 {
            expectedTerminations -= 1
            return
        }

        // A stale session id makes `--resume` fail before we ever see an init
        // message. Retry exactly once with a fresh session.
        if startedWithResume && !hasRetriedWithoutResume {
            startedWithResume = false
            hasRetriedWithoutResume = true
            configStore.config.lastSessionID = nil
            appendEntry(.system, "Couldn't resume the previous session — starting a fresh one.")
            startSession(resumeSessionID: nil)
            return
        }

        if exitCode == 0 {
            appendEntry(.system, "Claude session ended.")
        } else {
            appendEntry(.error, "Claude session ended unexpectedly (exit code \(exitCode)).")
        }
    }

    // MARK: - Transcript

    private func appendEntry(_ kind: TranscriptEntry.Kind, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = TranscriptEntry(kind: kind, text: trimmed)
        transcript.append(entry)
        transcriptStore.append(entry)
        listener.broadcast(PowerUpProtocol.transcript(entry))
        let overflow = transcript.count - AppState.maxTranscriptEntries
        if overflow > 0 {
            transcript.removeFirst(overflow)
        }
    }

    /// Replaces the window's scrollback with the stored history of the current
    /// project (newest entries, oldest first), topped with a marker so it's
    /// obvious where the earlier conversation ends. The marker is deliberately
    /// NOT persisted — it's set directly instead of going through
    /// `appendEntry`, or every launch would stack another one into the file.
    private func restorePersistedTranscript() {
        var restored = transcriptStore.loadTail()
        guard !restored.isEmpty else { return }
        if restored.count > AppState.maxTranscriptEntries - 1 {
            restored.removeFirst(restored.count - (AppState.maxTranscriptEntries - 1))
        }
        restored.append(TranscriptEntry(kind: .system, text: "Earlier conversation restored — New Session starts clean."))
        transcript = restored
    }

    // MARK: - Derived state

    /// Coalesces the work triggered by service `objectWillChange` notifications.
    /// Those fire *before* the value changes, so we recompute on the next hop.
    private func scheduleDerivedUpdate() {
        guard !statusUpdateScheduled else { return }
        statusUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.statusUpdateScheduled = false
            self.syncSpeechConfiguration()
            // Both are no-ops unless the config actually changed, so Settings
            // edits are picked up without the views having to tell us.
            self.syncControlMode()
            self.syncHarnessSelection()
            self.syncListener()
            RemoteControlService.updateCmuxPassword(self.configStore.config.remoteCmuxPassword)
            self.updateStatus()
            self.broadcastSessionIfChanged()
        }
    }

    /// Single source of truth for `status`, per the design's precedence order.
    private func updateStatus() {
        let newStatus: AppStatus
        if !controller.isConnected {
            newStatus = .noController
        } else if isPTTActive {
            newStatus = .listening
        } else if tts.isSpeaking {
            newStatus = .speaking
        } else if harness.state == .working || (isRemoteMode && remoteTurnActive) {
            // Remote mode has no process of ours to watch: the hooks bracket the
            // turn instead (UserPromptSubmit → Stop).
            newStatus = .thinking
        } else {
            newStatus = .idle
        }

        if newStatus != status {
            status = newStatus
            listener.broadcast(PowerUpProtocol.status(newStatus))
        }
        applyLight(for: newStatus)
    }

    private func applyLight(for status: AppStatus) {
        let color: (r: Float, g: Float, b: Float)
        if configStore.config.lightEnabled {
            switch status {
            case .noController: color = (0.0, 0.0, 0.0)
            case .idle:         color = (0.0, 0.25, 1.0)
            case .listening:    color = (1.0, 0.0, 0.0)
            case .thinking:     color = (1.0, 0.45, 0.0)
            case .speaking:     color = (0.55, 0.0, 1.0)
            }
        } else {
            color = (0.0, 0.0, 0.0)
        }

        let key = "\(color.r),\(color.g),\(color.b)"
        guard key != lastLightKey else { return }
        lastLightKey = key
        controller.setLight(r: color.r, g: color.g, b: color.b)
    }

    private func syncSpeechConfiguration() {
        let config = configStore.config
        let key = "\(config.localeID)|\(config.onDeviceRecognition)"
        guard key != lastSpeechConfigKey else { return }
        lastSpeechConfigKey = key
        speech.configure(localeID: config.localeID, onDevice: config.onDeviceRecognition)
    }

    // MARK: - Haptics

    private func haptic(intensity: Float, duration: TimeInterval) {
        guard configStore.config.hapticsEnabled else { return }
        controller.rumble(intensity: intensity, duration: duration)
    }

    /// Two short buzzes: "that didn't work".
    private func errorHaptic() {
        haptic(intensity: 0.9, duration: 0.06)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            self?.haptic(intensity: 0.9, duration: 0.06)
        }
    }
}
