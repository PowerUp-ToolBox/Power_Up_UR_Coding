import Foundation

/// Drives any Agent Client Protocol agent (JSON-RPC 2.0, newline-delimited,
/// over stdio): opencode natively, Claude Code and Codex through their npx
/// bridges, or a custom command.
///
/// The protocol's rules run in the Rust core (`harness::acp`, DESIGN v2.13):
/// the handshake, the JSON-RPC ids, the dispatch of every agent line, the
/// permission answers, the prompt queue, the agent presets and the
/// environment scrub list. The wire shapes verified live (2026-08-27,
/// opencode 1.1.44 and claude-agent-acp 0.16.2, DESIGN.md v2.0) and the
/// bridge package names are kept in the core's doc comments. This class is
/// the macOS half: it owns the process and its pipes, the stdin queue, the
/// timers, the stderr tail, the install paths and PATH, and carries out the
/// core's effects in order.
@MainActor
final class ACPAdapter: ObservableObject, HarnessAdapter {

    // MARK: - HarnessAdapter surface

    @Published private(set) var state: HarnessState = .stopped
    @Published private(set) var sessionID: String?
    @Published private(set) var modelName: String?
    private(set) var totalCostUSD: Double = 0        // ACP reports tokens, not dollars
    /// Accumulated from per-turn `usage` in prompt results (the Claude bridge
    /// reports it; opencode currently doesn't).
    private(set) var totalTokens: Int = 0

    var onHarnessEvent: ((HarnessEvent) -> Void)?

    // MARK: - Private state

    /// The ACP rules. One per adapter, alive across launches: the launch
    /// generation and the JSON-RPC ids live inside.
    private let core = CoreBridge.ACPStateMachine()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lines: LineQueue?

    private let stdinQueue = DispatchQueue(label: "com.powerup.acp.stdin")

    // MARK: - Command resolution (pure-ish, tested)

    /// Where opencode is looked for, in order.
    nonisolated static var opencodeCandidates: [String] {
        [NSHomeDirectory() + "/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
    }

    /// Where npx is looked for, in order (the Claude and Codex bridges).
    nonisolated static let npxCandidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]

    /// The agent command for the config's ACP settings, or nil when it can't
    /// be resolved (missing binary, empty custom command). The core says how
    /// each agent is launched (HK-129, HK-130); the install paths are this
    /// platform's (HK-286). `isExecutable` answers whether an install path
    /// holds the binary; tests pass their own so the table does not depend
    /// on what this machine has installed.
    nonisolated static func agentCommand(
        for config: AppConfig,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String]? {
        guard let launch = CoreBridge.acpAgentLaunch(agent: config.acpAgent,
                                                     customCommand: config.acpCustomCommand) else {
            return nil
        }
        let executable: String
        switch launch.program {
        case .opencode:
            guard let binary = opencodeCandidates.first(where: isExecutable) else { return nil }
            executable = binary
        case .npx:
            guard let npx = npxCandidates.first(where: isExecutable) else { return nil }
            executable = npx
        case .command(let typed):
            executable = typed
        }
        return [executable] + launch.arguments
    }

    /// The environment for a spawned agent. Strips the Claude-nesting markers
    /// the core lists (`CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_*`, HK-127) —
    /// verified live: the Claude bridge refuses to run inside a Claude
    /// session otherwise — and makes sure the usual install locations are on
    /// PATH (HK-128).
    nonisolated static func agentEnvironment(from base: [String: String]) -> [String: String] {
        let scrub = CoreBridge.acpEnvironmentScrub
        var env = base.filter { key, _ in !scrub.scrubs(key) }
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var components = existing.split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"] {
            if !components.contains(extra) { components.append(extra) }
        }
        env["PATH"] = components.joined(separator: ":")
        return env
    }

    /// Picks the option id answering a permission request. Prefers the
    /// `*_once` variant of the chosen direction so a controller press never
    /// silently grants "always"; nil when no option matches (→ cancelled).
    nonisolated static func permissionChoice(options: [(id: String, kind: String)],
                                             allow: Bool) -> String? {
        CoreBridge.acpPermissionChoice(options: options, allow: allow)
    }

    // MARK: - Lifecycle

    func start(_ configuration: HarnessConfiguration) {
        run(core.start(configuration))
    }

    func send(_ text: String) {
        run(core.send(text))
    }

    func interrupt() {
        run(core.interrupt())
    }

    func setModel(_ model: String) {
        run(core.setModel(model))
    }

    func setPermissionMode(_ mode: String) {
        run(core.setPermissionMode(mode))
    }

    func respondToPermission(id: String, allow: Bool) {
        run(core.respondToPermission(id: id, allow: allow))
    }

    /// Closes stdin, then terminates the agent if it still runs after a 2
    /// second grace.
    func stop() {
        run(core.stop())
    }

    // MARK: - Carrying out the core's effects

    /// Runs the effects in order. A spawn reports back at once, and its
    /// nested effects run before the rest of these, as the core expects.
    private func run(_ effects: [CoreBridge.ACPEffect]) {
        for effect in effects {
            switch effect {
            case .publish(let snapshot):
                publish(snapshot)
            case .spawn(let generation, let executable, let arguments, let projectDir):
                spawn(generation: generation, executable: executable, arguments: arguments,
                      projectDir: URL(fileURLWithPath: projectDir, isDirectory: true))
            case .writeStdin(let line):
                guard let handle = stdinHandle else { break }
                stdinQueue.async {
                    try? handle.write(contentsOf: line)
                }
            case .closeStdin:
                if let handle = stdinHandle {
                    stdinHandle = nil
                    stdinQueue.async { try? handle.close() }
                }
            case .terminateAfterGrace(let seconds):
                // The process current now: a start that follows replaces it.
                guard let proc = process else { break }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    if proc.isRunning { proc.terminate() }
                }
            case .armStartWatchdog(let generation, let seconds):
                // A wedged agent must not leave the app "starting" forever;
                // the core decides whether this launch is still starting.
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self else { return }
                    self.run(self.core.startWatchdogFired(generation: generation))
                }
            case .emit(let event):
                onHarnessEvent?(event)
            }
        }
    }

    /// Assigns only what changed, so an unchanged field does not fire
    /// `objectWillChange` for nothing.
    private func publish(_ snapshot: CoreBridge.ACPSnapshot) {
        if state != snapshot.state { state = snapshot.state }
        if sessionID != snapshot.sessionID { sessionID = snapshot.sessionID }
        if modelName != snapshot.modelName { modelName = snapshot.modelName }
        if totalTokens != snapshot.totalTokens { totalTokens = snapshot.totalTokens }
    }

    /// Spawns the agent with three pipes. The core hears `spawned` or
    /// `spawnFailed` before anything else happens.
    private func spawn(generation: UInt64, executable: String, arguments: [String], projectDir: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = projectDir
        proc.environment = ACPAdapter.agentEnvironment(from: ProcessInfo.processInfo.environment)

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let queue = LineQueue()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        outHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            queue.ingest(chunk)
            guard let adapter = self else { return }
            Task { @MainActor in
                adapter.drainLines(from: queue, generation: generation)
            }
        }
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            queue.ingestStderr(chunk)
        }

        proc.terminationHandler = { [weak self] finished in
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            let code = finished.terminationStatus
            let tail = queue.stderrTail(maxChars: 500)
            guard let adapter = self else { return }
            Task { @MainActor in
                adapter.handleTermination(of: finished, code: code, stderrTail: tail, generation: generation)
            }
        }

        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            run(core.spawnFailed(generation: generation, executable: executable,
                                 description: error.localizedDescription))
            return
        }

        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        lines = queue
        // initialize goes out and the start watchdog is armed.
        run(core.spawned(generation: generation))
    }

    // MARK: - Incoming

    /// Feeds the launch's lines to the core one at a time, so the state each
    /// one leaves is published before the next is handled. The core drops a
    /// retired launch's lines, and every line after a stop: the pipe stays
    /// readable until the kill grace, and a dying agent's late permission
    /// request must not bring back what the user just cleared (HK-135,
    /// HK-408).
    private func drainLines(from queue: LineQueue, generation: UInt64) {
        for line in queue.drain() {
            run(core.stdoutLine(generation: generation, line: line))
        }
    }

    /// The references go before the exit is reported, and only when they
    /// still point at the process that exited: a newer launch's must stay.
    private func handleTermination(of finished: Process, code: Int32, stderrTail: String, generation: UInt64) {
        if process === finished {
            process = nil
            stdinHandle = nil
            lines = nil
        }
        run(core.terminated(generation: generation, exitCode: code, stderrTail: stderrTail))
    }
}

// MARK: - LineQueue

/// Thread-safe buffers between the pipe reader threads and the main actor:
/// newline-split stdout lines (order-preserving) plus a bounded stderr tail
/// (HK-287). Lines are split by the core's line buffer, exactly as the
/// Claude adapter's are (HK-052, HK-053, HK-152): empty lines are dropped,
/// a `\r` is kept, and a tail past 16 MiB is dropped. The tail is never
/// flushed at the end of the stream, as before.
private final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutLines = CoreBridge.LineBuffer()
    private var pending: [Data] = []
    private var stderrBuffer = Data()

    private let maxStderrBytes = 64 * 1024

    func ingest(_ data: Data) {
        let finished = stdoutLines.ingest(data)
        guard !finished.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: finished)
    }

    func drain() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        return lines
    }

    func ingestStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrBuffer.append(data)
        if stderrBuffer.count > maxStderrBytes {
            stderrBuffer = stderrBuffer.suffix(maxStderrBytes)
        }
    }

    func stderrTail(maxChars: Int) -> String {
        lock.lock()
        let data = stderrBuffer
        lock.unlock()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxChars else { return text }
        return "…" + String(text.suffix(maxChars))
    }
}
