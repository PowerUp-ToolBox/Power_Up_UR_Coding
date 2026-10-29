import Foundation
import PowerUpCore

// MARK: - The ACP harness (slice 2.4)
//
// The ACP adapter's JSON-RPC rules, the permission choice, the agent presets
// and the environment scrub list run in the Rust core (DESIGN v2.13). The
// process, the pipes, the timers, the install paths and PATH stay with
// ACPAdapter. As in CoreBridge.swift, generated names are written
// `PowerUpCore.…` wherever a wrapper shares them. No wrapper here is named
// `ACPAdapter`: inside `extension CoreBridge` it would shadow the app's class.

extension CoreBridge {

    /// The ACP adapter's published state.
    struct ACPSnapshot: Equatable {
        var state: HarnessState
        var sessionID: String?
        var modelName: String?
        var totalTokens: Int

        static let stopped = ACPSnapshot(state: .stopped, sessionID: nil, modelName: nil, totalTokens: 0)
    }

    /// What the ACP adapter asks ACPAdapter to do. Run them in order, each
    /// before the next, and before the next adapter call.
    enum ACPEffect: Equatable {
        /// Assign the published state.
        case publish(ACPSnapshot)
        /// Spawn the agent, then call `spawned(generation:)` or
        /// `spawnFailed(generation:executable:description:)` before anything
        /// else.
        case spawn(generation: UInt64, executable: String, arguments: [String], projectDir: String)
        /// Write one line, newline included, on the current agent's stdin.
        case writeStdin(Data)
        case closeStdin
        /// Terminate the process that is current now if it still runs after
        /// the grace (HK-154).
        case terminateAfterGrace(seconds: TimeInterval)
        /// One-shot: after `seconds`, call `startWatchdogFired(generation:)`
        /// (HK-134).
        case armStartWatchdog(generation: UInt64, seconds: TimeInterval)
        /// Hand the event to the session.
        case emit(HarnessEvent)
    }

    /// The ACP adapter's rules (DESIGN v2.13). One per ACPAdapter, alive
    /// across launches; the launch generation and the JSON-RPC ids live
    /// inside. Call it from the main actor only: its effects must run in the
    /// order the calls were made. A core failure is logged and gives no
    /// effects; a failed constructor makes every call give none and the
    /// snapshot read stopped (HK-409).
    final class ACPStateMachine {
        private let core: CoreAcpAdapter?

        init() {
            core = CoreBridge.call("CoreAcpAdapter.init", fallback: nil) { try CoreAcpAdapter() }
        }

        /// The current launch's generation; 0 when the core fails.
        var generation: UInt64 {
            guard let core else { return 0 }
            return CoreBridge.call("CoreAcpAdapter.generation", fallback: 0) { try core.generation() }
        }

        /// The published state as it is now; stopped when the core fails.
        var snapshot: ACPSnapshot {
            guard let core else { return .stopped }
            return CoreBridge.call("CoreAcpAdapter.snapshot", fallback: .stopped) {
                ACPSnapshot(try core.snapshot())
            }
        }

        private func run(_ name: String, _ body: (CoreAcpAdapter) throws -> [CoreAcpEffect]) -> [ACPEffect] {
            guard let core else { return [] }
            return CoreBridge.call("CoreAcpAdapter.\(name)", fallback: []) {
                try body(core).map(ACPEffect.init)
            }
        }

        func start(_ configuration: HarnessConfiguration) -> [ACPEffect] {
            run("start") { try $0.start(configuration: configuration.core) }
        }

        func spawned(generation: UInt64) -> [ACPEffect] {
            run("spawned") { try $0.spawned(generation: generation) }
        }

        func spawnFailed(generation: UInt64, executable: String, description: String) -> [ACPEffect] {
            run("spawnFailed") {
                try $0.spawnFailed(generation: generation, executable: executable, description: description)
            }
        }

        func send(_ text: String) -> [ACPEffect] {
            run("send") { try $0.send(text: text) }
        }

        func interrupt() -> [ACPEffect] {
            run("interrupt") { try $0.interrupt() }
        }

        func setModel(_ model: String) -> [ACPEffect] {
            run("setModel") { try $0.setModel(model: model) }
        }

        func setPermissionMode(_ mode: String) -> [ACPEffect] {
            run("setPermissionMode") { try $0.setPermissionMode(mode: mode) }
        }

        func respondToPermission(id: String, allow: Bool) -> [ACPEffect] {
            run("respondToPermission") { try $0.respondToPermission(id: id, allow: allow) }
        }

        func stop() -> [ACPEffect] {
            run("stop") { try $0.stop() }
        }

        /// One raw stdout line of `generation`, without its newline, fed one
        /// at a time; a retired generation's lines, and any line after a
        /// stop, are dropped.
        func stdoutLine(generation: UInt64, line: Data) -> [ACPEffect] {
            run("stdoutLine") { try $0.stdoutLine(generation: generation, line: line) }
        }

        func terminated(generation: UInt64, exitCode: Int32, stderrTail: String) -> [ACPEffect] {
            run("terminated") {
                try $0.terminated(generation: generation, exitCode: exitCode, stderrTail: stderrTail)
            }
        }

        func startWatchdogFired(generation: UInt64) -> [ACPEffect] {
            run("startWatchdogFired") { try $0.startWatchdogFired(generation: generation) }
        }
    }

    /// The option id answering a permission request (HK-131); nil when no
    /// option matches, or when the core fails, so the request is answered
    /// cancelled and never granted by accident.
    static func acpPermissionChoice(options: [(id: String, kind: String)], allow: Bool) -> String? {
        call("acpPermissionChoice", fallback: nil) {
            try PowerUpCore.acpPermissionChoice(
                options: options.map { CoreAcpPermissionOption(optionId: $0.id, kind: $0.kind) },
                allow: allow)
        }
    }

    /// The program an ACP agent runs: opencode and npx are looked up on the
    /// app's install paths; a custom executable is used as typed.
    enum ACPAgentProgram: Equatable {
        case opencode
        case npx
        case command(String)
    }

    /// An agent's program and the arguments that follow it.
    struct ACPAgentLaunch: Equatable {
        let program: ACPAgentProgram
        let arguments: [String]
    }

    /// How the stored agent is launched (HK-129, HK-130); nil for an
    /// unknown agent or an empty custom command, and when the core fails,
    /// so the start reports that no command is configured.
    static func acpAgentLaunch(agent: String, customCommand: String) -> ACPAgentLaunch? {
        call("acpAgentLaunch", fallback: nil) {
            try PowerUpCore.acpAgentLaunch(agent: agent, customCommand: customCommand).map(ACPAgentLaunch.init)
        }
    }

    /// The variables removed from a spawned agent's environment (HK-127).
    struct ACPEnvironmentScrub: Equatable {
        let names: [String]
        let prefixes: [String]

        /// Whether `key` leaves the environment: an exact name, or a prefix
        /// as `hasPrefix` matches it (whole clusters, as the core does).
        func scrubs(_ key: String) -> Bool {
            names.contains(key) || prefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The scrub list. When the core fails it is empty (logged): nothing is
    /// scrubbed, and the Claude bridge then refuses with its own visible
    /// nested-session error rather than PowerUp failing silently.
    static var acpEnvironmentScrub: ACPEnvironmentScrub {
        call("acpEnvironmentScrub", fallback: ACPEnvironmentScrub(names: [], prefixes: [])) {
            let scrub = try PowerUpCore.acpEnvironmentScrub()
            return ACPEnvironmentScrub(names: scrub.names, prefixes: scrub.prefixes)
        }
    }
}

// MARK: - Conversions
//
// Exhaustive switches with no `default:`, as in CoreBridge.swift.

extension CoreBridge.ACPSnapshot {
    fileprivate init(_ core: CoreAcpSnapshot) {
        self.init(state: ClaudeState(core.state), sessionID: core.sessionId, modelName: core.modelName,
                  totalTokens: Int(clamping: core.totalTokens))
    }
}

extension CoreBridge.ACPEffect {
    fileprivate init(_ core: CoreAcpEffect) {
        switch core {
        case .publish(let snapshot): self = .publish(CoreBridge.ACPSnapshot(snapshot))
        case .spawn(let generation, let executable, let arguments, let projectDir):
            self = .spawn(generation: generation, executable: executable, arguments: arguments, projectDir: projectDir)
        case .writeStdin(let line): self = .writeStdin(line)
        case .closeStdin: self = .closeStdin
        case .terminateAfterGrace(let seconds): self = .terminateAfterGrace(seconds: seconds)
        case .armStartWatchdog(let generation, let seconds):
            self = .armStartWatchdog(generation: generation, seconds: seconds)
        case .emit(let event): self = .emit(HarnessEvent(event))
        }
    }
}

extension CoreBridge.ACPAgentLaunch {
    fileprivate init(_ core: CoreAcpAgentLaunch) {
        let program: CoreBridge.ACPAgentProgram
        switch core.program {
        case .opencode: program = .opencode
        case .npx: program = .npx
        case .command(let executable): program = .command(executable)
        }
        self.init(program: program, arguments: core.arguments)
    }
}
