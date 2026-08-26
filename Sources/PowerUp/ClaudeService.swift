import Foundation
import Combine

/// Drives a persistent `claude` CLI subprocess in streaming-JSON mode.
///
/// The process is spawned with three pipes. stdout is consumed with a
/// `readabilityHandler` (never a blocking read), buffered as raw `Data` and split
/// on newlines; a trailing partial line waits for the next chunk. Parsed events
/// are queued on a lock-protected FIFO and drained on the main actor, so ordering
/// is preserved even though the parse happens on a background queue.
@MainActor
final class ClaudeService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: ClaudeState = .stopped
    @Published private(set) var sessionID: String?
    @Published private(set) var modelName: String?
    @Published private(set) var totalCostUSD: Double = 0

    /// Always invoked on the main actor.
    var onEvent: ((ClaudeEvent) -> Void)?

    // MARK: - Private state

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var channel: IOChannel?

    /// Bumped on every launch so callbacks belonging to a retired process are
    /// dropped instead of clobbering the state of a newer one.
    private var launchGeneration: Int = 0

    /// True once a `system/init` message has been seen for the current process.
    private var didReceiveInit = false

    /// Last assistant message emitted this turn (the CLI repeats assistant
    /// messages once per completed content block, so identical repeats are
    /// suppressed).
    private var lastAssistantMessage: String?

    /// request_id → (control subtype, requested value) for every
    /// control_request still awaiting a control_response. The value is what the
    /// request asked for (model alias / permission mode; nil for interrupt), so
    /// an ack can report exactly which value was confirmed. Cleared whenever a
    /// process starts or dies, so a reply from a retired process can never be
    /// attributed to a new one.
    private var inFlightControlRequests: [String: (subtype: String, value: String?)] = [:]

    /// stdin payloads accepted while the binary is still being resolved off the
    /// main thread (see `start`). Flushed in order the moment the process is up
    /// — the CLI buffers stdin while it boots, so ordering guarantees hold.
    private var pendingStdinPayloads: [Data] = []

    private let stdinQueue = DispatchQueue(label: "com.powerup.claude.stdin")

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

    func start(projectDir: URL,
               model: String,
               permissionMode: String,
               effort: String,
               resumeSessionID: String?,
               claudePathOverride: String?) {

        if process != nil { stop() }

        // Retire the old process *before* anything else can fail: its
        // termination handler is generation-guarded, so once we bump here a
        // replaced process can never deliver a stale `.terminated`.
        launchGeneration &+= 1
        let generation = launchGeneration

        // Reset per-process bookkeeping *before* anything can fail: the retired
        // process's termination handler is generation-guarded and skips this
        // cleanup, so an aborted launch (e.g. unresolvable binary) must not
        // leave stale in-flight entries behind.
        didReceiveInit = false
        lastAssistantMessage = nil
        inFlightControlRequests.removeAll()
        pendingStdinPayloads.removeAll()

        sessionID = resumeSessionID
        state = .starting
        modelName = nil

        // Resolving the binary can shell out to a zsh *login* shell with a
        // blocking wait of up to ~2.5s (heavy .zprofile/.zshrc) — running that
        // on the main actor froze the window at every cold launch. Resolve off
        // the main thread and continue the spawn on the main actor once the
        // path is known; anything sent meanwhile is queued (see `send`).
        Task.detached(priority: .userInitiated) { [weak self] in
            let binaryPath = ClaudeService.resolveClaudeBinary(override: claudePathOverride)
            guard let service = self else { return }
            await service.finishStart(binaryPath: binaryPath,
                                      generation: generation,
                                      projectDir: projectDir,
                                      model: model,
                                      permissionMode: permissionMode,
                                      effort: effort,
                                      resumeSessionID: resumeSessionID)
        }
    }

    /// Second half of `start()`, entered once the binary path is resolved.
    private func finishStart(binaryPath: String?,
                             generation: Int,
                             projectDir: URL,
                             model: String,
                             permissionMode: String,
                             effort: String,
                             resumeSessionID: String?) {
        // A newer start() owns the service now, or stop() was called while the
        // binary was being resolved — either way this launch is abandoned.
        guard launchGeneration == generation else { return }
        guard state != .stopped else {
            pendingStdinPayloads.removeAll()
            inFlightControlRequests.removeAll()
            return
        }

        guard let binaryPath else {
            state = .stopped
            sessionID = nil
            pendingStdinPayloads.removeAll()
            inFlightControlRequests.removeAll()
            emit(.processError("claude CLI not found — set the path in Settings"))
            return
        }

        ClaudeService.ignoreSIGPIPEOnce()

        var arguments = [
            "-p",
            "--verbose",                    // REQUIRED: stream-json output refuses to run without it
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages"
        ]
        if !model.isEmpty && model != "default" {
            arguments.append(contentsOf: ["--model", model])
        }
        if !permissionMode.isEmpty {
            arguments.append(contentsOf: ["--permission-mode", permissionMode])
        }
        // There is no live effort switch — "default" simply means: don't pass the flag.
        if !effort.isEmpty && effort != "default" {
            arguments.append(contentsOf: ["--effort", effort])
        }
        if let resumeSessionID = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resumeSessionID.isEmpty {
            arguments.append(contentsOf: ["--resume", resumeSessionID])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = arguments
        proc.currentDirectoryURL = projectDir
        proc.environment = ClaudeService.childEnvironment(binaryPath: binaryPath)

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
            let reason = finished.terminationReason
            let tail = io.stderrTail(maxChars: 500)
            guard let service = self else { return }

            Task { @MainActor in
                guard service.launchGeneration == generation else {
                    // A newer launch owns the service now; just drop our stale
                    // reference if no replacement process was installed.
                    if service.process === finished {
                        service.process = nil
                        service.stdinHandle = nil
                        service.channel = nil
                    }
                    return
                }
                // Flush late stdout events before announcing termination.
                service.drainEvents(from: io, generation: generation)

                let clean = (exitCode == 0 && reason == .exit)
                if !clean {
                    if !tail.isEmpty {
                        service.emit(.processError(tail))
                    } else {
                        service.emit(.processError("The claude process exited unexpectedly (code \(exitCode))."))
                    }
                }
                service.process = nil
                service.stdinHandle = nil
                service.channel = nil
                service.inFlightControlRequests.removeAll()
                service.state = .stopped
                // A dead process no longer owns its session id. Leaving it set
                // would keep AppState's hook echo guard armed forever — a
                // terminal session resumed with this very id (`claude --resume`)
                // would have all its read-back silently discarded.
                service.sessionID = nil
                service.emit(.terminated(exitCode: exitCode))
            }
        }

        do {
            try proc.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            proc.terminationHandler = nil
            state = .stopped
            sessionID = nil
            pendingStdinPayloads.removeAll()
            inFlightControlRequests.removeAll()
            emit(.processError("Couldn't start the claude CLI at \(binaryPath): \(error.localizedDescription)"))
            return
        }

        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        channel = io

        // Flush anything that was sent while the binary was still resolving.
        if !pendingStdinPayloads.isEmpty, let handle = stdinHandle {
            let queued = pendingStdinPayloads
            pendingStdinPayloads.removeAll()
            for payload in queued { write(payload, to: handle) }
        }
    }

    /// Sends a user turn: one JSON envelope + newline on stdin.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let envelope: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": trimmed]]
            ],
            "parent_tool_use_id": NSNull()
        ]
        guard let payload = ClaudeService.encodeLine(envelope) else { return }

        // The spawn may still be resolving the binary off-main — queue the
        // turn; it is flushed, in order, the moment the process is up.
        if process == nil, state == .starting || state == .working {
            lastAssistantMessage = nil
            state = .working
            pendingStdinPayloads.append(payload)
            return
        }

        guard let proc = process, proc.isRunning, let handle = stdinHandle else {
            emit(.processError("Can't send that — the Claude session isn't running."))
            return
        }

        lastAssistantMessage = nil
        state = .working
        write(payload, to: handle)
    }

    /// Interrupts the current turn.
    func interrupt() {
        sendControlRequest(subtype: "interrupt")
    }

    /// Switches the model mid-session (applies live, no restart).
    func setModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendControlRequest(subtype: "set_model", extra: ["model": trimmed], value: trimmed)
    }

    /// Switches the permission mode mid-session (applies live, no restart).
    func setPermissionMode(_ mode: String) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendControlRequest(subtype: "set_permission_mode", extra: ["mode": trimmed], value: trimmed)
    }

    /// Writes one control request in the nested envelope the CLI requires.
    ///
    /// The flat shape `{"type":"control_request","subtype":"…"}` is FATAL — the
    /// CLI exits with code 1 and "Missing request on control_request", killing the
    /// session. The payload below is the verified shape:
    /// `{"type":"control_request","request_id":"…","request":{"subtype":"…", …}}`.
    private func sendControlRequest(subtype: String, extra: [String: Any] = [:], value: String? = nil) {
        var request: [String: Any] = ["subtype": subtype]
        for (key, fieldValue) in extra { request[key] = fieldValue }

        let requestID = UUID().uuidString
        let envelope: [String: Any] = [
            "type": "control_request",
            "request_id": requestID,
            "request": request
        ]
        guard let payload = ClaudeService.encodeLine(envelope) else { return }

        // Queue during the off-main binary resolution, same as `send`.
        if process == nil, state == .starting || state == .working {
            inFlightControlRequests[requestID] = (subtype: subtype, value: value)
            pendingStdinPayloads.append(payload)
            return
        }

        guard let proc = process, proc.isRunning, let handle = stdinHandle else { return }

        inFlightControlRequests[requestID] = (subtype: subtype, value: value)
        write(payload, to: handle)
    }

    /// Closes stdin (letting claude finish cleanly), then terminates after a
    /// 2 second grace period.
    func stop() {
        guard let proc = process else {
            // A launch may still be resolving its binary; finishStart sees the
            // stopped state and abandons the spawn, and nothing queued should
            // outlive the session it was meant for.
            pendingStdinPayloads.removeAll()
            inFlightControlRequests.removeAll()
            if state != .stopped { state = .stopped }
            return
        }

        if let handle = stdinHandle {
            stdinHandle = nil
            stdinQueue.async {
                try? handle.close()
            }
        }

        state = .stopped

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - Main-actor event plumbing

    private func drainEvents(from io: IOChannel, generation: Int) {
        guard launchGeneration == generation else {
            _ = io.drain()
            return
        }
        for event in io.drain() {
            apply(event)
        }
    }

    /// Applies an event's state changes, then forwards it to `onEvent`.
    private func apply(_ event: ClaudeEvent) {
        switch event {
        case .ready(let id, let model):
            sessionID = id
            // Every init refreshes the model — after a live `set_model` the CLI
            // reports the new one here.
            if !model.isEmpty { modelName = model }
            if !didReceiveInit {
                didReceiveInit = true
                // `send()` may already have marked the first turn as in flight
                // (the CLI queues stdin while it boots) — don't downgrade it.
                if state != .working { state = .ready }
            } else if state == .stopped || state == .starting {
                state = .ready
            }
            lastAssistantMessage = nil

        case .assistantMessage(let text):
            // The CLI repeats the assistant message once per content block.
            if let previous = lastAssistantMessage, previous == text { return }
            lastAssistantMessage = text

        case .turnCompleted(_, let cost, _, _):
            if let cost, cost.isFinite, cost > 0 { totalCostUSD += cost }
            lastAssistantMessage = nil
            state = .ready

        case .controlResult(let requestID, let ok, let detail, _):
            // The background parser has no access to the in-flight map, so it
            // reports the raw request_id in `action`; resolve it to the subtype
            // (and the value that request carried) here. Replies we don't
            // recognise (a stale process, a request the CLI invented) are dropped.
            guard let pending = inFlightControlRequests.removeValue(forKey: requestID) else { return }
            // Don't wait for the next system/init to reflect a live model
            // switch — the chip would lag a full turn behind otherwise.
            if ok, pending.subtype == "set_model", let newModel = pending.value, !newModel.isEmpty {
                modelName = newModel
            }
            emit(.controlResult(action: pending.subtype, ok: ok, detail: detail, value: pending.value))
            return

        case .textDelta, .toolUse, .processError, .terminated:
            break
        }

        emit(event)
    }

    private func emit(_ event: ClaudeEvent) {
        onEvent?(event)
    }

    // MARK: - stdin writing

    private func write(_ data: Data, to handle: FileHandle) {
        stdinQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                let message = "Couldn't reach the claude process: \(error.localizedDescription)"
                guard let service = self else { return }
                Task { @MainActor in
                    service.emit(.processError(message))
                }
            }
        }
    }

    private static func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        data.append(0x0A)
        return data
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

    /// Parses one stdout line. Anything unrecognised is silently ignored.
    private nonisolated static func events(fromLine line: Data) -> [ClaudeEvent] {
        guard !line.isEmpty else { return [] }
        guard let parsed = try? JSONSerialization.jsonObject(with: line, options: []),
              let root = parsed as? [String: Any],
              let type = root["type"] as? String else { return [] }

        switch type {
        case "system":
            guard (root["subtype"] as? String) == "init" else { return [] }
            let id = (root["session_id"] as? String) ?? ""
            let model = (root["model"] as? String) ?? ""
            guard !id.isEmpty else { return [] }
            return [.ready(sessionID: id, model: model)]

        case "stream_event":
            guard let event = root["event"] as? [String: Any],
                  (event["type"] as? String) == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String,
                  !text.isEmpty else { return [] }
            return [.textDelta(text)]

        case "assistant":
            return assistantEvents(root: root)

        case "control_response":
            return controlResponseEvents(root: root)

        case "user":
            // Echoes of our own turns, plus CLI-generated notes such as the
            // "<local-command-stdout>Set model to …</local-command-stdout>" one
            // that follows set_model — whose `content` is a plain STRING, not an
            // array. Nothing here is ever read, so no cast is attempted at all.
            return []

        case "result":
            let subtype = (root["subtype"] as? String) ?? "success"
            let flagged = (root["is_error"] as? Bool) ?? false
            let resultText = (root["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = (root["total_cost_usd"] as? NSNumber)?.doubleValue
            return [.turnCompleted(resultText: (resultText?.isEmpty == true) ? nil : resultText,
                                   costUSD: cost,
                                   isError: flagged || subtype != "success",
                                   subtype: subtype)]

        default:
            // rate_limit_event, non-init system messages, and anything unknown.
            return []
        }
    }

    /// Parses `{"type":"control_response","response":{"subtype":…,"request_id":…}}`.
    ///
    /// `action` carries the raw request_id at this point; the main actor swaps in
    /// the subtype we recorded when the request went out (see `apply`).
    private nonisolated static func controlResponseEvents(root: [String: Any]) -> [ClaudeEvent] {
        guard let response = root["response"] as? [String: Any],
              let requestID = response["request_id"] as? String,
              !requestID.isEmpty else { return [] }

        let subtype = (response["subtype"] as? String) ?? ""
        let ok = (subtype == "success")

        var detail = ""
        if !ok {
            if let error = response["error"] as? String {
                detail = error
            } else if let nested = response["response"] as? [String: Any],
                      let error = nested["error"] as? String {
                detail = error
            }
            if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detail = subtype.isEmpty ? "the CLI rejected the request" : subtype
            }
        }

        return [.controlResult(action: requestID, ok: ok, detail: condense(detail, maxChars: 200), value: nil)]
    }

    private nonisolated static func assistantEvents(root: [String: Any]) -> [ClaudeEvent] {
        guard let message = root["message"] as? [String: Any] else { return [] }

        if let plain = message["content"] as? String {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.assistantMessage(trimmed)]
        }

        guard let blocks = message["content"] as? [Any] else { return [] }

        var textParts: [String] = []
        var toolEvents: [ClaudeEvent] = []

        for element in blocks {
            guard let block = element as? [String: Any],
                  let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { textParts.append(trimmed) }
                }
            case "tool_use":
                let name = (block["name"] as? String) ?? "Tool"
                let detail = toolDetail(from: block["input"] as? [String: Any])
                toolEvents.append(.toolUse(name: name, detail: detail))
            default:
                // "thinking", "redacted_thinking", "tool_result", … — skipped.
                continue
            }
        }

        var events: [ClaudeEvent] = []
        if !textParts.isEmpty {
            events.append(.assistantMessage(textParts.joined(separator: "\n")))
        }
        events.append(contentsOf: toolEvents)
        return events
    }

    /// Best short human-readable summary of a tool's input.
    private nonisolated static func toolDetail(from input: [String: Any]?) -> String {
        guard let input, !input.isEmpty else { return "" }
        let preferred = ["file_path", "command", "description", "pattern", "url", "prompt"]
        for key in preferred {
            if let value = input[key] as? String {
                let condensed = condense(value)
                if !condensed.isEmpty { return condensed }
            }
        }
        for key in input.keys.sorted() {
            if let value = input[key] as? String {
                let condensed = condense(value)
                if !condensed.isEmpty { return condensed }
            }
        }
        return ""
    }

    private nonisolated static func condense(_ text: String, maxChars: Int = 80) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        return String(collapsed.prefix(maxChars - 1)) + "…"
    }
}

// MARK: - Login-shell lookup cache

/// Login shells are slow to start (a heavy profile can take seconds), so the
/// lookup runs at most once per app run. Swift global `let`s are initialized
/// lazily and thread-safely on first access.
private let cachedLoginShellClaudePath: String? = ClaudeService.loginShellLookup()

// MARK: - IOChannel

/// Thread-safe buffers shared between the pipe reader threads and the main actor.
private final class IOChannel: @unchecked Sendable {

    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pending: [ClaudeEvent] = []

    private let maxLineBytes = 16 * 1024 * 1024
    private let maxStderrBytes = 64 * 1024

    /// Appends a stdout chunk and returns every complete line it produced. A
    /// trailing partial line stays buffered for the next chunk.
    func ingestStdout(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        stdoutBuffer.append(data)

        var lines: [Data] = []
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            let nextStart = stdoutBuffer.index(after: newlineIndex)
            stdoutBuffer = stdoutBuffer.subdata(in: nextStart..<stdoutBuffer.endIndex)
            if !line.isEmpty { lines.append(line) }
        }

        // Runaway line without a newline: drop it rather than grow forever.
        if stdoutBuffer.count > maxLineBytes {
            stdoutBuffer.removeAll(keepingCapacity: false)
        }
        return lines
    }

    /// Returns any buffered partial line (used once the stream has ended).
    func flushStdoutRemainder() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !stdoutBuffer.isEmpty else { return nil }
        let remainder = stdoutBuffer
        stdoutBuffer.removeAll(keepingCapacity: false)
        return remainder
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
