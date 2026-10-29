import Foundation
import PowerUpCore

// MARK: - The session (slice 2.3)
//
// AppState's session rules, the status derivation, the destructive-action
// classifier and the setting cycles run in the Rust core (DESIGN v2.12).
// AppState keeps the adapters, the config store, the transcript, speech,
// haptics and the remote injector, and carries out the effects.

extension CoreBridge {

    /// Which adapter an effect or an event belongs to.
    enum HarnessKind: Equatable {
        case claude, acp
    }

    /// One adapter as the session sees it at the moment of a call.
    struct HarnessSnapshot: Equatable {
        var state: HarnessState
        var sessionID: String?
        var modelName: String?
        var supportsEffort: Bool

        init(state: HarnessState, sessionID: String?, modelName: String?, supportsEffort: Bool) {
            self.state = state
            self.sessionID = sessionID
            self.modelName = modelName
            self.supportsEffort = supportsEffort
        }

        /// What `adapter` shows now. Adapters live on the main actor.
        @MainActor
        init(of adapter: any HarnessAdapter) {
            self.init(state: adapter.state, sessionID: adapter.sessionID, modelName: adapter.modelName,
                      supportsEffort: adapter.supportsEffort)
        }
    }

    /// A path as this Mac's filesystem places it (HK-398). The session
    /// never touches the filesystem: the folder rules run on these values.
    struct PlacedPath: Equatable {
        /// The standardized path's components after resolving symlinks,
        /// the root first.
        let components: [String]
        /// The standardized path, symlinks left as they are.
        let standardized: String
        /// The last component of `standardized`.
        let name: String

        /// `path` read as a directory, as AppState placed hook folders
        /// before the rules moved: membership resolves symlinks, the label
        /// does not (HK-113, HK-115).
        static func place(_ path: String) -> PlacedPath {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let standardized = url.path
            return PlacedPath(components: url.resolvingSymlinksInPath().pathComponents,
                              standardized: standardized,
                              name: URL(fileURLWithPath: standardized, isDirectory: true).lastPathComponent)
        }
    }

    /// Everything one session call reads: the settings as they are now
    /// (read live per call, HK-165), each adapter's state and the time.
    struct SessionContext {
        var config: AppConfig
        var claude: HarnessSnapshot
        /// nil until the ACP adapter exists (it is created lazily).
        var acp: HarnessSnapshot?
        /// The ACP agent's command line; filled only while ACP is selected,
        /// nil then meaning the agent was not found.
        var acpAgentCommand: [String]?
        var now: Date
    }

    /// One config write.
    enum ConfigChange: Equatable {
        case model(String)
        case effort(String)
        case permissionMode(String)
        case controlMode(String)
        case projectDir(String)
        case lastSessionID(String?)
        /// nil removes the folder's entry.
        case projectSessionID(projectDir: String, sessionID: String?)
        case recentProjectDirs([String])
    }

    /// What the session asks AppState to do. Run them in order, each
    /// before the next; one that makes an adapter report an event at once
    /// re-enters the session with a fresh context, and that call's effects
    /// run before the rest (DESIGN v2.12).
    enum SessionEffect: Equatable {
        case startHarness(HarnessKind, HarnessConfiguration)
        /// Checked again when it runs: a stopped adapter (its start failed
        /// at once) gets `sendRefused(context:)` instead.
        case sendToHarness(HarnessKind, text: String)
        case interruptHarness(HarnessKind)
        case setHarnessModel(HarnessKind, model: String)
        case setHarnessPermissionMode(HarnessKind, mode: String)
        case answerPermission(HarnessKind, id: String, allow: Bool)
        case stopHarness(HarnessKind)
        case changeConfig(ConfigChange)
        /// Trimmed and dropped when empty, as every transcript entry.
        case appendTranscript(TranscriptEntry.Kind, String)
        case showProjectTranscript(projectDir: String, restoreHistory: Bool)
        case appendLiveReply(String)
        case clearLiveReply
        case setLastReply(String)
        case pendingPermissionChanged(AppState.PendingPermission?)
        case remoteTurnActiveChanged(Bool)
        case remoteFocusChanged(String?)
        case haptic(intensity: Float, duration: TimeInterval)
        case errorHaptic
        case announce(String)
        case speakReply(String)
        case cancelSummary
        case stopSpeaking
        case injectText(String, submit: Bool)
        case injectKey(RemoteControlService.RemoteKey)
        case refreshRemoteStatus
        /// Call `remoteTurnCheck(context:)` after this long.
        case scheduleRemoteTurnCheck(after: TimeInterval)
        /// Call `deferredEffortRestart(context:)` once the current event
        /// delivery is over (HK-082).
        case deferEffortRestart
        case updateStatus
    }

    /// AppState's session rules (DESIGN v2.12). One per AppState, created
    /// once the launch bookkeeping is seeded; it adopts the stored control
    /// mode and harness selection without acting on them (HK-166). Call it
    /// from the main actor only. A core failure is logged and gives no
    /// effects.
    final class Session {
        private let core: CoreSession?

        init(initial config: AppConfig) {
            core = CoreBridge.call("CoreSession.init", fallback: nil) {
                try CoreSession(initial: CoreSessionSettings(config))
            }
        }

        private func run(_ name: String, _ context: SessionContext,
                         _ body: (CoreSession, CoreSessionContext) throws -> [CoreSessionEffect]) -> [SessionEffect] {
            guard let core else { return [] }
            return CoreBridge.call("CoreSession.\(name)", fallback: []) {
                try body(core, context.core).map(SessionEffect.init)
            }
        }

        func startSessionIfNeeded(context: SessionContext) -> [SessionEffect] {
            run("startSessionIfNeeded", context) { try $0.startSessionIfNeeded(context: $1) }
        }

        func newSession(context: SessionContext) -> [SessionEffect] {
            run("newSession", context) { try $0.newSession(context: $1) }
        }

        func sendUserText(context: SessionContext, text: String) -> [SessionEffect] {
            run("sendUserText", context) { try $0.sendUserText(context: $1, text: text) }
        }

        func interrupt(context: SessionContext) -> [SessionEffect] {
            run("interrupt", context) { try $0.interrupt(context: $1) }
        }

        func answerPendingPermission(context: SessionContext, allow: Bool) -> [SessionEffect] {
            run("answerPendingPermission", context) { try $0.answerPendingPermission(context: $1, allow: allow) }
        }

        func adoptProject(context: SessionContext, path: String, moveToFront: Bool) -> [SessionEffect] {
            run("adoptProject", context) { try $0.adoptProject(context: $1, path: path, moveToFront: moveToFront) }
        }

        func switchProject(context: SessionContext, path: String) -> [SessionEffect] {
            run("switchProject", context) { try $0.switchProject(context: $1, path: path) }
        }

        /// `existingRecents`: the recents, in order, that still exist on disk.
        func cycleProject(context: SessionContext, existingRecents: [String]) -> [SessionEffect] {
            run("cycleProject", context) { try $0.cycleProject(context: $1, existingRecents: existingRecents) }
        }

        func handleIntent(context: SessionContext, intent: Intent) -> [SessionEffect] {
            run("handleIntent", context) { try $0.handleIntent(context: $1, intent: intent.core) }
        }

        /// An adapter's event; `from` is the adapter that reported it.
        func harnessEvent(context: SessionContext, from: HarnessKind, event: HarnessEvent) -> [SessionEffect] {
            run("harnessEvent", context) { try $0.harnessEvent(context: $1, from: from.core, event: event.core) }
        }

        /// A Claude Code hook. Its folder and the project folder are placed
        /// with `place` when they are non-empty.
        func hookEvent(context: SessionContext, hook: RemoteHookEvent,
                       place: (String) -> PlacedPath = PlacedPath.place) -> [SessionEffect] {
            func placed(_ path: String?) -> CorePlacedPath? {
                guard let path, !path.isEmpty else { return nil }
                return place(path).core
            }
            let coreHook = CoreHookEvent(kind: hook.kind.core, text: hook.text, sessionId: hook.sessionID,
                                         cwd: hook.cwd, cwdPlace: placed(hook.cwd))
            let projectPlace = placed(context.config.projectDir)
            return run("hookEvent", context) { try $0.hookEvent(context: $1, hook: coreHook, projectPlace: projectPlace) }
        }

        func remoteTurnCheck(context: SessionContext) -> [SessionEffect] {
            run("remoteTurnCheck", context) { try $0.remoteTurnCheck(context: $1) }
        }

        func deferredEffortRestart(context: SessionContext) -> [SessionEffect] {
            run("deferredEffortRestart", context) { try $0.deferredEffortRestart(context: $1) }
        }

        /// The derived-update pass after any settings change.
        func syncSettings(context: SessionContext) -> [SessionEffect] {
            run("syncSettings", context) { try $0.syncSettings(context: $1) }
        }

        func sendRefused(context: SessionContext) -> [SessionEffect] {
            run("sendRefused", context) { try $0.sendRefused(context: $1) }
        }

        func shutdown(context: SessionContext) -> [SessionEffect] {
            run("shutdown", context) { try $0.shutdown(context: $1) }
        }

        /// The permission request waiting for an answer; nil when the core
        /// fails.
        var pendingPermission: AppState.PendingPermission? {
            guard let core else { return nil }
            return CoreBridge.call("CoreSession.pendingPermission", fallback: nil) {
                try core.pendingPermission().map(AppState.PendingPermission.init)
            }
        }

        var remoteTurnActive: Bool {
            guard let core else { return false }
            return CoreBridge.call("CoreSession.remoteTurnActive", fallback: false) { try core.remoteTurnActive() }
        }

        var remoteFocus: String? {
            guard let core else { return nil }
            return CoreBridge.call("CoreSession.remoteFocus", fallback: nil) { try core.remoteFocus() }
        }

        var remoteFocusLabel: String? {
            guard let core else { return nil }
            return CoreBridge.call("CoreSession.remoteFocusLabel", fallback: nil) { try core.remoteFocusLabel() }
        }
    }

    // MARK: Status

    /// The status precedence (HK-121); `.noController` when the core fails.
    static func derivedStatus(controllerConnected: Bool, isPTTActive: Bool, isSpeaking: Bool,
                              isWorking: Bool) -> AppStatus {
        call("derivedStatus", fallback: .noController) {
            AppStatus(try PowerUpCore.derivedStatus(controllerConnected: controllerConnected,
                                                    isPttActive: isPTTActive, isSpeaking: isSpeaking,
                                                    isWorking: isWorking))
        }
    }

    /// The working input of the status (HK-120); false when the core fails.
    static func derivedIsWorking(harnessState: HarnessState, isRemoteMode: Bool, remoteTurnActive: Bool) -> Bool {
        call("derivedIsWorking", fallback: false) {
            try PowerUpCore.derivedIsWorking(harnessState: harnessState.core, isRemoteMode: isRemoteMode,
                                             remoteTurnActive: remoteTurnActive)
        }
    }

    /// The turn table without its expired entries (HK-109); the table as
    /// it was when the core fails.
    static func liveRemoteTurns(_ turns: [String: Date], now: Date, expiry: TimeInterval) -> [String: Date] {
        call("liveRemoteTurns", fallback: turns) {
            try PowerUpCore.liveRemoteTurns(turns: turns.mapValues(\.timeIntervalSinceReferenceDate),
                                            now: now.timeIntervalSinceReferenceDate, expiry: expiry)
                .mapValues(Date.init(timeIntervalSinceReferenceDate:))
        }
    }

    /// Whether a remote turn lights the bar; false when the core fails.
    static func remoteTurnIsActive(_ turns: [String: Date], focus: String?) -> Bool {
        call("remoteTurnIsActive", fallback: false) {
            try PowerUpCore.remoteTurnIsActive(turns: turns.mapValues(\.timeIntervalSinceReferenceDate), focus: focus)
        }
    }

    /// How long a remote turn lives without a sign of life; 15 minutes
    /// when the core fails.
    static var remoteTurnExpiry: TimeInterval {
        call("remoteTurnExpirySeconds", fallback: 15 * 60) { try PowerUpCore.remoteTurnExpirySeconds() }
    }

    /// The model chip (HK-088); when the core fails, the configured alias
    /// unless it is empty or "default".
    static func modelChipLabel(configured: String, reported: String?) -> String {
        let fallback = configured.isEmpty ? "default" : configured
        return call("modelChipLabel", fallback: fallback) {
            try PowerUpCore.modelChipLabel(configured: configured, reported: reported)
        }
    }

    /// Whether a permission request takes a second Approve (HK-093..097).
    /// True when the core fails: the safe side costs one extra press.
    static func isDestructive(kind: String, title: String, detail: String) -> Bool {
        call("isDestructive", fallback: true) {
            try PowerUpCore.isDestructive(kind: kind, title: title, detail: detail)
        }
    }

    /// The substrings that make a request destructive, in the core's
    /// order; empty when the core fails.
    static func destructivePatterns() -> [String] {
        call("destructivePatterns", fallback: []) { try PowerUpCore.destructivePatterns() }
    }

    // MARK: Cycles

    /// The effort cycle (HK-009); empty when the core fails.
    static func effortCycle() -> [String] {
        call("effortCycle", fallback: []) { try PowerUpCore.effortCycle() }
    }

    /// The permission-mode cycle (HK-008); empty when the core fails.
    static func permissionModeCycle() -> [String] {
        call("permissionModeCycle", fallback: []) { try PowerUpCore.permissionModeCycle() }
    }

    /// The model cycle when the user's own is empty; empty when the core
    /// fails.
    static func defaultModelCycle() -> [String] {
        call("defaultModelCycle", fallback: []) { try PowerUpCore.defaultModelCycle() }
    }

    /// The name an effort value is shown by; the value itself when the core
    /// fails.
    static func effortDisplayName(_ effort: String) -> String {
        call("effortDisplayName", fallback: effort) { try PowerUpCore.effortDisplayName(effort: effort) }
    }

    /// The name an ACP agent setting is shown by; the setting itself when
    /// the core fails.
    static func acpAgentDisplayName(_ agent: String) -> String {
        call("acpAgentDisplayName", fallback: agent) { try PowerUpCore.acpAgentDisplayName(agent: agent) }
    }

    /// Whether a stored control mode is remote mode (HK-156); false (the
    /// built-in session) when the core fails.
    static func isRemoteMode(controlMode: String) -> Bool {
        call("isRemoteMode", fallback: false) { try PowerUpCore.isRemoteMode(controlMode: controlMode) }
    }

    /// The harness a stored kind selects (HK-156); the built-in Claude
    /// harness when the core fails.
    static func harnessKind(fromSetting raw: String) -> HarnessKind {
        call("harnessKindFromSetting", fallback: .claude) {
            HarnessKind(try PowerUpCore.harnessKindFromSetting(raw: raw))
        }
    }
}

// MARK: - Conversions

extension CoreBridge.HarnessKind {
    fileprivate init(_ core: CoreHarnessKind) {
        switch core {
        case .claude: self = .claude
        case .acp: self = .acp
        }
    }

    fileprivate var core: CoreHarnessKind {
        switch self {
        case .claude: return .claude
        case .acp: return .acp
        }
    }
}

extension CoreBridge.PlacedPath {
    fileprivate var core: CorePlacedPath {
        CorePlacedPath(components: components, standardized: standardized, name: name)
    }
}

extension CoreBridge.HarnessSnapshot {
    fileprivate var core: CoreHarnessSnapshot {
        CoreHarnessSnapshot(state: state.core, sessionId: sessionID, modelName: modelName,
                            supportsEffort: supportsEffort)
    }
}

extension CoreSessionSettings {
    /// The config fields the session rules read.
    fileprivate init(_ config: AppConfig) {
        self.init(harnessKind: config.harnessKind, acpAgent: config.acpAgent,
                  acpCustomCommand: config.acpCustomCommand, controlMode: config.controlMode,
                  model: config.model, modelCycle: config.modelCycle, effort: config.effort,
                  permissionMode: config.permissionMode, projectDir: config.projectDir,
                  lastSessionId: config.lastSessionID, sessionIdsByProject: config.sessionIDsByProject,
                  recentProjectDirs: config.recentProjectDirs, claudePath: config.claudePath,
                  remoteAutoSubmit: config.remoteAutoSubmit)
    }
}

extension CoreBridge.SessionContext {
    fileprivate var core: CoreSessionContext {
        CoreSessionContext(settings: CoreSessionSettings(config), claude: claude.core, acp: acp?.core,
                           acpAgentCommand: acpAgentCommand, now: now.timeIntervalSinceReferenceDate)
    }
}

extension RemoteHookEvent.Kind {
    fileprivate var core: CoreHookKind {
        switch self {
        case .userPromptSubmit: return .userPromptSubmit
        case .postToolUse: return .postToolUse
        case .notification: return .notification
        case .stop: return .stop
        case .sessionEnd: return .sessionEnd
        }
    }
}

extension AppState.PendingPermission {
    fileprivate init(_ core: CorePendingPermission) {
        self.init(id: core.id, name: core.name, detail: core.detail, isDestructive: core.isDestructive,
                  armed: core.armed)
    }
}

extension CoreBridge.ConfigChange {
    fileprivate init(_ core: CoreConfigChange) {
        switch core {
        case .model(let value): self = .model(value)
        case .effort(let value): self = .effort(value)
        case .permissionMode(let value): self = .permissionMode(value)
        case .controlMode(let value): self = .controlMode(value)
        case .projectDir(let path): self = .projectDir(path)
        case .lastSessionId(let sessionID): self = .lastSessionID(sessionID)
        case .projectSessionId(let projectDir, let sessionID):
            self = .projectSessionID(projectDir: projectDir, sessionID: sessionID)
        case .recentProjectDirs(let paths): self = .recentProjectDirs(paths)
        }
    }
}

extension TranscriptEntry.Kind {
    /// Shared with CoreBridgeTranscript.swift, whose loaded entries carry
    /// the same kind.
    init(_ core: CoreTranscriptKind) {
        switch core {
        case .user: self = .user
        case .assistant: self = .assistant
        case .tool: self = .tool
        case .system: self = .system
        case .error: self = .error
        }
    }
}

extension RemoteControlService.RemoteKey {
    fileprivate init(_ core: CoreRemoteKey) {
        switch core {
        case .enter: self = .enter
        case .escape: self = .escape
        case .shiftTab: self = .shiftTab
        }
    }
}

extension CoreBridge.SessionEffect {
    fileprivate init(_ core: CoreSessionEffect) {
        typealias Kind = CoreBridge.HarnessKind
        switch core {
        case .startHarness(let harness, let configuration):
            self = .startHarness(Kind(harness), HarnessConfiguration(configuration))
        case .sendToHarness(let harness, let text): self = .sendToHarness(Kind(harness), text: text)
        case .interruptHarness(let harness): self = .interruptHarness(Kind(harness))
        case .setHarnessModel(let harness, let model): self = .setHarnessModel(Kind(harness), model: model)
        case .setHarnessPermissionMode(let harness, let mode):
            self = .setHarnessPermissionMode(Kind(harness), mode: mode)
        case .answerPermission(let harness, let id, let allow):
            self = .answerPermission(Kind(harness), id: id, allow: allow)
        case .stopHarness(let harness): self = .stopHarness(Kind(harness))
        case .changeConfig(let change): self = .changeConfig(CoreBridge.ConfigChange(change))
        case .appendTranscript(let kind, let text): self = .appendTranscript(TranscriptEntry.Kind(kind), text)
        case .showProjectTranscript(let projectDir, let restoreHistory):
            self = .showProjectTranscript(projectDir: projectDir, restoreHistory: restoreHistory)
        case .appendLiveReply(let text): self = .appendLiveReply(text)
        case .clearLiveReply: self = .clearLiveReply
        case .setLastReply(let text): self = .setLastReply(text)
        case .pendingPermissionChanged(let permission):
            self = .pendingPermissionChanged(permission.map(AppState.PendingPermission.init))
        case .remoteTurnActiveChanged(let active): self = .remoteTurnActiveChanged(active)
        case .remoteFocusChanged(let sessionID): self = .remoteFocusChanged(sessionID)
        case .haptic(let intensity, let duration): self = .haptic(intensity: intensity, duration: duration)
        case .errorHaptic: self = .errorHaptic
        case .announce(let phrase): self = .announce(phrase)
        case .speakReply(let text): self = .speakReply(text)
        case .cancelSummary: self = .cancelSummary
        case .stopSpeaking: self = .stopSpeaking
        case .injectText(let text, let submit): self = .injectText(text, submit: submit)
        case .injectKey(let key): self = .injectKey(RemoteControlService.RemoteKey(key))
        case .refreshRemoteStatus: self = .refreshRemoteStatus
        case .scheduleRemoteTurnCheck(let afterSeconds): self = .scheduleRemoteTurnCheck(after: afterSeconds)
        case .deferEffortRestart: self = .deferEffortRestart
        case .updateStatus: self = .updateStatus
        }
    }
}

extension AppStatus {
    fileprivate init(_ core: CoreAppStatus) {
        switch core {
        case .noController: self = .noController
        case .idle: self = .idle
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        }
    }
}

extension VoiceCaptureMode {
    fileprivate var core: CoreVoiceCaptureMode {
        switch self {
        case .send: return .send
        case .draft: return .draft
        }
    }
}

extension Intent {
    fileprivate var core: CoreIntent {
        switch self {
        case .beginVoiceCapture(let mode): return .beginVoiceCapture(mode: mode.core)
        case .endVoiceCapture: return .endVoiceCapture
        case .sendPrompt(let prompt): return .sendPrompt(prompt: prompt)
        case .sendDraft: return .sendDraft
        case .approve: return .approve
        case .reject: return .reject
        case .interrupt: return .interrupt
        case .stopSpeaking: return .stopSpeaking
        case .replayLastReply: return .replayLastReply
        case .toggleTTS: return .toggleTts
        case .newSession: return .newSession
        case .showWindow: return .showWindow
        case .cycleModel: return .cycleModel
        case .cycleEffort: return .cycleEffort
        case .cyclePermissionMode: return .cyclePermissionMode
        case .cycleProject: return .cycleProject
        case .cycleFocus: return .cycleFocus
        case .toggleControlMode: return .toggleControlMode
        }
    }
}
