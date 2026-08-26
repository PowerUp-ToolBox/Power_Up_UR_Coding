import Foundation
import Combine
import Network

// MARK: - RemoteHookEvent

/// One Claude Code hook firing, delivered by the hook script over loopback HTTP.
///
/// Verified stdin shapes (claude v2.1.243):
/// - `Stop` → `hook_event_name`, `session_id`, `cwd`, `permission_mode`,
///   `last_assistant_message` (the full final reply — no transcript parsing).
/// - `UserPromptSubmit` → `hook_event_name`, `session_id`, `cwd`, `prompt`.
/// - `Notification` → `message` (per docs).
struct RemoteHookEvent {
    enum Kind { case stop, userPromptSubmit, notification }

    let kind: Kind
    /// `last_assistant_message` / `prompt` / `message`, whichever the kind carries.
    let text: String?
    let sessionID: String?
    let cwd: String?
}

// MARK: - RemoteListener

/// A deliberately tiny HTTP server on 127.0.0.1, used only as the drop box for
/// PowerUp's Claude Code hook script.
///
/// It accepts exactly one request shape — `POST /event` with a matching
/// `X-PowerUp-Token` header — answers `204 No Content` immediately, and treats
/// everything else (garbage bytes, truncated bodies, oversized uploads, port
/// clashes) as something to survive rather than something to report loudly.
@MainActor
final class RemoteListener: ObservableObject {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    /// Always invoked on the main actor.
    var onEvent: ((RemoteHookEvent) -> Void)?

    private let queue = DispatchQueue(label: "com.powerup.remote-listener")
    private let registry = ConnectionRegistry()

    private var listener: NWListener?
    private var activePort: UInt16?
    private var activeToken: String?

    /// Bumped on every start/stop so events from a torn-down listener can never
    /// be attributed to a newer one.
    private var generation = 0

    /// Bounded recovery from a `.failed` bind (usually a transient port clash):
    /// a few spaced retries, reset on success or on any explicit start/stop.
    private var retryAttempts = 0
    private static let maxRetryAttempts = 3

    // MARK: - Lifecycle

    /// Binds to `127.0.0.1:port`. Calling it again with the same port and token
    /// while running is a no-op; any other call restarts cleanly.
    func start(port: UInt16, token: String) {
        if isRunning, listener != nil, activePort == port, activeToken == token { return }

        stop()

        // Ports below 1024 need root to bind — accepting one here would just
        // trade a clear message now for an opaque bind failure a moment later.
        guard port >= 1024, let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Port \(port) isn't a usable port number — pick one between 1024 and 65535."
            return
        }
        guard !token.isEmpty else {
            lastError = "The read-back token is empty — reinstall the hooks from Settings → Remote."
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        // Loopback ONLY: nothing outside this machine can ever reach the listener.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            lastError = "Couldn't listen on 127.0.0.1:\(port) — \(error.localizedDescription)"
            return
        }

        generation &+= 1
        let generation = self.generation
        listener = created
        activePort = port
        activeToken = token
        lastError = nil

        created.stateUpdateHandler = { [weak self] state in
            guard let owner = self else { return }
            Task { @MainActor in
                owner.handleListenerState(state, generation: generation, port: port)
            }
        }

        created.newConnectionHandler = { [weak self] connection in
            guard let listener = self else {
                connection.cancel()
                return
            }
            listener.accept(connection, token: token, generation: generation)
        }

        created.start(queue: queue)
    }

    /// Tears everything down. Safe to call when already stopped.
    func stop() {
        generation &+= 1

        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listener = nil
        activePort = nil
        activeToken = nil
        registry.cancelAll()

        if isRunning { isRunning = false }
    }

    private func handleListenerState(_ state: NWListener.State, generation: Int, port: UInt16) {
        guard generation == self.generation else { return }

        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            retryAttempts = 0
        case .waiting(let error):
            // Most often EADDRINUSE. Network.framework keeps retrying, so the
            // listener stays alive and may recover on its own.
            isRunning = false
            lastError = RemoteListener.describe(error, port: port)
        case .failed(let error):
            // Port contention arrives as .failed (verified), not the .waiting
            // above — without a retry, one transient clash would leave the
            // listener down for the rest of the session with no way back short
            // of editing the port. A few spaced attempts recover on their own;
            // any explicit start/stop meanwhile bumps the generation and
            // invalidates the pending retry.
            isRunning = false
            lastError = RemoteListener.describe(error, port: port)
            let token = activeToken
            stop()
            if retryAttempts < RemoteListener.maxRetryAttempts, let token {
                retryAttempts += 1
                let retryGeneration = self.generation
                let delay = Double(retryAttempts) * 2.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let owner = self,
                          owner.generation == retryGeneration,
                          owner.listener == nil else { return }
                    owner.start(port: port, token: token)
                }
            }
        case .cancelled:
            isRunning = false
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use — pick a different port in Settings → Remote."
        }
        return "Listener problem on port \(port): \(error.localizedDescription)"
    }

    // MARK: - Connections

    /// The `newConnectionHandler` fires on `queue`; this hands the socket to a
    /// self-contained handler and keeps a strong reference until it's done.
    private nonisolated func accept(_ connection: NWConnection, token: String, generation: Int) {
        let handler = HookConnection(
            connection: connection,
            queue: queue,
            token: token,
            onEvent: { [weak self] event in
                guard let owner = self else { return }
                Task { @MainActor in
                    owner.deliver(event, generation: generation)
                }
            },
            onFinished: { [registry] handler in
                registry.remove(handler)
            }
        )
        registry.insert(handler)
        handler.start()
    }

    private func deliver(_ event: RemoteHookEvent, generation: Int) {
        guard generation == self.generation else { return }
        onEvent?(event)
    }
}

// MARK: - ConnectionRegistry

/// Keeps in-flight connection handlers alive (Network.framework does not retain
/// them for us) and lets `stop()` drop them all at once.
private final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: HookConnection] = [:]

    /// Hard ceiling so a misbehaving client can't pile up sockets forever.
    private let maxConcurrent = 32

    func insert(_ handler: HookConnection) {
        var evicted: [HookConnection] = []
        lock.lock()
        handlers[ObjectIdentifier(handler)] = handler
        if handlers.count > maxConcurrent {
            // Drop the oldest-looking excess; any dropped request simply isn't
            // answered, which the hook script tolerates by design.
            let overflow = handlers.count - maxConcurrent
            for key in handlers.keys.prefix(overflow) where key != ObjectIdentifier(handler) {
                if let victim = handlers.removeValue(forKey: key) { evicted.append(victim) }
            }
        }
        lock.unlock()
        evicted.forEach { $0.cancel() }
    }

    func remove(_ handler: HookConnection) {
        lock.lock()
        handlers.removeValue(forKey: ObjectIdentifier(handler))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}

// MARK: - HookConnection

/// Parses one HTTP request off one connection, answers it, and closes.
///
/// All callbacks are delivered on the single serial queue the connection was
/// started on, so the mutable state below is never touched concurrently.
private final class HookConnection: @unchecked Sendable {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let onEvent: (RemoteHookEvent) -> Void
    private let onFinished: (HookConnection) -> Void

    private var buffer = Data()
    private var head: RequestHead?
    private var bodyStart = 0
    private var expectedBodyLength = 0
    private var awaitingEOFBody = false
    private var continueSent = false
    private var didRespond = false
    private var didFinish = false

    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 4 * 1024 * 1024
    private let deadline: TimeInterval = 15

    init(connection: NWConnection,
         queue: DispatchQueue,
         token: String,
         onEvent: @escaping (RemoteHookEvent) -> Void,
         onFinished: @escaping (HookConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.onEvent = onEvent
        self.onFinished = onFinished
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            // A client that opens a socket and then says nothing must not pin
            // resources forever.
            self?.finish()
        }
        receive()
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finish()
        }
    }

    // MARK: Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            if error != nil {
                self.finish()
                return
            }
            if isComplete {
                self.handleEndOfStream()
                return
            }
            if !self.didRespond && !self.didFinish {
                self.receive()
            }
        }
    }

    private func ingest(_ data: Data) {
        guard !didRespond, !didFinish else { return }
        buffer.append(data)
        if buffer.count > maxHeaderBytes + maxBodyBytes {
            respond(status: 413, reason: "Payload Too Large")
            return
        }
        process()
    }

    private func handleEndOfStream() {
        guard !didRespond, !didFinish else {
            finish()
            return
        }
        if head != nil {
            // The peer closed early (or used chunked encoding): answer with
            // whatever arrived rather than hanging.
            complete(bodyFromRemainder: true)
        } else {
            finish()
        }
    }

    private func process() {
        if head == nil {
            guard let boundary = HookConnection.headerBoundary(in: buffer) else {
                if buffer.count > maxHeaderBytes {
                    respond(status: 431, reason: "Request Header Fields Too Large")
                }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + boundary.headerEnd))
            guard let parsed = RequestHead(headerData) else {
                respond(status: 400, reason: "Bad Request")
                return
            }
            head = parsed
            bodyStart = boundary.bodyStart

            if let declared = parsed.contentLength {
                guard declared >= 0, declared <= maxBodyBytes else {
                    respond(status: 413, reason: "Payload Too Large")
                    return
                }
                expectedBodyLength = declared
            } else if parsed.isChunked {
                // We don't decode chunked framing; read to EOF and let the JSON
                // parse fail harmlessly if the framing bytes are in the way.
                awaitingEOFBody = true
            } else {
                expectedBodyLength = 0
            }

            // curl adds `Expect: 100-continue` for bodies over ~1KB and waits
            // for the interim response before sending them. Hook payloads
            // routinely exceed that, so this handshake is not optional.
            if parsed.expectsContinue, !continueSent {
                continueSent = true
                send(raw: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), thenClose: false)
            }
        }

        guard !awaitingEOFBody else { return }
        let available = buffer.count - bodyStart
        if available >= expectedBodyLength {
            complete(bodyFromRemainder: false)
        }
    }

    // MARK: Responding

    private func complete(bodyFromRemainder: Bool) {
        guard !didRespond, !didFinish, let head else { return }

        guard head.method == "POST" else {
            respond(status: 404, reason: "Not Found")
            return
        }
        guard head.path == "/event" else {
            respond(status: 404, reason: "Not Found")
            return
        }
        guard !token.isEmpty, head.value(for: "x-powerup-token") == token else {
            respond(status: 403, reason: "Forbidden")
            return
        }

        let length = bodyFromRemainder
            ? max(0, buffer.count - bodyStart)
            : min(expectedBodyLength, max(0, buffer.count - bodyStart))
        let body = length > 0
            ? buffer.subdata(in: (buffer.startIndex + bodyStart)..<(buffer.startIndex + bodyStart + length))
            : Data()

        // Answer first: the hook script is holding up nothing, but the sooner
        // curl is released the less chance it hits its 1s --max-time.
        respond(status: 204, reason: "No Content")

        if let event = HookConnection.event(from: body) {
            onEvent(event)
        }
    }

    private func respond(status: Int, reason: String) {
        guard !didRespond, !didFinish else { return }
        didRespond = true

        var response = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        if status != 204 {
            response += "Content-Length: 0\r\n"
        }
        response += "\r\n"
        send(raw: Data(response.utf8), thenClose: true)
    }

    private func send(raw data: Data, thenClose: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard thenClose else { return }
            self?.finish()
        })
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        buffer.removeAll(keepingCapacity: false)
        onFinished(self)
    }

    // MARK: Parsing helpers

    /// Finds the end of the header block, tolerating bare-LF line endings.
    private static func headerBoundary(in data: Data) -> (headerEnd: Int, bodyStart: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D, index + 3 < bytes.count,
               bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return (index, index + 4)
            }
            if bytes[index] == 0x0A, bytes[index + 1] == 0x0A {
                return (index, index + 2)
            }
            index += 1
        }
        return nil
    }

    /// Maps a hook payload to an event. Anything unexpected yields nil, which
    /// the caller treats as "answer 204 and forget it".
    private static func event(from body: Data) -> RemoteHookEvent? {
        guard !body.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: body, options: []),
              let root = parsed as? [String: Any],
              let name = root["hook_event_name"] as? String else { return nil }

        let kind: RemoteHookEvent.Kind
        let textKey: String
        switch name {
        case "Stop":
            kind = .stop
            textKey = "last_assistant_message"
        case "UserPromptSubmit":
            kind = .userPromptSubmit
            textKey = "prompt"
        case "Notification":
            kind = .notification
            textKey = "message"
        default:
            // SubagentStop, PreToolUse, anything future — not ours to act on.
            return nil
        }

        return RemoteHookEvent(kind: kind,
                               text: nonEmpty(root[textKey] as? String),
                               sessionID: nonEmpty(root["session_id"] as? String),
                               cwd: nonEmpty(root["cwd"] as? String))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

// MARK: - RequestHead

/// The request line plus headers of one HTTP request.
private struct RequestHead {
    let method: String
    let path: String
    private let headers: [String: String]   // lowercased names

    init?(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        method = parts[0].uppercased()
        let target = String(parts[1])
        path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        var collected: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            collected[name] = value
        }
        headers = collected
    }

    func value(for name: String) -> String? { headers[name.lowercased()] }

    var contentLength: Int? {
        guard let raw = headers["content-length"] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    var isChunked: Bool {
        (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
    }

    var expectsContinue: Bool {
        (headers["expect"] ?? "").lowercased().contains("100-continue")
    }
}
