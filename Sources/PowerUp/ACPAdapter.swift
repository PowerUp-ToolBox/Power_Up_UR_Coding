import Foundation

/// Drives any Agent Client Protocol agent (JSON-RPC 2.0, newline-delimited,
/// over stdio): opencode natively, Claude Code via the
/// `@agentclientprotocol/claude-agent-acp` bridge, or a custom command.
///
/// Wire shapes verified live on this machine (2026-08-27) against
/// opencode 1.1.44 and claude-agent-acp 0.16.2 — see DESIGN.md v2.0. Parse
/// defensively throughout: unknown methods, update kinds, and fields are
/// ignored, and a protocol surprise degrades to an error event, never a crash.
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

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lines: LineQueue?
    private var launchGeneration = 0

    private var nextRequestID = 1
    private enum Pending {
        case initialize, sessionNew, prompt
        case setModel(String), setMode(String)
    }
    private var pendingRequests: [Int: Pending] = [:]

    /// Agent→client permission requests awaiting an answer:
    /// our event id (stringified JSON-RPC id) → (rpc id, [(optionId, kind)]).
    private var pendingPermissions: [String: (rpcID: Int, options: [(id: String, kind: String)])] = [:]

    /// Prompts accepted while a turn is in flight; sent FIFO on completion.
    private var queuedPrompts: [String] = []
    private var replyBuffer = ""
    private var stopRequested = false

    private let stdinQueue = DispatchQueue(label: "com.powerup.acp.stdin")

    // MARK: - Command resolution (pure-ish, tested)

    /// The agent command for the config's ACP settings, or nil when it can't
    /// be resolved (missing binary, empty custom command).
    nonisolated static func agentCommand(for config: AppConfig) -> [String]? {
        switch config.acpAgent {
        case "opencode":
            let candidates = [
                NSHomeDirectory() + "/.opencode/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode",
            ]
            guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return nil
            }
            return [binary, "acp"]
        case "claudeBridge":
            let candidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]
            guard let npx = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return nil
            }
            return [npx, "-y", "@agentclientprotocol/claude-agent-acp"]
        case "codexBridge":
            // Handshake verified live 2026-08-27 (bridge 1.7.0 via npx).
            let candidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]
            guard let npx = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return nil
            }
            return [npx, "-y", "@agentclientprotocol/codex-acp"]
        case "custom":
            let parts = config.acpCustomCommand
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            return parts.isEmpty ? nil : parts
        default:
            return nil
        }
    }

    /// The environment for a spawned agent. Strips the Claude-nesting markers
    /// (`CLAUDECODE`, `CLAUDE_CODE_*`) — verified live: the Claude bridge
    /// refuses to run inside a Claude session otherwise — and makes sure the
    /// usual install locations are on PATH.
    nonisolated static func agentEnvironment(from base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in
            key != "CLAUDECODE" && key != "CLAUDE_PID" && !key.hasPrefix("CLAUDE_CODE_")
        }
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
        let matching = options.filter { allow ? $0.kind.contains("allow") : $0.kind.contains("reject") }
        return (matching.first { $0.kind.contains("once") } ?? matching.first)?.id
    }

    // MARK: - Lifecycle

    func start(_ configuration: HarnessConfiguration) {
        if process != nil { stop() }

        launchGeneration &+= 1
        let generation = launchGeneration

        pendingRequests.removeAll()
        pendingPermissions.removeAll()
        queuedPrompts.removeAll()
        replyBuffer = ""
        stopRequested = false
        sessionID = nil
        modelName = nil
        totalTokens = 0
        state = .starting

        guard let command = configuration.agentCommand, let executable = command.first else {
            state = .stopped
            emit(.runtimeError("No ACP agent command is configured — check Settings → General → Harness."))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = Array(command.dropFirst())
        proc.currentDirectoryURL = configuration.projectDir
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
                adapter.handleTermination(code: code, stderrTail: tail, generation: generation)
            }
        }

        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            state = .stopped
            emit(.runtimeError("Couldn't start the ACP agent (\(executable)): \(error.localizedDescription)"))
            return
        }

        process = proc
        stdinHandle = inPipe.fileHandleForWriting
        lines = queue

        sendRequest(.initialize, method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ])

        // A wedged agent must not leave the app "starting" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.launchGeneration == generation, self.state == .starting else { return }
            self.emit(.runtimeError("The ACP agent didn't finish starting within 30 seconds."))
            self.stop()
        }

        // session/new is sent from the initialize response, carrying the cwd.
        pendingConfiguration = configuration
    }

    private var pendingConfiguration: HarnessConfiguration?

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch state {
        case .stopped:
            emit(.runtimeError("Can't send that — the agent session isn't running."))
        case .starting, .working:
            queuedPrompts.append(trimmed)
            state = .working
        case .ready:
            sendPrompt(trimmed)
        }
    }

    private func sendPrompt(_ text: String) {
        guard let sessionID else {
            queuedPrompts.append(text)
            return
        }
        replyBuffer = ""
        state = .working
        sendRequest(.prompt, method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": text]],
        ])
    }

    func interrupt() {
        guard let sessionID else { return }
        cancelPendingPermissions()
        sendNotification(method: "session/cancel", params: ["sessionId": sessionID])
        emit(.controlResult(action: "interrupt", ok: true, detail: "", value: nil))
    }

    func setModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }
        sendRequest(.setModel(trimmed), method: "session/set_model",
                    params: ["sessionId": sessionID, "modelId": trimmed])
    }

    func setPermissionMode(_ mode: String) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionID else { return }
        sendRequest(.setMode(trimmed), method: "session/set_mode",
                    params: ["sessionId": sessionID, "modeId": trimmed])
    }

    func respondToPermission(id: String, allow: Bool) {
        guard let pending = pendingPermissions.removeValue(forKey: id) else { return }
        let outcome: [String: Any]
        if let optionID = ACPAdapter.permissionChoice(options: pending.options, allow: allow) {
            outcome = ["outcome": "selected", "optionId": optionID]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        write(["jsonrpc": "2.0", "id": pending.rpcID, "result": ["outcome": outcome]])
    }

    func stop() {
        stopRequested = true
        cancelPendingPermissions()
        pendingRequests.removeAll()
        queuedPrompts.removeAll()

        guard let proc = process else {
            if state != .stopped { state = .stopped }
            return
        }
        if let handle = stdinHandle {
            stdinHandle = nil
            stdinQueue.async { try? handle.close() }
        }
        state = .stopped
        sessionID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - Incoming messages

    private func drainLines(from queue: LineQueue, generation: Int) {
        let batch = queue.drain()
        guard launchGeneration == generation, state != .stopped else { return }
        // (state guard: after stop(), the pipe stays readable until the 2s
        // terminate grace — a dying agent's late permission request must not
        // resurrect UI state the caller just cleared.)
        for line in batch {
            guard let parsed = try? JSONSerialization.jsonObject(with: line),
                  let message = parsed as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        // Response to one of our requests.
        if let id = message["id"] as? Int, let pending = pendingRequests.removeValue(forKey: id) {
            handleResponse(pending, message: message)
            return
        }
        // Request from the agent (has both method and id).
        if let method = message["method"] as? String {
            if let id = message["id"] {
                handleAgentRequest(method: method, id: id, params: message["params"] as? [String: Any])
            } else if method == "session/update" {
                handleSessionUpdate(message["params"] as? [String: Any] ?? [:])
            }
            return
        }
        // Anything else (stray response, malformed) — ignore.
    }

    private func handleResponse(_ pending: Pending, message: [String: Any]) {
        let result = message["result"] as? [String: Any]
        let error = message["error"] as? [String: Any]
        let errorText = (error?["message"] as? String) ?? ""

        switch pending {
        case .initialize:
            guard error == nil else {
                emit(.runtimeError("The ACP agent rejected initialize: \(errorText)"))
                stop()
                return
            }
            guard let configuration = pendingConfiguration else { return }
            sendRequest(.sessionNew, method: "session/new", params: [
                "cwd": configuration.projectDir.path,
                "mcpServers": [],
            ])

        case .sessionNew:
            guard error == nil, let result, let id = result["sessionId"] as? String else {
                emit(.runtimeError(errorText.isEmpty
                    ? "The ACP agent couldn't create a session. Is it logged in? (e.g. run `opencode auth login`)"
                    : "The ACP agent couldn't create a session: \(errorText)"))
                stop()
                return
            }
            sessionID = id
            let models = result["models"] as? [String: Any]
            modelName = models?["currentModelId"] as? String
            if state == .starting { state = .ready }
            emit(.sessionReady(sessionID: id, model: modelName ?? "acp"))
            if !queuedPrompts.isEmpty {
                let next = queuedPrompts.removeFirst()
                sendPrompt(next)
            }

        case .prompt:
            if let usage = result?["usage"] as? [String: Any] {
                let input = (usage["inputTokens"] as? NSNumber)?.intValue ?? 0
                let output = (usage["outputTokens"] as? NSNumber)?.intValue ?? 0
                if input + output > 0 { totalTokens += input + output }
            }
            let stopReason = (result?["stopReason"] as? String) ?? (error != nil ? "error" : "end_turn")
            let text = replyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            replyBuffer = ""
            if !text.isEmpty {
                emit(.reply(text))
            }
            let isError = (error != nil) || stopReason == "refusal"
            emit(.turnCompleted(resultText: text.isEmpty ? nil : text,
                                costUSD: nil,
                                isError: isError,
                                detail: error != nil ? (errorText.isEmpty ? "error" : errorText) : stopReason))
            state = .ready
            if !queuedPrompts.isEmpty {
                let next = queuedPrompts.removeFirst()
                sendPrompt(next)
            }

        case .setModel(let value):
            let ok = (error == nil)
            if ok { modelName = value }
            emit(.controlResult(action: "set_model", ok: ok,
                                detail: ok ? "" : (errorText.isEmpty ? "the agent rejected the model" : errorText),
                                value: value))

        case .setMode(let value):
            let ok = (error == nil)
            emit(.controlResult(action: "set_permission_mode", ok: ok,
                                detail: ok ? "" : (errorText.isEmpty ? "the agent rejected the mode" : errorText),
                                value: value))
        }
    }

    private func handleAgentRequest(method: String, id: Any, params: [String: Any]?) {
        switch method {
        case "session/request_permission":
            guard let rpcID = id as? Int else {
                write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                return
            }
            let toolCall = params?["toolCall"] as? [String: Any]
            let title = (toolCall?["title"] as? String) ?? "run a tool"
            let kind = (toolCall?["kind"] as? String) ?? ""
            let detail = ACPAdapter.toolDetail(from: toolCall)
            let options = ((params?["options"] as? [[String: Any]]) ?? []).compactMap { option -> (id: String, kind: String)? in
                guard let optionID = option["optionId"] as? String else { return nil }
                return (optionID, (option["kind"] as? String) ?? "")
            }
            let eventID = String(rpcID)
            pendingPermissions[eventID] = (rpcID, options)
            emit(.permissionRequest(id: eventID, name: title, kind: kind, detail: detail))

        default:
            // fs/*, terminal/* — we declared no such capabilities; refuse politely.
            write(["jsonrpc": "2.0", "id": id,
                   "error": ["code": -32601, "message": "PowerUp does not support \(method)"]])
        }
    }

    private func handleSessionUpdate(_ params: [String: Any]) {
        guard let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "agent_message_chunk":
            guard let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String, !text.isEmpty else { return }
            replyBuffer += text
            emit(.replyDelta(text))

        case "tool_call":
            let name = ((update["_meta"] as? [String: Any])?["claudeCode"] as? [String: Any])?["toolName"] as? String
                ?? (update["title"] as? String) ?? "Tool"
            emit(.toolUse(name: name, detail: ACPAdapter.toolDetail(from: update)))

        default:
            // agent_thought_chunk, tool_call_update, usage_update, plan,
            // available_commands_update, current_mode_update, … — ignored.
            break
        }
    }

    /// Best short human string for a tool call: a file location, else the
    /// first string in rawInput, else empty.
    private nonisolated static func toolDetail(from toolCall: [String: Any]?) -> String {
        guard let toolCall else { return "" }
        if let locations = toolCall["locations"] as? [[String: Any]],
           let path = locations.first?["path"] as? String, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if let rawInput = toolCall["rawInput"] as? [String: Any] {
            for key in ["file_path", "command", "description", "pattern", "url"] {
                if let value = rawInput[key] as? String, !value.isEmpty {
                    return value.count > 80 ? String(value.prefix(79)) + "…" : value
                }
            }
        }
        return ""
    }

    private func handleTermination(code: Int32, stderrTail: String, generation: Int) {
        guard launchGeneration == generation else { return }
        let wasExpected = stopRequested
        process = nil
        stdinHandle = nil
        lines = nil
        pendingRequests.removeAll()
        cancelPendingPermissions()
        state = .stopped
        sessionID = nil
        if !wasExpected {
            if !stderrTail.isEmpty {
                emit(.runtimeError(stderrTail))
            }
            emit(.ended(exitCode: code))
        }
    }

    /// Any permission request left unanswered when the moment passes is
    /// cancelled so the agent never hangs on us.
    private func cancelPendingPermissions() {
        for (_, pending) in pendingPermissions {
            write(["jsonrpc": "2.0", "id": pending.rpcID, "result": ["outcome": ["outcome": "cancelled"]]])
        }
        pendingPermissions.removeAll()
    }

    // MARK: - Outgoing messages

    private func sendRequest(_ pending: Pending, method: String, params: [String: Any]) {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = pending
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func sendNotification(method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        let line = payload + Data([0x0A])
        guard let handle = stdinHandle else { return }
        stdinQueue.async {
            try? handle.write(contentsOf: line)
        }
    }

    private func emit(_ event: HarnessEvent) {
        onHarnessEvent?(event)
    }
}

// MARK: - LineQueue

/// Thread-safe buffers between the pipe reader threads and the main actor:
/// newline-split stdout lines (order-preserving) plus a bounded stderr tail.
private final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [Data] = []
    private var stderrBuffer = Data()

    private let maxLineBytes = 16 * 1024 * 1024
    private let maxStderrBytes = 64 * 1024

    func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
            if !line.isEmpty { pending.append(line) }
        }
        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: false)
        }
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
