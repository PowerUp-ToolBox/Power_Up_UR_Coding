import Foundation
import Combine

/// Drives a persistent `claude` CLI subprocess in streaming-JSON mode.
///
/// The process is spawned with three pipes. stdout is consumed with a
/// `readabilityHandler` (never a blocking read) and split into lines by the
/// Rust core's line buffer; a trailing partial line waits for the next chunk.
/// Each line is parsed by the core (DESIGN v2.12), and the events are queued
/// on a lock-protected FIFO and drained on the main actor, so ordering is
/// preserved even though the parse happens on a background queue.
@MainActor
final class ClaudeService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: ClaudeState = .stopped
    @Published private(set) var sessionID: String?
    @Published private(set) var modelName: String?
    @Published private(set) var totalCostUSD: Double = 0

    /// The normalized stream. Always on the main actor. This is the
    /// `HarnessAdapter` surface `AppState` consumes.
    var onHarnessEvent: ((HarnessEvent) -> Void)?

    // MARK: - Private state

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var channel: IOChannel?

    /// The adapter's rules (DESIGN v2.12): the launch generation, the queue
    /// of lines sent before the spawn, the in-flight control requests and
    /// the assistant de-dupe all live in the core, across launches.
    private let core: CoreBridge.ClaudeAdapter

    private let stdinQueue = DispatchQueue(label: "com.powerup.claude.stdin")

    /// Control request ids are `"<requestIDPrefix>-<n>"` (HK-396); the CLI
    /// takes any unique string, so a UUID per service keeps them unique.
    init(requestIDPrefix: String = UUID().uuidString) {
        core = CoreBridge.ClaudeAdapter(requestIDPrefix: requestIDPrefix)
    }

    // MARK: - Binary resolution

    /// Finds the `claude` executable: explicit override, then a zsh login shell
    /// lookup (picks up nvm/homebrew/PATH tweaks), then the usual install spots.
    nonisolated static func resolveClaudeBinary(override: String?) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            if isRunnableFile(expanded) { return expanded }
        }

        if let fromShell = cachedLoginShellClaudePath, isRunnableFile(fromShell) { return fromShell }

        let home = NSHomeDirectory()
        let candidates = [
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.npm-global/bin/claude"
        ]
        return candidates.first(where: isRunnableFile)
    }

    private nonisolated static func isRunnableFile(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    /// `/bin/zsh -l -c 'command -v claude'`. Returns nil on any failure; a shell
    /// function/alias (which prints a bare name) is rejected. The probe is
    /// bounded: a hung login shell is terminated after a short deadline instead
    /// of wedging the caller.
    fileprivate nonisolated static func loginShellLookup() -> String? {
        let shell = "/bin/zsh"
        guard isRunnableFile(shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Bounded wait — a stuck .zshrc/.zprofile must not hang the app. The
        // pipes buffer far more than `command -v` ever writes, so waiting
        // before reading can't deadlock a well-behaved shell; a pathological
        // one hits the deadline, is killed, and we fall through to the
        // known-install-path candidates.
        guard exited.wait(timeout: .now() + 2.5) == .success else {
            process.terminationHandler = nil
            process.terminate()
            return nil
        }
        process.terminationHandler = nil

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for rawLine in text.split(separator: "\n").reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("/") { return line }
        }
        return nil
    }

    // MARK: - Lifecycle
    //
    // Every call goes to the core's adapter, which answers with effects;
    // `run` carries them out in order. The core decides what a call means
    // (queue it while the binary resolves, refuse it without a process,
    // drop a retired launch's output); this class only owns the process.

    func start(projectDir: URL,
               model: String,
               permissionMode: String,
               effort: String,
               resumeSessionID: String?,
               claudePathOverride: String?) {
        run(core.start(HarnessConfiguration(projectDir: projectDir, model: model, permissionMode: permissionMode,
                                            effort: effort, resumeSessionID: resumeSessionID,
                                            binaryPathOverride: claudePathOverride)))
    }

    /// Sends a user turn: one JSON envelope + newline on stdin.
    func send(_ text: String) {
        run(core.send(text, processRunning: processRunning))
    }

    /// Interrupts the current turn.
    func interrupt() {
        run(core.interrupt(processRunning: processRunning))
    }

    /// Switches the model mid-session (applies live, no restart).
    func setModel(_ model: String) {
        run(core.setModel(model, processRunning: processRunning))
    }

    /// Switches the permission mode mid-session (applies live, no restart).
    func setPermissionMode(_ mode: String) {
        run(core.setPermissionMode(mode, processRunning: processRunning))
    }

    /// Closes stdin (letting claude finish cleanly), then terminates after a
    /// 2 second grace period.
    func stop() {
        run(core.stop())
    }

    /// The core's answer for "is there a live process to write to".
    private var processRunning: Bool { process?.isRunning == true }

    // MARK: - Carrying out the core's effects

    /// Runs the effects in order. An emitted event can re-enter this class
    /// (the session restarts the CLI from inside an `ended`); the nested
    /// call's effects run before the rest of these, as the core expects.
    private func run(_ effects: [CoreBridge.ClaudeAdapterEffect]) {
        for effect in effects {
            switch effect {
            case .publish(let snapshot):
                publish(snapshot)
            case .resolveBinary(let generation, let binaryPathOverride):
                // The lookup can shell out to a zsh *login* shell and wait up
                // to ~2.5s (heavy .zprofile/.zshrc); on the main actor that
                // froze the window at every cold launch. Resolve off the main
                // thread; the core queues anything sent meanwhile.
                Task.detached(priority: .userInitiated) { [weak self] in
                    let path = ClaudeService.resolveClaudeBinary(override: binaryPathOverride)
                    guard let service = self else { return }
                    await service.binaryResolved(generation: generation, path: path)
                }
            case .spawn(let generation, let executable, let arguments, let projectDir):
                spawn(generation: generation, executable: executable, arguments: arguments,
                      projectDir: URL(fileURLWithPath: projectDir, isDirectory: true))
            case .writeStdin(let line):
                if let handle = stdinHandle { write(line, to: handle) }
            case .closeStdin:
                if let handle = stdinHandle {
                    stdinHandle = nil
                    stdinQueue.async {
                        try? handle.close()
                    }
                }
            case .terminateAfterGrace(let seconds):
                // The process current now: a start that follows replaces it.
                guard let proc = process else { break }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    if proc.isRunning { proc.terminate() }
                }
            case .emit(let event):
                onHarnessEvent?(event)
            }
        }
    }

    /// Assigns only what changed, so an unchanged field does not fire
    /// `objectWillChange` for nothing.
    private func publish(_ snapshot: CoreBridge.ClaudeSnapshot) {
        if state != snapshot.state { state = snapshot.state }
        if sessionID != snapshot.sessionID { sessionID = snapshot.sessionID }
        if modelName != snapshot.modelName { modelName = snapshot.modelName }
        if totalCostUSD != snapshot.totalCostUSD { totalCostUSD = snapshot.totalCostUSD }
    }

    private func binaryResolved(generation: UInt64, path: String?) {
        run(core.binaryResolved(generation: generation, path: path))
    }

    /// Spawns the CLI with three pipes. The core hears `spawned` or
    /// `spawnFailed` before anything else happens.
    private func spawn(generation: UInt64, executable: String, arguments: [String], projectDir: URL) {
        ClaudeService.ignoreSIGPIPEOnce()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = projectDir
        proc.environment = ClaudeService.childEnvironment(binaryPath: executable)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let io = IOChannel()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        outHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF — the child closed stdout.
                handle.readabilityHandler = nil
                return
            }
            let events = ClaudeService.events(fromChunk: chunk, channel: io)
            guard !events.isEmpty else { return }
            io.enqueue(events)
            guard let service = self else { return }
            Task { @MainActor in
                service.drainEvents(from: io, generation: generation)
            }
        }

        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            io.ingestStderr(chunk)
        }

        proc.terminationHandler = { [weak self] finished in
            // Break the retain cycle pipe → handler → self → process.
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil

            // Pick up anything still sitting in the pipes now that the child is
            // gone (both reads return empty at EOF, so this always finishes).
            ClaudeService.drainRemaining(handle: outHandle, into: io, isStdout: true)
            ClaudeService.drainRemaining(handle: errHandle, into: io, isStdout: false)

            let exitCode = finished.terminationStatus
            let clean = (exitCode == 0 && finished.terminationReason == .exit)
            let tail = io.stderrTail(maxChars: 500)
            guard let service = self else { return }

            Task { @MainActor in
                // Late stdout events go first; the core drops a retired
                // launch's. The references go before the exit is reported:
                // a resume retry started from the `ended` it emits installs
                // a new process, which must not be cleared afterwards.
                service.drainEvents(from: io, generation: generation)
                if service.process === finished {
                    service.process = nil
                    service.stdinHandle = nil
                    service.channel = nil
                }
                service.run(service.core.terminated(generation: generation, exitCode: exitCode,
                                                    clean: clean, stderrTail: tail))
            }
        }

        do {
            try proc.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            proc.terminationHandler = nil
            run(core.spawnFailed(generation: generation, executable: executable,
                                 description: error.localizedDescription))
            return
        }

        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        channel = io
        // Flushes anything that was sent while the binary was resolving.
        run(core.spawned(generation: generation))
    }

    /// Feeds the launch's parsed events to the core one at a time, so the
    /// state each one leaves is published before the next is handled.
    private func drainEvents(from io: IOChannel, generation: UInt64) {
        for event in io.drain() {
            run(core.stdoutEvent(generation: generation, event: event))
        }
    }

    // MARK: - stdin writing

    private func write(_ data: Data, to handle: FileHandle) {
        stdinQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                let description = error.localizedDescription
                guard let service = self else { return }
                Task { @MainActor in
                    service.run(service.core.stdinWriteFailed(description: description))
                }
            }
        }
    }

    /// SIGPIPE would otherwise kill the app when writing to a dead child.
    private static let sigpipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func ignoreSIGPIPEOnce() {
        _ = sigpipeIgnored
    }

    // MARK: - Environment

    private nonisolated static func childEnvironment(binaryPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = (binaryPath as NSString).deletingLastPathComponent
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var components = existing.split(separator: ":").map(String.init)
        components.removeAll { $0 == binDir }
        if !binDir.isEmpty {
            components.insert(binDir, at: 0)
        }
        // Common install locations, so hooks/tools the CLI shells out to are found.
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"] {
            if !components.contains(extra) { components.append(extra) }
        }
        env["PATH"] = components.joined(separator: ":")
        return env
    }

    // MARK: - Background parsing (nonisolated)

    private nonisolated static func drainRemaining(handle: FileHandle, into io: IOChannel, isStdout: Bool) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if isStdout {
                let events = events(fromChunk: chunk, channel: io)
                if !events.isEmpty { io.enqueue(events) }
            } else {
                io.ingestStderr(chunk)
            }
        }
        if isStdout, let remainder = io.flushStdoutRemainder() {
            let events = events(fromLine: remainder)
            if !events.isEmpty { io.enqueue(events) }
        }
    }

    private nonisolated static func events(fromChunk chunk: Data, channel io: IOChannel) -> [ClaudeEvent] {
        var result: [ClaudeEvent] = []
        for line in io.ingestStdout(chunk) {
            result.append(contentsOf: events(fromLine: line))
        }
        return result
    }

    /// What one stdout line means. The stream-json parser runs in the Rust
    /// core (DESIGN v2.12): anything unrecognised gives no events, and the
    /// wire-protocol quirks verified against the live CLI are pinned by
    /// `Tests/Fixtures/harness/claude-stream.json` in both languages.
    /// Internal so `ClaudeStreamParsingTests` can play lines through it.
    nonisolated static func events(fromLine line: Data) -> [ClaudeEvent] {
        CoreBridge.claudeEvents(fromLine: line)
    }
}

// MARK: - HarnessAdapter conformance

extension ClaudeService: HarnessAdapter {
    var supportsEffort: Bool { true }
    var reportsCostUSD: Bool { true }

    func start(_ configuration: HarnessConfiguration) {
        start(projectDir: configuration.projectDir,
              model: configuration.model,
              permissionMode: configuration.permissionMode,
              effort: configuration.effort,
              resumeSessionID: configuration.resumeSessionID,
              claudePathOverride: configuration.binaryPathOverride)
    }
}

// MARK: - Login-shell lookup cache

/// Login shells are slow to start (a heavy profile can take seconds), so the
/// lookup runs at most once per app run. Swift global `let`s are initialized
/// lazily and thread-safely on first access.
private let cachedLoginShellClaudePath: String? = ClaudeService.loginShellLookup()

// MARK: - IOChannel

/// Thread-safe buffers shared between the pipe reader threads and the main actor.
/// Internal (not private) so the line-splitting behavior is testable.
final class IOChannel: @unchecked Sendable {

    private let lock = NSLock()
    /// The stdout line splitter runs in the Rust core (HK-052, HK-053): a
    /// partial line waits for the next chunk, empty lines are dropped, and
    /// a tail past 16 MiB is dropped. It locks itself.
    private let stdoutLines = CoreBridge.LineBuffer()
    private var stderrBuffer = Data()
    private var pending: [ClaudeEvent] = []

    private let maxStderrBytes = 64 * 1024

    /// Appends a stdout chunk and returns every complete line it produced. A
    /// trailing partial line stays buffered for the next chunk.
    func ingestStdout(_ data: Data) -> [Data] {
        stdoutLines.ingest(data)
    }

    /// Returns any buffered partial line (used once the stream has ended).
    func flushStdoutRemainder() -> Data? {
        stdoutLines.flushRemainder()
    }

    func ingestStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrBuffer.append(data)
        if stderrBuffer.count > maxStderrBytes {
            let excess = stderrBuffer.count - maxStderrBytes
            stderrBuffer = stderrBuffer.subdata(in: (stderrBuffer.startIndex + excess)..<stderrBuffer.endIndex)
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

    func enqueue(_ events: [ClaudeEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: events)
    }

    func drain() -> [ClaudeEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = pending
        pending.removeAll(keepingCapacity: true)
        return events
    }
}
