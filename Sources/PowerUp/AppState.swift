import Foundation
import Combine
import AppKit

/// The time source and one-shot timer behind remote-turn expiry and the
/// remote session registry (DESIGN v1.10, v2.2 A/B), also used to time the
/// error haptic's second buzz. Internal test seam (#118): the app reads the
/// wall clock and sleeps; a test injects a clock it advances by hand, so
/// expiry (and the delayed buzz) is driven without ever waiting.
@MainActor
protocol RemoteTurnClock: AnyObject {
    var now: Date { get }
    /// Runs `action` on the main actor once `delay` seconds have passed.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void)
}

/// The app's clock: `Date()` and a sleeping main-actor Task.
@MainActor
private final class SystemRemoteTurnClock: RemoteTurnClock {
    var now: Date { Date() }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            action()
        }
    }
}

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

    /// The session driver, seen strictly through the harness contract; which
    /// adapter that is follows Settings → General → Harness. The session
    /// rules run in the core and reach the adapters through `HarnessEvent`
    /// and the effects (`execute`). `claude` stays exposed for the views
    /// until the UI fully generalizes.
    var harness: any HarnessAdapter {
        AppState.normalizedHarnessKind(configStore.config.harnessKind) == "acp"
            ? (injectedACPHarness ?? acpAdapterInstance())
            : claudeHarness
    }

    /// Test seams (never set by the app): adapters handed to the initializer
    /// in place of the real ones, wired into the same event handler.
    /// `injectedHarness` stands in for the built-in Claude adapter and
    /// `injectedACPHarness` for the ACP adapter. A test that injects only the
    /// first gets it in both slots, so it IS the harness whatever the config's
    /// harness kind says.
    private let injectedHarness: (any HarnessAdapter)?
    private let injectedACPHarness: (any HarnessAdapter)?

    /// The adapter behind the built-in Claude harness kind.
    private var claudeHarness: any HarnessAdapter { injectedHarness ?? claude }

    /// Lazily created ACP adapter (opencode, the Claude bridge, or a custom
    /// agent command), wired into the same event handler as the Claude adapter.
    private var acpAdapter: ACPAdapter?

    /// What the active harness reports as its model, for the model chip.
    var harnessReportedModel: String? { harness.modelName }

    /// The model chip's label (DESIGN.md v1.3 C). `config.model` wins whenever
    /// it is an explicit alias, so a Cycle Model press shows up instantly
    /// (optimistic); only when the config says "default" does the chip fall
    /// back to whatever the ACTIVE harness reported (Claude adapter or ACP agent).
    var modelChipLabel: String {
        CoreBridge.modelChipLabel(configured: configStore.config.model, reported: harnessReportedModel)
    }

    private func acpAdapterInstance() -> ACPAdapter {
        if let acpAdapter { return acpAdapter }
        let adapter = ACPAdapter()
        adapter.onHarnessEvent = { [weak self, weak adapter] event in
            guard let self, let adapter else { return }
            self.route(event, from: adapter)
        }
        adapter.objectWillChange
            .sink { [weak self] _ in self?.scheduleDerivedUpdate() }
            .store(in: &cancellables)
        acpAdapter = adapter
        return adapter
    }

    /// Which adapter a stored harness kind selects. A one-line wiring
    /// check that must agree with the core's own reading
    /// (`AppStateSeamTests.testRuntimeNormalizationAgreesWithTheCore`).
    nonisolated static func normalizedHarnessKind(_ raw: String) -> String {
        raw == "acp" ? "acp" : "claude"
    }

    /// Delivers input to somebody else's Claude session (cmux surface, or any app
    /// via keystroke injection) when `config.controlMode` is "remote".
    let remote: RemoteControlService
    /// Audio device catalogue: which mics/outputs exist, tracked by stable UID,
    /// with hot-plug updates (Settings pickers + STT/TTS routing).
    let audioDevices: AudioDeviceStore
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
    /// running, so the light bar and status pill lean on this). A mirror of
    /// the session's per-session turn table, kept by its effects; never write
    /// it directly.
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
    private let transcriptStore: TranscriptStore

    private var cancellables: Set<AnyCancellable> = []
    private var statusUpdateScheduled = false

    /// Colour last pushed to the light bar, so we only talk to the controller on change.
    private var lastLightKey: String?
    /// Speech settings last pushed to `SpeechService`, same idea.
    private var lastSpeechConfigKey: String?
    /// Port/token the listener was last started with, so it only rebinds on change.
    private var lastListenerKey: String?
    /// Which control on the active controller owns the running hold (its
    /// `owner`; nil when the pad owns no capture), and the v2.7 §C rules for
    /// what each press and release does. Wherever a capture ends other than
    /// through the tracker (a toggle stop, a denied permission, a vanished
    /// microphone), it is replaced with a fresh `HoldTracker()` so a trigger
    /// still physically held can't end or cancel the next capture.
    private var holdTracker = HoldTracker()
    /// Mode of the capture `startPushToTalk` began; only meaningful while capturing.
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

    /// A remote turn with no hook activity for this long is presumed dead
    /// (missed Stop: killed terminal, crashed CLI, Escape pressed directly in
    /// the session). Long legitimate turns can exceed it — the tradeoff is a
    /// too-early idle that self-corrects on the next hook, versus an amber
    /// light no event will ever clear. Internal so the status tests can pin
    /// the 15 minutes their fixture rows assume; the core owns the value.
    static var remoteTurnExpiry: TimeInterval { CoreBridge.remoteTurnExpiry }

    /// Read-back focus in remote mode: nil = everything (default), else only
    /// this session id is spoken/haptic'd and drives the working light; other
    /// sessions still log (prefixed) into the transcript. A mirror of the
    /// session's focus, kept by its effects.
    @Published private(set) var remoteFocusSessionID: String?

    /// Display name for the focused session (cwd basename, else the first
    /// eight characters of its id), for the chip.
    var remoteFocusLabel: String? { session.remoteFocusLabel }

    /// Bumped whenever the thing worth speaking changes (new turn, interrupt,
    /// PTT start) so a summary that arrives late speaks into the right moment
    /// or not at all.
    private var speechTurnGeneration = 0

    /// The permission request currently awaiting ✕ (allow) / ○ (deny),
    /// published so the main window can banner it. Built-in mode only —
    /// remote mode's Approve/Reject already mean Enter/Escape in the target.
    /// A mirror of the session's, kept by its effects.
    struct PendingPermission: Equatable {
        let id: String
        let name: String
        let detail: String
        /// The classifier flagged this as destructive → two ✕ presses needed.
        let isDestructive: Bool
        /// First ✕ received; the next ✕ confirms if no other intent came in
        /// between (any other intent disarms — see `handle(_:)`).
        var armed: Bool = false
    }
    @Published private(set) var pendingPermission: PendingPermission?

    /// The session rules (DESIGN v2.12): resume retry, effort restart,
    /// destructive confirmation, the setting cycles, project and mode
    /// switches, remote read-back. They run in the Rust core; this class
    /// hands them each call, event and hook with a fresh context and carries
    /// out the effects (`execute`).
    private let session: CoreBridge.Session

    private var willTerminateObserver: NSObjectProtocol?

    // MARK: - Init

    /// The side effects of bringing the app up that reach outside the
    /// process — hardware, ports, global event monitors, subprocesses. The
    /// app runs with `.all`; a test constructs AppState with `[]` so it needs
    /// no pad, binds nothing, prompts nobody and registers no global observer.
    struct SideEffects: OptionSet {
        let rawValue: Int

        /// `ControllerService.start()` — GameController connect/disconnect observers.
        static let startController = SideEffects(rawValue: 1 << 0)
        /// `AudioDeviceStore.start()` — CoreAudio hardware property listener.
        static let startAudioDevices = SideEffects(rawValue: 1 << 1)
        /// Binding the loopback listener (at start-up, on every port/token
        /// change, and on `restartListener()`) and refreshing the hook script.
        static let syncListener = SideEffects(rawValue: 1 << 2)
        /// The app-wide `NSEvent` keyDown monitor (keyboard commands).
        static let keyboardMonitor = SideEffects(rawValue: 1 << 3)
        /// The `NSApplication.willTerminateNotification` shutdown observer.
        static let terminateObserver = SideEffects(rawValue: 1 << 4)
        /// cmux status probes (subprocess + Accessibility check) in remote mode.
        static let cmuxProbe = SideEffects(rawValue: 1 << 5)

        static let all: SideEffects = [.startController, .startAudioDevices, .syncListener,
                                       .keyboardMonitor, .terminateObserver, .cmuxProbe]
    }

    /// Which side effects this instance performs; fixed at construction.
    private let sideEffects: SideEffects

    /// Time for remote-turn expiry and the remote session registry.
    private let remoteTurnClock: any RemoteTurnClock

    /// True once the keyboard command monitor is installed (never in a test).
    var hasKeyboardMonitor: Bool { keyMonitor != nil }
    /// True once the shutdown observer is registered (never in a test).
    var hasTerminateObserver: Bool { willTerminateObserver != nil }

    /// The app's AppState: real services, every side effect on.
    convenience init() {
        self.init(configStore: ConfigStore(), sideEffects: .all)
    }

    /// The one construction path. Any collaborator left nil is created fresh
    /// (real, unstarted); `sideEffects` decides what gets started. Callback
    /// wiring and observation always happen, so injected services reach the
    /// same handlers in a test as in the app. `harness` and `acpHarness` are
    /// the exception to "nil means real": nil keeps the config-selected real
    /// adapter (the app's behavior). A test passes scripted adapters: with
    /// both, `harness` stands in for the built-in Claude adapter and
    /// `acpHarness` for the ACP one, and the config's harness kind picks
    /// between them as in the app; with `harness` alone, that adapter IS the
    /// harness whatever the config's harness kind says. `clock` (nil = the
    /// wall clock) times remote-turn expiry and the error haptic's second
    /// buzz.
    init(configStore store: ConfigStore,
         controller: ControllerService? = nil,
         speech: SpeechService? = nil,
         tts: TTSService? = nil,
         claude: ClaudeService? = nil,
         harness: (any HarnessAdapter)? = nil,
         acpHarness: (any HarnessAdapter)? = nil,
         remote: RemoteControlService? = nil,
         listener: RemoteListener? = nil,
         audioDevices: AudioDeviceStore? = nil,
         transcriptStore: TranscriptStore? = nil,
         clock: (any RemoteTurnClock)? = nil,
         sideEffects: SideEffects) {
        configStore = store
        self.controller = controller ?? ControllerService()
        self.speech = speech ?? SpeechService()
        self.tts = tts ?? TTSService()
        self.claude = claude ?? ClaudeService()
        self.injectedHarness = harness
        self.injectedACPHarness = acpHarness ?? harness
        self.remote = remote ?? RemoteControlService()
        self.listener = listener ?? RemoteListener()
        self.audioDevices = audioDevices ?? AudioDeviceStore()
        self.transcriptStore = transcriptStore ?? TranscriptStore()
        self.remoteTurnClock = clock ?? SystemRemoteTurnClock()
        self.sideEffects = sideEffects

        // ConfigStore mints a token on first launch; the session adopts
        // whatever mode and harness the config already holds without running
        // the switch side effects (HK-166). The bookkeeping seeded below
        // touches neither, so the session can be made first.
        session = CoreBridge.Session(initial: store.config)

        self.transcriptStore.setProject(store.config.projectDir)
        restorePersistedTranscript()
        seedProjectBookkeeping()

        wireController()
        wireClaude()
        wireTTS()
        wireListener()
        wireAudioDevices()
        observeServices()

        // Before the controller starts, so the pads it seeds already land in
        // the pinned slot.
        syncControllerSlot()
        if sideEffects.contains(.startController) {
            self.controller.start()
        }
        if sideEffects.contains(.startAudioDevices) {
            self.audioDevices.start()
        }
        syncAudioAvailabilityBaseline()
        syncSpeechConfiguration()
        syncListener()
        RemoteControlService.updateCmuxPassword(configStore.config.remoteCmuxPassword)
        if isRemoteMode {
            // Populate the cmux availability / workspace list for the UI. All of
            // these probes are read-only.
            refreshRemoteStatus()
        }
        updateStatus()

        if sideEffects.contains(.keyboardMonitor) {
            installKeyMonitor()
        }

        if sideEffects.contains(.terminateObserver) {
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
    }

    /// The cmux probe, gated so a test never spawns a subprocess.
    private func refreshRemoteStatus() {
        guard sideEffects.contains(.cmuxProbe) else { return }
        remote.refreshStatus()
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
        // Low battery: ControllerService latches this to once per connection;
        // surface it like any other system event — transcript entry + error buzz.
        controller.onLowBattery = { [weak self] level in
            guard let self else { return }
            // Truncate, don't round: the latch admits (0, 0.2) exclusive, so a
            // 0.196 reading must not display as the contradictory "20%".
            let percent = Int(level * 100)
            self.appendEntry(.system, "🔋 Controller battery is low (\(percent)%) — plug it in soon.")
            self.errorHaptic()
        }
    }

    private func wireClaude() {
        claude.onHarnessEvent = { [weak self] event in
            guard let self else { return }
            self.route(event, from: self.claude)
        }
        if let injected = injectedHarness {
            injected.onHarnessEvent = { [weak self, weak injected] event in
                guard let self, let injected else { return }
                self.route(event, from: injected)
            }
        }
        if let acp = injectedACPHarness, acp !== injectedHarness {
            acp.onHarnessEvent = { [weak self, weak acp] event in
                guard let self, let acp else { return }
                self.route(event, from: acp)
            }
        }
    }

    /// Hands an adapter's event to the session logic, but only while that
    /// adapter is the active harness. A harness switch stops the outgoing
    /// adapter, yet a stopped claude process can still flush output and exit
    /// up to two seconds later. Those events belong to a retired session: a
    /// late turn completion must not clear the new session's permission
    /// request, and a late exit must not be taken for the new session ending
    /// (it would even run the resume retry and restart the new harness).
    private func route(_ event: HarnessEvent, from adapter: any HarnessAdapter) {
        let kind: CoreBridge.HarnessKind
        if adapter === harness {
            kind = activeHarnessKind
        } else {
            kind = adapter === claudeHarness ? .claude : .acp
        }
        execute(session.harnessEvent(context: sessionContext(), from: kind, event: event))
    }

    private func wireTTS() {
        tts.onFinished = { [weak self] in
            self?.updateStatus()
        }
    }

    /// UID of the chosen microphone the current capture is recording from;
    /// nil while not recording, or when it records from the system default.
    /// Snapshotted when the recognizer starts, so a mid-hold picker change
    /// can't make the unplug check look at the wrong device.
    private var captureInputUID: String?

    /// Tracks the configured devices' presence for the came/went announcements.
    private var inputAvailability = AudioAvailabilityTracker()
    private var outputAvailability = AudioAvailabilityTracker()

    private func wireAudioDevices() {
        // The services resolve the chosen UID to a live device id at use time
        // (each press / each utterance); an unplugged pick resolves nil and
        // they fall back to the system default — which is also what makes
        // auto-restore free when the device returns.
        speech.preferredInputDeviceID = { [weak self] in
            guard let self else { return nil }
            return self.audioDevices.inputDeviceID(forUID: self.configStore.config.audioInputUID)
        }
        tts.preferredOutputDeviceID = { [weak self] in
            guard let self else { return nil }
            return self.audioDevices.outputDeviceID(forUID: self.configStore.config.audioOutputUID)
        }
        audioDevices.onDevicesChanged = { [weak self] in
            // A routed utterance whose device just vanished may never fire
            // its completion — resolve it before deciding what to announce.
            self?.tts.recoverIfEngineDied()
            self?.abortCaptureIfMicrophoneVanished()
            self?.announceAudioDeviceChanges()
        }
    }

    /// The chosen microphone a capture is recording from went away mid-capture.
    /// What was heard is cut off mid-sentence, so it is discarded — never sent,
    /// never left in the prompt box — and the capture ends with the error
    /// buzz. Applies to every capture (hold, mic button, keyboard): unlike a
    /// pad dropping (forceReleaseHold), ending here sends nothing, so it is
    /// safe whoever started it. The next capture falls back to the system
    /// default through the usual per-press resolution.
    private func abortCaptureIfMicrophoneVanished() {
        guard isPTTActive, let uid = captureInputUID,
              audioDevices.inputDevice(forUID: uid) == nil else { return }
        captureInputUID = nil
        isPTTActive = false
        isDraftDictation = false
        // The trigger still physically held must not end the next capture.
        holdTracker = HoldTracker()
        if pttMode == .draft, !pttDraftTargetsRemote {
            endDraftCapture(restoringDraft: true)
        }
        // Ends the recognizer; whatever it still makes of the cut-off audio
        // resolves here and is dropped.
        speech.stopListening { _ in }
        appendEntry(.error, "🎤 Your microphone disconnected while recording — nothing was sent. Try again; PowerUp will use the system default.")
        errorHaptic()
        updateStatus()
    }

    /// The (input, output) selection the trackers were last baselined on.
    private var lastAudioUIDKey: String?

    /// Re-baselines the availability trackers whenever the user's device
    /// selection changes (the tracker consumes a UID change silently — picking
    /// a device is not an unplug), so the FIRST real transition of the newly
    /// picked device announces correctly. Runs from the derived-update path
    /// like the other keyed syncs, and once at init to prime the baseline.
    private func syncAudioAvailabilityBaseline() {
        let config = configStore.config
        let key = "\(config.audioInputUID ?? "")|\(config.audioOutputUID ?? "")"
        guard key != lastAudioUIDKey else { return }
        lastAudioUIDKey = key
        announceAudioDeviceChanges()
    }

    /// One transcript note when a chosen device goes away (we're on the system
    /// default until it returns) and one when it comes back. Selection changes
    /// rebaseline silently inside the tracker.
    private func announceAudioDeviceChanges() {
        let config = configStore.config
        let inputName = audioDevices.inputDevice(forUID: config.audioInputUID)?.name
        switch inputAvailability.check(configuredUID: config.audioInputUID,
                                       isAvailable: inputName != nil) {
        case .becameUnavailable:
            appendEntry(.system, "🎤 Your chosen microphone disconnected — using the system default until it returns.")
        case .becameAvailable:
            appendEntry(.system, "🎤 \(inputName ?? "Your chosen microphone") is back — using it again.")
        case nil:
            break
        }

        let outputName = audioDevices.outputDevice(forUID: config.audioOutputUID)?.name
        switch outputAvailability.check(configuredUID: config.audioOutputUID,
                                        isAvailable: outputName != nil) {
        case .becameUnavailable:
            appendEntry(.system, "🔊 Your chosen speaker disconnected — speaking through the system default until it returns.")
        case .becameAvailable:
            appendEntry(.system, "🔊 \(outputName ?? "Your chosen speaker") is back — speaking through it again.")
        case nil:
            break
        }
    }

    private func wireListener() {
        listener.onEvent = { [weak self] event in
            guard let self else { return }
            self.execute(self.session.hookEvent(context: self.sessionContext(), hook: event))
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
                                costUSD: harness.totalCostUSD,
                                tokens: harness.totalTokens)
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
                   String(harness.totalCostUSD),
                   String(harness.totalTokens)].joined(separator: "|")
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
            listener.objectWillChange,
            audioDevices.objectWillChange
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
        // Resolve through the (profile, control) mapper — the same path every
        // future input surface (HID profiles, virtual devices) routes through.
        // The DualSense service still speaks the enum; its control ids are the
        // enum's raw values. Only the controller in the slot delivers presses,
        // so its profile is the one to resolve against (DESIGN v2.7 B).
        let action = configStore.config.action(
            onProfile: controller.active?.profileID ?? DeviceProfile.dualSenseID,
            control: button.rawValue)
        apply(holdTracker.effect(for: action, control: button.rawValue, phase: .began,
                                 toggleCaptureActive: isToggleCaptureActive))
    }

    private func handleButtonUp(_ button: ControllerButton) {
        // The tracker ends the capture only for the control that started it,
        // whatever that control is mapped to *now* — so a mapping edit mid-hold
        // can't strand the recorder, and every other release (both releases
        // after a cancel included) does nothing.
        let action = configStore.config.action(
            onProfile: controller.active?.profileID ?? DeviceProfile.dualSenseID,
            control: button.rawValue)
        apply(holdTracker.effect(for: action, control: button.rawValue, phase: .ended,
                                 toggleCaptureActive: isToggleCaptureActive))
    }

    /// A capture is running that the pad does not own: started by the mic
    /// button or the keyboard, which have no press/release pair (v2.6). A hold
    /// press during it is ignored rather than taken as a second hold (v2.7 §C).
    private var isToggleCaptureActive: Bool {
        isPTTActive && holdTracker.owner == nil
    }

    /// Turns one hold-tracker effect into today's capture paths (v2.7 §C).
    private func apply(_ effect: HoldEffect) {
        switch effect {
        case .beginCapture(let mode):
            handle(.beginVoiceCapture(mode))
        case .endCapture:
            handle(.endVoiceCapture)
        case .cancelCapture:
            cancelHoldCapture()
        case .deliver(let intent):
            handle(intent)
        case .ignore:
            break
        }
    }

    /// Two holds on the active controller cancel both (v2.7 §C): the capture
    /// ends without sending or drafting — the recognizer is stopped without
    /// consulting its transcript, a local draft hold puts the prompt box back
    /// as it was — and the pad gets the error haptic. The tracker has already
    /// cleared its owner, so neither trigger's later release does anything.
    private func cancelHoldCapture() {
        if isPTTActive {
            isPTTActive = false
            isDraftDictation = false
            captureInputUID = nil
            // Only a local draft hold mirrored partials into the prompt box; a
            // remote draft hold has typed nothing yet, so there is nothing to undo.
            if pttMode == .draft, !pttDraftTargetsRemote {
                endDraftCapture(restoringDraft: true)
            }
            // Ends the recognizer (or nothing, while the permission prompt is
            // still up); whatever it makes of the audio resolves here and is dropped.
            speech.stopListening { _ in }
        }
        errorHaptic()
        updateStatus()
    }

    /// Safety net for a hold that can no longer be released the normal way —
    /// the controller disconnected between the button's down and up events,
    /// or the Controller slot changed to another pad (v2.7 §C). Ends a
    /// CONTROLLER-owned hold so the mic and status can never stay wedged.
    /// Deliberately scoped to the tracker's owner: a capture started from the
    /// mic button or the keyboard has nothing to do with the pad, keeps its
    /// working stop affordances (mic click, ⌘D/⇧⌘D), and must survive a pad
    /// powering off mid-dictation — ending a `.send` capture here would fire
    /// the half-finished transcript at Claude uninvited.
    func forceReleaseHold() {
        apply(holdTracker.releaseAll())
    }

    /// Toggle-style voice capture for input sources that have no press/release
    /// pair — the on-screen mic button and the keyboard shortcuts. A click (or
    /// key press) while idle starts a capture in `mode`; the next one ends
    /// whatever capture is active, regardless of who started it or in which
    /// mode. Resetting the hold tracker on the way out means a controller
    /// trigger still physically held after a keyboard stop can't end (or
    /// cancel) the *next* capture when it is finally released.
    func toggleVoiceCapture(_ mode: VoiceCaptureMode) {
        if isPTTActive {
            holdTracker = HoldTracker()
            handle(.endVoiceCapture)
        } else {
            // The UI disables its mic button and menu items on this same
            // condition, but a command menu's disabled state can lag the
            // config — the model-level guard is the one that holds.
            guard canAcceptInput else { return }
            handle(.beginVoiceCapture(mode))
        }
    }

    /// True when there is somewhere for input to go: a project folder for the
    /// built-in session, or remote mode (where input targets someone else's
    /// session). Gates the mic button and the Voice menu items, mirroring the
    /// composer's own rule.
    var canAcceptInput: Bool {
        configStore.config.projectDir != nil || isRemoteMode
    }

    /// Mouse path for a pending harness permission request — the banner's
    /// Allow/Deny buttons, so tool approvals don't require a controller.
    /// Routes through the same intents as ✕/○ (destructive arming included),
    /// but no-ops when nothing is pending: a click that races the request
    /// being resolved elsewhere must not fall through to Approve's
    /// "send Yes/No as text" branch.
    func answerPendingPermission(allow: Bool) {
        execute(session.answerPendingPermission(context: sessionContext(), allow: allow))
    }

    // MARK: - Keyboard shortcuts (local event monitor)

    /// The app's keyboard shortcut vocabulary. Delivered by the NSEvent
    /// monitor below — NOT by SwiftUI key equivalents: on macOS 26, AppKit's
    /// key-equivalent routing into a commands-menu Button traps in
    /// `MainActor.assumeIsolated` inside SwiftUI's `ButtonAction` (an OS bug
    /// with macOS 14 SDK builds; the crash fires before the action closure
    /// ever runs). The menu items keep their `.keyboardShortcut` modifiers
    /// purely so the menu displays the glyphs; the monitor sees every key
    /// event first and consumes ours, so that routing is never reached.
    enum KeyboardCommand: Equatable {
        case dictateToggle   // ⌘D
        case talkToggle      // ⇧⌘D
        case newSession      // ⌘N
        case sendDraft       // ⌘↩
        case openSettings    // ⌘, — the system item's key routing traps too
    }

    /// Pure chord → command mapping, pinned by `KeyboardCommandTests`.
    /// `key` is `charactersIgnoringModifiers` lowercased; extra modifiers
    /// (⌥, ⌃) make a chord not-ours so text-editing combos pass through.
    nonisolated static func keyboardCommand(forKey key: String,
                                            modifiers: NSEvent.ModifierFlags) -> KeyboardCommand? {
        let chord = modifiers.intersection([.command, .shift, .option, .control])
        if key == "d" {
            if chord == [.command] { return .dictateToggle }
            if chord == [.command, .shift] { return .talkToggle }
            return nil
        }
        if key == "n", chord == [.command] { return .newSession }
        if key == ",", chord == [.command] { return .openSettings }
        // Return and keypad Enter both mean "send" under ⌘.
        if key == "\r" || key == "\u{3}" {
            if chord == [.command] { return .sendDraft }
        }
        return nil
    }

    private var keyMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let command = AppState.keyboardCommand(forKey: key, modifiers: event.modifierFlags)
            else { return event }
            self.perform(command)
            return nil    // consumed — never reaches menu key-equivalent routing
        }
    }

    private func perform(_ command: KeyboardCommand) {
        switch command {
        case .dictateToggle:
            toggleVoiceCapture(.draft)
        case .talkToggle:
            toggleVoiceCapture(.send)
        case .newSession:
            newSession()
        case .sendDraft:
            // Mirror the composer's gate: with nowhere for input to go its
            // send button is disabled, and ⌘↩ must not behave differently.
            guard canAcceptInput else { return }
            sendDraft()
        case .openSettings:
            openSettingsWindow()
        }
    }

    /// Opens the Settings scene by firing the app menu's own "Settings…"
    /// item (action → target). Every conventional route is broken on
    /// macOS 26 for macOS 14 SDK builds — `SettingsLink` silently does
    /// nothing, and `showSettingsWindow:` is accepted (sendAction returns
    /// true) but never presents the window; firing the menu item's own
    /// wiring is what the OS still honors (probe-verified 2026-08-31).
    /// The item is found by its ⌘, key equivalent, not its localized title.
    func openSettingsWindow() {
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let item = appMenu.items.first(where: { $0.keyEquivalent == "," }),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        // No Settings… item found (unexpected) — try the legacy selector.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - Intent dispatch

    /// The single dispatcher every input source funnels into: controller
    /// buttons (via the mapping), and protocol clients (via the listener).
    func handle(_ intent: Intent) {
        // The session runs its own intents and disarms an armed destructive
        // confirmation on anything but Approve (the request stays pending),
        // so a stray Approve later can never complete a confirmation the
        // person moved on from. The rest are the platform's.
        execute(session.handleIntent(context: sessionContext(), intent: intent))
        switch intent {
        case .beginVoiceCapture(let mode):
            startPushToTalk(mode: mode)
        case .endVoiceCapture:
            stopPushToTalk()
        case .sendDraft:
            sendDraft()
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
        case .showWindow:
            showWindow()
        case .cycleProject:
            // Which recents still exist is the filesystem's answer; stepping
            // through them is the session's.
            let existing = configStore.config.recentProjectDirs.filter {
                FileManager.default.fileExists(atPath: $0)
            }
            execute(session.cycleProject(context: sessionContext(), existingRecents: existing))
        case .sendPrompt, .approve, .reject, .interrupt, .newSession, .cycleModel, .cycleEffort,
             .cyclePermissionMode, .cycleFocus, .toggleControlMode:
            break
        }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Spoken confirmations

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
                self.holdTracker = HoldTracker()
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
            // Same resolution SpeechService does for the engine: the chosen
            // mic when it is present, else the system default (nil).
            let chosenUID = self.configStore.config.audioInputUID
            self.captureInputUID = self.audioDevices.inputDevice(forUID: chosenUID) != nil ? chosenUID : nil
            self.speech.startListening()
        }
    }

    private func stopPushToTalk() {
        guard isPTTActive else { return }
        isPTTActive = false
        isDraftDictation = false
        captureInputUID = nil

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

    /// Starts the selected harness when nothing runs, resuming the folder's
    /// own session. Remote mode never starts one of its own.
    func startSessionIfNeeded() {
        execute(session.startSessionIfNeeded(context: sessionContext()))
    }

    func newSession() {
        execute(session.newSession(context: sessionContext()))
    }

    func sendUserText(_ text: String) {
        execute(session.sendUserText(context: sessionContext(), text: text))
    }

    func interruptClaude() {
        execute(session.interrupt(context: sessionContext()))
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
        execute(session.adoptProject(context: sessionContext(), path: url.path, moveToFront: true))
    }

    /// Switch to a specific known project (Settings recents list): its own
    /// session id, its own transcript history and, in built-in mode, a
    /// session resuming that folder's conversation.
    func switchProject(to path: String) {
        execute(session.switchProject(context: sessionContext(), path: path))
    }

    /// Migrates pre-multi-project configs: the single lastSessionID becomes
    /// the current folder's entry, and the current folder joins the recents.
    private func seedProjectBookkeeping() {
        // The rule is the core's (`config::seed_project_bookkeeping`); the
        // store is only written when it changes anything.
        if let seeded = CoreBridge.seedProjectBookkeeping(configStore.config),
           seeded != configStore.config {
            configStore.config = seeded
        }
    }

    /// Minimum reply length before a summary is worth a model call — anything
    /// shorter is faster to just speak in full.
    private static let summaryMinimumReplyLength = 350

    /// Whether a completed reply goes to the summarizer instead of being
    /// spoken in full: Spoken Summaries on, and at least
    /// `summaryMinimumReplyLength` Characters (extended grapheme clusters).
    static func wantsSummary(of reply: String, speakSummaries: Bool) -> Bool {
        speakSummaries && reply.count >= summaryMinimumReplyLength
    }

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
        guard AppState.wantsSummary(of: reply, speakSummaries: config.speakSummaries) else {
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

    nonisolated static func normalizedControlMode(_ raw: String) -> String {
        raw == "remote" ? "remote" : "builtin"
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
        guard sideEffects.contains(.syncListener) else { return }
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

    /// The turn table with expired entries dropped: an entry survives only
    /// while its last sign of life is strictly newer than `now - expiry`.
    /// Pure, in the core; pinned by Tests/Fixtures/status/remote-turns.json.
    nonisolated static func liveRemoteTurns(_ turns: [String: Date],
                                            now: Date,
                                            expiry: TimeInterval) -> [String: Date] {
        CoreBridge.liveRemoteTurns(turns, now: now, expiry: expiry)
    }

    /// Whether a remote turn lights the bar: any live entry, or — with a
    /// focus set — only the focused session's (DESIGN v2.2 §B). Pure, in the
    /// core; pinned by Tests/Fixtures/status/remote-turns.json.
    nonisolated static func remoteTurnIsActive(_ turns: [String: Date], focus: String?) -> Bool {
        CoreBridge.remoteTurnIsActive(turns, focus: focus)
    }

    // MARK: - Carrying out the session's effects

    private var activeHarnessKind: CoreBridge.HarnessKind {
        AppState.normalizedHarnessKind(configStore.config.harnessKind) == "acp" ? .acp : .claude
    }

    private func adapter(for kind: CoreBridge.HarnessKind) -> any HarnessAdapter {
        switch kind {
        case .claude: return claudeHarness
        case .acp: return injectedACPHarness ?? acpAdapterInstance()
        }
    }

    /// What one session call reads: the config as it is now, each adapter
    /// as it is now, and the injected clock's time. The ACP adapter is
    /// created lazily, so it is reported only once it exists (or is
    /// selected). A test that injects one adapter for both slots shows it
    /// as the ACP adapter only while ACP is selected.
    private func sessionContext() -> CoreBridge.SessionContext {
        let config = configStore.config
        let acpSelected = activeHarnessKind == .acp
        let acpInstance: (any HarnessAdapter)? = injectedACPHarness ?? (acpSelected ? acpAdapterInstance() : acpAdapter)
        var acpSnapshot: CoreBridge.HarnessSnapshot?
        if let acpInstance, acpInstance !== claudeHarness || acpSelected {
            acpSnapshot = CoreBridge.HarnessSnapshot(of: acpInstance)
        }
        return CoreBridge.SessionContext(config: config,
                                         claude: CoreBridge.HarnessSnapshot(of: claudeHarness),
                                         acp: acpSnapshot,
                                         acpAgentCommand: acpSelected ? ACPAdapter.agentCommand(for: config) : nil,
                                         now: remoteTurnClock.now)
    }

    /// Carries out the session's effects in order (DESIGN v2.12). A harness
    /// call can make its adapter report an event at once; that event
    /// re-enters the session, and its effects run here before the rest.
    private func execute(_ effects: [CoreBridge.SessionEffect]) {
        for effect in effects {
            switch effect {
            case .startHarness(let kind, let configuration):
                adapter(for: kind).start(configuration)
            case .sendToHarness(let kind, let text):
                // Checked again now: an adapter whose start failed at once
                // has nothing to send to.
                let target = adapter(for: kind)
                if target.state == .stopped {
                    execute(session.sendRefused(context: sessionContext()))
                } else {
                    target.send(text)
                }
            case .interruptHarness(let kind):
                adapter(for: kind).interrupt()
            case .setHarnessModel(let kind, let model):
                adapter(for: kind).setModel(model)
            case .setHarnessPermissionMode(let kind, let mode):
                adapter(for: kind).setPermissionMode(mode)
            case .answerPermission(let kind, let id, let allow):
                adapter(for: kind).respondToPermission(id: id, allow: allow)
            case .stopHarness(let kind):
                adapter(for: kind).stop()
            case .changeConfig(let change):
                applyConfigChange(change)
            case .appendTranscript(let kind, let text):
                appendEntry(kind, text)
            case .showProjectTranscript(let projectDir, let restoreHistory):
                // Transcript history is per project: switch the store over and
                // swap the window's scrollback for the new project's history.
                transcriptStore.setProject(projectDir)
                if restoreHistory {
                    transcript = []
                    restorePersistedTranscript()
                }
            case .appendLiveReply(let text):
                liveAssistantText += text
            case .clearLiveReply:
                liveAssistantText = ""
            case .setLastReply(let text):
                lastAssistantReply = text
            case .pendingPermissionChanged(let pending):
                pendingPermission = pending
            case .remoteTurnActiveChanged(let active):
                remoteTurnActive = active
            case .remoteFocusChanged(let sessionID):
                remoteFocusSessionID = sessionID
            case .haptic(let intensity, let duration):
                haptic(intensity: intensity, duration: duration)
            case .errorHaptic:
                errorHaptic()
            case .announce(let phrase):
                announce(phrase)
            case .speakReply(let text):
                speakReply(text)
            case .cancelSummary:
                cancelPendingSummary()
            case .stopSpeaking:
                tts.stop()
            case .injectText(let text, let submit):
                sendRemoteText(text, submit: submit)
            case .injectKey(let key):
                sendRemoteKey(key)
            case .refreshRemoteStatus:
                refreshRemoteStatus()
            case .scheduleRemoteTurnCheck(let delay):
                remoteTurnClock.schedule(after: delay) { [weak self] in
                    guard let self else { return }
                    self.execute(self.session.remoteTurnCheck(context: self.sessionContext()))
                }
            case .deferEffortRestart:
                // Off this event delivery before the process is torn down, so
                // the rest of the batch still reaches the session that made it.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.execute(self.session.deferredEffortRestart(context: self.sessionContext()))
                }
            case .updateStatus:
                updateStatus()
            }
        }
    }

    private func applyConfigChange(_ change: CoreBridge.ConfigChange) {
        switch change {
        case .model(let value): configStore.config.model = value
        case .effort(let value): configStore.config.effort = value
        case .permissionMode(let value): configStore.config.permissionMode = value
        case .controlMode(let value): configStore.config.controlMode = value
        case .projectDir(let path): configStore.config.projectDir = path
        case .lastSessionID(let sessionID): configStore.config.lastSessionID = sessionID
        case .projectSessionID(let projectDir, let sessionID):
            if let sessionID {
                configStore.config.sessionIDsByProject[projectDir] = sessionID
            } else {
                configStore.config.sessionIDsByProject.removeValue(forKey: projectDir)
            }
        case .recentProjectDirs(let paths): configStore.config.recentProjectDirs = paths
        }
    }

    private func shutdown() {
        tts.stop()
        listener.stop()
        execute(session.shutdown(context: sessionContext()))
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
            self.syncControllerSlot()
            self.syncSpeechConfiguration()
            self.syncAudioAvailabilityBaseline()
            // The control mode, then the harness selection: each a no-op
            // unless the config actually changed, so Settings edits are
            // picked up without the views having to tell us.
            self.execute(self.session.syncSettings(context: self.sessionContext()))
            self.syncListener()
            RemoteControlService.updateCmuxPassword(self.configStore.config.remoteCmuxPassword)
            self.updateStatus()
            self.broadcastSessionIfChanged()
        }
    }

    /// Single source of truth for `status`, per the design's precedence order.
    private func updateStatus() {
        // Remote mode has no process of ours to watch: the hooks bracket the
        // turn instead (UserPromptSubmit → Stop) — hence remoteTurnActive.
        let newStatus = AppState.derivedStatus(
            controllerConnected: controller.isConnected,
            isPTTActive: isPTTActive,
            isSpeaking: tts.isSpeaking,
            isWorking: AppState.derivedIsWorking(harnessState: harness.state,
                                                 isRemoteMode: isRemoteMode,
                                                 remoteTurnActive: remoteTurnActive))

        if newStatus != status {
            status = newStatus
            listener.broadcast(PowerUpProtocol.status(newStatus))
        }
        applyLight(for: newStatus)
    }

    /// Pure status derivation, in the core (DESIGN v2.6, v2.12; the full
    /// precedence table is Tests/Fixtures/status/derivation.json). Live
    /// activity outranks the missing controller: the pad is optional — voice
    /// capture can be started from the mic button or the keyboard, replies
    /// still speak, and turns still run — so "No Controller" is only the
    /// *resting* state, never a mask over what the app is doing right now.
    nonisolated static func derivedStatus(controllerConnected: Bool,
                                          isPTTActive: Bool,
                                          isSpeaking: Bool,
                                          isWorking: Bool) -> AppStatus {
        CoreBridge.derivedStatus(controllerConnected: controllerConnected, isPTTActive: isPTTActive,
                                 isSpeaking: isSpeaking, isWorking: isWorking)
    }

    /// The `isWorking` input to `derivedStatus` (DESIGN v2.6 §B): the harness
    /// is working, or — in remote mode only — a hooked session's turn is
    /// active. A remote-turn flag left over in built-in mode never counts.
    /// Pure, in the core; pinned by Tests/Fixtures/status/working.json.
    nonisolated static func derivedIsWorking(harnessState: HarnessState,
                                             isRemoteMode: Bool,
                                             remoteTurnActive: Bool) -> Bool {
        CoreBridge.derivedIsWorking(harnessState: harnessState, isRemoteMode: isRemoteMode,
                                    remoteTurnActive: remoteTurnActive)
    }

    private func applyLight(for status: AppStatus) {
        let color: (r: Float, g: Float, b: Float)
        if configStore.config.lightEnabled {
            switch status {
            case .noController: color = (0.0, 0.0, 0.0)
            case .idle:         color = (0.0, 1.0, 0.2)
            case .listening:    color = (1.0, 0.0, 0.0)
            case .thinking:     color = (1.0, 0.45, 0.0)
            case .speaking:     color = (0.55, 0.0, 1.0)
            }
        } else {
            color = (0.0, 0.0, 0.0)
        }

        // The key includes which controller fills the slot: with activity now
        // outranking .noController, a pad that (re)connects mid-listening/
        // -thinking sees no status change, and a slot change between two
        // connected pads changes neither status nor connection state, so the
        // color alone would memo-match and the pad now in the slot would keep
        // its firmware default (or the dark it was given). setLight with the
        // slot empty is a harmless no-op, so keying on the active id is
        // exactly the re-push needed.
        let key = "\(controller.active?.id ?? "-")|\(color.r),\(color.g),\(color.b)"
        guard key != lastLightKey else { return }
        lastLightKey = key
        controller.setLight(r: color.r, g: color.g, b: color.b)
    }

    /// Hands the Controller slot pin (DESIGN v2.7 B) to the controller
    /// service, which re-selects the slot only when the pin actually changed.
    private func syncControllerSlot() {
        controller.pinnedControllerID = configStore.config.controllerDeviceID
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
    /// The second buzz is timed on the injected clock (the wall clock in
    /// the app), so a test sees it only when it advances that clock.
    private func errorHaptic() {
        haptic(intensity: 0.9, duration: 0.06)
        remoteTurnClock.schedule(after: 0.14) { [weak self] in
            self?.haptic(intensity: 0.9, duration: 0.06)
        }
    }
}
