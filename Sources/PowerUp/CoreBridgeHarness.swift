import Foundation
import PowerUpCore

// MARK: - The Claude harness (slice 2.3)
//
// The claude CLI's stdout lines, its stdin lines, its argv and the Claude
// adapter's process rules run in the Rust core (DESIGN v2.12). The process,
// the pipes, the binary lookup and the kill timer stay with ClaudeService.
// As in CoreBridge.swift, generated names are written `PowerUpCore.…`
// wherever a wrapper shares them.

extension CoreBridge {

    /// What one stdout line (without its newline) means; anything the
    /// parser does not recognize, or a core failure, gives no events.
    /// Pure, so the pipe reader threads call it directly.
    static func claudeEvents(fromLine line: Data) -> [ClaudeEvent] {
        call("claudeEventsFromLine", fallback: []) {
            try PowerUpCore.claudeEventsFromLine(line: line).map(ClaudeEvent.init)
        }
    }

    /// The Claude adapter's event in the normalized vocabulary (HK-090).
    /// It cannot fail in practice; if the core does, the session hears a
    /// runtime error instead of nothing, so a lost event is never silent.
    static func harnessEvent(from event: ClaudeEvent) -> HarnessEvent {
        call("harnessEventFromClaude", fallback: .runtimeError("PowerUp's core could not read an event.")) {
            HarnessEvent(try PowerUpCore.harnessEventFromClaude(event: event.core))
        }
    }

    /// The claude CLI's argv for one launch (HK-077, HK-080); empty when
    /// the core fails.
    static func claudeLaunchArguments(model: String, permissionMode: String, effort: String,
                                      resumeSessionID: String?) -> [String] {
        call("claudeLaunchArguments", fallback: []) {
            try PowerUpCore.claudeLaunchArguments(model: model, permissionMode: permissionMode,
                                                  effort: effort, resumeSessionId: resumeSessionID)
        }
    }

    /// The user-turn line, newline included; nil when the trimmed text is
    /// empty or the core fails, so nothing is sent.
    static func claudeUserTurnLine(_ text: String) -> Data? {
        call("claudeUserTurnLine", fallback: nil) {
            try PowerUpCore.claudeUserTurnLine(text: text)
        }
    }

    /// One control request's line in the nested envelope, newline included;
    /// nil when its value trims to nothing, the subtype is not one the CLI
    /// takes, or the core fails.
    static func claudeControlRequestLine(requestID: String, subtype: String, value: String?) -> Data? {
        call("claudeControlRequestLine", fallback: nil) {
            try PowerUpCore.claudeControlRequestLine(requestId: requestID, subtype: subtype, value: value)
        }
    }

    // MARK: Line buffer

    /// The stdout bytes of one launch that no newline has finished yet
    /// (HK-052, HK-053): a partial line waits for the next chunk, empty
    /// lines are dropped, and a tail past 16 MiB is dropped. Safe from any
    /// thread: the pipe's readability handler and the termination drain
    /// both feed it. One per launch, owned by its IOChannel.
    final class LineBuffer: @unchecked Sendable {
        private let core: CoreLineBuffer?

        init() {
            core = CoreBridge.call("CoreLineBuffer.init", fallback: nil) { try CoreLineBuffer() }
        }

        /// Every line `chunk` finishes, in order; none when the core fails.
        func ingest(_ chunk: Data) -> [Data] {
            guard let core else { return [] }
            return CoreBridge.call("CoreLineBuffer.ingest", fallback: []) { try core.ingest(chunk: chunk) }
        }

        /// The buffered tail once the stream has ended, or nil; empties the
        /// buffer.
        func flushRemainder() -> Data? {
            guard let core else { return nil }
            return CoreBridge.call("CoreLineBuffer.flushRemainder", fallback: nil) { try core.flushRemainder() }
        }
    }

    // MARK: Claude adapter

    /// The Claude adapter's published state.
    struct ClaudeSnapshot: Equatable {
        var state: ClaudeState
        var sessionID: String?
        var modelName: String?
        var totalCostUSD: Double

        static let stopped = ClaudeSnapshot(state: .stopped, sessionID: nil, modelName: nil, totalCostUSD: 0)
    }

    /// What the Claude adapter asks ClaudeService to do. Run them in order,
    /// each before the next, and before the next adapter call.
    enum ClaudeAdapterEffect: Equatable {
        /// Assign the published state.
        case publish(ClaudeSnapshot)
        /// Resolve the binary off the main thread, then call
        /// `binaryResolved(generation:path:)`.
        case resolveBinary(generation: UInt64, binaryPathOverride: String?)
        /// Spawn the process, then call `spawned(generation:)` or
        /// `spawnFailed(generation:executable:description:)` before anything
        /// else.
        case spawn(generation: UInt64, executable: String, arguments: [String], projectDir: String)
        /// Write one line, newline included, on the current process's stdin.
        case writeStdin(Data)
        case closeStdin
        /// Terminate the process that is current now if it still runs after
        /// the grace (HK-078).
        case terminateAfterGrace(seconds: TimeInterval)
        /// Hand the event to the session.
        case emit(HarnessEvent)
    }

    /// The Claude adapter's process rules (DESIGN v2.12). One per
    /// ClaudeService, alive across launches; the launch generation lives
    /// inside. Call it from the main actor only: its effects must run in
    /// the order the calls were made. A core failure is logged and gives no
    /// effects.
    final class ClaudeAdapter {
        private let core: CoreClaudeAdapter?

        /// Request ids are `"<requestIDPrefix>-<n>"` (HK-396).
        init(requestIDPrefix: String) {
            core = CoreBridge.call("CoreClaudeAdapter.init", fallback: nil) {
                try CoreClaudeAdapter(requestIdPrefix: requestIDPrefix)
            }
        }

        /// The current launch's generation; 0 when the core fails.
        var generation: UInt64 {
            guard let core else { return 0 }
            return CoreBridge.call("CoreClaudeAdapter.generation", fallback: 0) { try core.generation() }
        }

        /// The published state as it is now; stopped when the core fails.
        var snapshot: ClaudeSnapshot {
            guard let core else { return .stopped }
            return CoreBridge.call("CoreClaudeAdapter.snapshot", fallback: .stopped) {
                ClaudeSnapshot(try core.snapshot())
            }
        }

        private func run(_ name: String,
                         _ body: (CoreClaudeAdapter) throws -> [CoreClaudeEffect]) -> [ClaudeAdapterEffect] {
            guard let core else { return [] }
            return CoreBridge.call("CoreClaudeAdapter.\(name)", fallback: []) {
                try body(core).map(ClaudeAdapterEffect.init)
            }
        }

        func start(_ configuration: HarnessConfiguration) -> [ClaudeAdapterEffect] {
            run("start") { try $0.start(configuration: configuration.core) }
        }

        func binaryResolved(generation: UInt64, path: String?) -> [ClaudeAdapterEffect] {
            run("binaryResolved") { try $0.binaryResolved(generation: generation, path: path) }
        }

        func spawned(generation: UInt64) -> [ClaudeAdapterEffect] {
            run("spawned") { try $0.spawned(generation: generation) }
        }

        func spawnFailed(generation: UInt64, executable: String, description: String) -> [ClaudeAdapterEffect] {
            run("spawnFailed") {
                try $0.spawnFailed(generation: generation, executable: executable, description: description)
            }
        }

        /// `processRunning`: the current process's `isRunning`.
        func send(_ text: String, processRunning: Bool) -> [ClaudeAdapterEffect] {
            run("send") { try $0.send(text: text, processRunning: processRunning) }
        }

        func interrupt(processRunning: Bool) -> [ClaudeAdapterEffect] {
            run("interrupt") { try $0.interrupt(processRunning: processRunning) }
        }

        func setModel(_ model: String, processRunning: Bool) -> [ClaudeAdapterEffect] {
            run("setModel") { try $0.setModel(model: model, processRunning: processRunning) }
        }

        func setPermissionMode(_ mode: String, processRunning: Bool) -> [ClaudeAdapterEffect] {
            run("setPermissionMode") { try $0.setPermissionMode(mode: mode, processRunning: processRunning) }
        }

        func stop() -> [ClaudeAdapterEffect] {
            run("stop") { try $0.stop() }
        }

        /// One parsed stdout event of `generation`, fed one at a time; a
        /// retired generation's events are dropped.
        func stdoutEvent(generation: UInt64, event: ClaudeEvent) -> [ClaudeAdapterEffect] {
            run("stdoutEvent") { try $0.stdoutEvent(generation: generation, event: event.core) }
        }

        /// The process of `generation` exited; feed its last stdout events
        /// first.
        func terminated(generation: UInt64, exitCode: Int32, clean: Bool,
                        stderrTail: String) -> [ClaudeAdapterEffect] {
            run("terminated") {
                try $0.terminated(generation: generation, exitCode: exitCode, clean: clean, stderrTail: stderrTail)
            }
        }

        func stdinWriteFailed(description: String) -> [ClaudeAdapterEffect] {
            run("stdinWriteFailed") { try $0.stdinWriteFailed(description: description) }
        }
    }
}

// MARK: - Conversions
//
// Exhaustive switches with no `default:`, as in CoreBridge.swift.

extension ClaudeEvent {
    fileprivate init(_ core: CoreClaudeEvent) {
        switch core {
        case .ready(let sessionID, let model): self = .ready(sessionID: sessionID, model: model)
        case .textDelta(let text): self = .textDelta(text)
        case .assistantMessage(let text): self = .assistantMessage(text)
        case .toolUse(let name, let detail): self = .toolUse(name: name, detail: detail)
        case .turnCompleted(let resultText, let costUSD, let isError, let subtype):
            self = .turnCompleted(resultText: resultText, costUSD: costUSD, isError: isError, subtype: subtype)
        case .controlResult(let action, let ok, let detail, let value):
            self = .controlResult(action: action, ok: ok, detail: detail, value: value)
        case .processError(let message): self = .processError(message)
        case .terminated(let exitCode): self = .terminated(exitCode: exitCode)
        }
    }

    fileprivate var core: CoreClaudeEvent {
        switch self {
        case .ready(let sessionID, let model): return .ready(sessionId: sessionID, model: model)
        case .textDelta(let text): return .textDelta(text: text)
        case .assistantMessage(let text): return .assistantMessage(text: text)
        case .toolUse(let name, let detail): return .toolUse(name: name, detail: detail)
        case .turnCompleted(let resultText, let costUSD, let isError, let subtype):
            return .turnCompleted(resultText: resultText, costUsd: costUSD, isError: isError, subtype: subtype)
        case .controlResult(let action, let ok, let detail, let value):
            return .controlResult(action: action, ok: ok, detail: detail, value: value)
        case .processError(let message): return .processError(message: message)
        case .terminated(let exitCode): return .terminated(exitCode: exitCode)
        }
    }
}

extension HarnessEvent {
    init(_ core: CoreHarnessEvent) {
        switch core {
        case .sessionReady(let sessionID, let model): self = .sessionReady(sessionID: sessionID, model: model)
        case .replyDelta(let text): self = .replyDelta(text)
        case .reply(let text): self = .reply(text)
        case .toolUse(let name, let detail): self = .toolUse(name: name, detail: detail)
        case .turnCompleted(let resultText, let costUSD, let isError, let detail):
            self = .turnCompleted(resultText: resultText, costUSD: costUSD, isError: isError, detail: detail)
        case .controlResult(let action, let ok, let detail, let value):
            self = .controlResult(action: action, ok: ok, detail: detail, value: value)
        case .permissionRequest(let id, let name, let kind, let detail):
            self = .permissionRequest(id: id, name: name, kind: kind, detail: detail)
        case .notification(let message): self = .notification(message)
        case .runtimeError(let message): self = .runtimeError(message)
        case .ended(let exitCode): self = .ended(exitCode: exitCode)
        }
    }

    var core: CoreHarnessEvent {
        switch self {
        case .sessionReady(let sessionID, let model): return .sessionReady(sessionId: sessionID, model: model)
        case .replyDelta(let text): return .replyDelta(text: text)
        case .reply(let text): return .reply(text: text)
        case .toolUse(let name, let detail): return .toolUse(name: name, detail: detail)
        case .turnCompleted(let resultText, let costUSD, let isError, let detail):
            return .turnCompleted(resultText: resultText, costUsd: costUSD, isError: isError, detail: detail)
        case .controlResult(let action, let ok, let detail, let value):
            return .controlResult(action: action, ok: ok, detail: detail, value: value)
        case .permissionRequest(let id, let name, let kind, let detail):
            return .permissionRequest(id: id, name: name, kind: kind, detail: detail)
        case .notification(let message): return .notification(message: message)
        case .runtimeError(let message): return .runtimeError(message: message)
        case .ended(let exitCode): return .ended(exitCode: exitCode)
        }
    }
}

extension ClaudeState {
    init(_ core: CoreHarnessState) {
        switch core {
        case .stopped: self = .stopped
        case .starting: self = .starting
        case .ready: self = .ready
        case .working: self = .working
        }
    }

    var core: CoreHarnessState {
        switch self {
        case .stopped: return .stopped
        case .starting: return .starting
        case .ready: return .ready
        case .working: return .working
        }
    }
}

extension HarnessConfiguration {
    /// From the core: the project folder is a directory URL of the path.
    init(_ core: CoreHarnessConfiguration) {
        self.init(projectDir: URL(fileURLWithPath: core.projectDir, isDirectory: true),
                  model: core.model, permissionMode: core.permissionMode, effort: core.effort,
                  resumeSessionID: core.resumeSessionId, binaryPathOverride: core.binaryPathOverride,
                  agentCommand: core.agentCommand)
    }

    var core: CoreHarnessConfiguration {
        CoreHarnessConfiguration(projectDir: projectDir.path, model: model, permissionMode: permissionMode,
                                 effort: effort, resumeSessionId: resumeSessionID,
                                 binaryPathOverride: binaryPathOverride, agentCommand: agentCommand)
    }
}

extension CoreBridge.ClaudeSnapshot {
    fileprivate init(_ core: CoreClaudeSnapshot) {
        self.init(state: ClaudeState(core.state), sessionID: core.sessionId, modelName: core.modelName,
                  totalCostUSD: core.totalCostUsd)
    }
}

extension CoreBridge.ClaudeAdapterEffect {
    fileprivate init(_ core: CoreClaudeEffect) {
        switch core {
        case .publish(let snapshot): self = .publish(CoreBridge.ClaudeSnapshot(snapshot))
        case .resolveBinary(let generation, let binaryPathOverride):
            self = .resolveBinary(generation: generation, binaryPathOverride: binaryPathOverride)
        case .spawn(let generation, let executable, let arguments, let projectDir):
            self = .spawn(generation: generation, executable: executable, arguments: arguments, projectDir: projectDir)
        case .writeStdin(let line): self = .writeStdin(line)
        case .closeStdin: self = .closeStdin
        case .terminateAfterGrace(let seconds): self = .terminateAfterGrace(seconds: seconds)
        case .emit(let event): self = .emit(HarnessEvent(event))
        }
    }
}
