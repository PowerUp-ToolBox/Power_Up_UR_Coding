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
/// - `SessionEnd` → `session_id`, `cwd`, `reason` (per docs) — the only
///   signal a session that closes mid-turn ever sends.
struct RemoteHookEvent {
    enum Kind { case stop, userPromptSubmit, notification, sessionEnd }

    let kind: Kind
    /// `last_assistant_message` / `prompt` / `message`, whichever the kind carries.
    let text: String?
    let sessionID: String?
    let cwd: String?
}

// MARK: - RemoteListener

/// A deliberately tiny local server on 127.0.0.1 with two jobs:
///
/// 1. The drop box for PowerUp's Claude Code hook script — `POST /event` with
///    a matching `X-PowerUp-Token` header, answered `204 No Content`.
/// 2. The PowerUp protocol endpoint (docs/protocol.md) — `GET /ws` upgrades to
///    a WebSocket over which authenticated clients receive status/transcript/
///    session events and send intents.
///
/// Everything else (garbage bytes, truncated bodies, oversized uploads, port
/// clashes) is something to survive rather than something to report loudly.
@MainActor
final class RemoteListener: ObservableObject {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    /// Always invoked on the main actor.
    var onEvent: ((RemoteHookEvent) -> Void)?

    /// Intents sent by authenticated protocol clients. Always on the main
    /// actor. Voice-capture intents can never arrive (the protocol vocabulary
    /// omits them — see `IntentMapper.intent(forProtocolName:)`).
    var onIntent: ((Intent) -> Void)?

    /// Messages sent to a client right after its `welcome` — the current
    /// status/session snapshot. Called on the main actor.
    var welcomeSnapshot: (() -> [[String: Any]])?

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

    // MARK: - Protocol broadcast

    /// Sends one protocol message to every authenticated client. Cheap when
    /// nobody is connected; encoding happens once per broadcast.
    func broadcast(_ message: [String: Any]) {
        guard registry.hasAuthed() else { return }
        guard let payload = PowerUpProtocol.encode(message) else { return }
        let frame = WebSocketFraming.encodeText(payload)
        for handler in registry.authedHandlers() {
            handler.sendRawFrame(frame)
        }
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
            onProtocolAuth: { [weak self, registry] handler in
                // Runs on `queue`. Register under the lock first so a broadcast
                // racing with the welcome can already reach this client.
                guard registry.markAuthed(handler) else {
                    handler.refuseForCapacity()
                    return
                }
                guard let owner = self else { return }
                Task { @MainActor in
                    owner.welcomeAuthenticated(handler, generation: generation)
                }
            },
            onProtocolIntent: { [weak self] intent in
                guard let owner = self else { return }
                Task { @MainActor in
                    owner.deliverIntent(intent, generation: generation)
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

    private func deliverIntent(_ intent: Intent, generation: Int) {
        guard generation == self.generation else { return }
        onIntent?(intent)
    }

    private func welcomeAuthenticated(_ handler: HookConnection, generation: Int) {
        guard generation == self.generation else { return }
        handler.sendProtocolMessage(PowerUpProtocol.welcome(appVersion: RemoteListener.appVersion))
        for message in welcomeSnapshot?() ?? [] {
            handler.sendProtocolMessage(message)
        }
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

// MARK: - ConnectionRegistry

/// Keeps in-flight connection handlers alive (Network.framework does not retain
/// them for us) and lets `stop()` drop them all at once. Also tracks which
/// handlers are authenticated protocol clients: they're long-lived, must not
/// be evicted by a burst of hook posts, and are the broadcast audience.
private final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: HookConnection] = [:]
    private var authed: [ObjectIdentifier: HookConnection] = [:]

    /// Hard ceiling so a misbehaving client can't pile up sockets forever.
    private let maxConcurrent = 32
    /// Separate, smaller ceiling for long-lived protocol clients.
    private let maxAuthed = 16

    func insert(_ handler: HookConnection) {
        var evicted: [HookConnection] = []
        lock.lock()
        handlers[ObjectIdentifier(handler)] = handler
        if handlers.count > maxConcurrent {
            // Drop the oldest-looking excess, but never an authenticated
            // protocol client — a hook burst must not sever a device plugin.
            // Any dropped hook request simply isn't answered, which the hook
            // script tolerates by design.
            let overflow = handlers.count - maxConcurrent
            var dropped = 0
            for key in handlers.keys where dropped < overflow {
                guard key != ObjectIdentifier(handler), authed[key] == nil else { continue }
                if let victim = handlers.removeValue(forKey: key) {
                    evicted.append(victim)
                    dropped += 1
                }
            }
        }
        lock.unlock()
        evicted.forEach { $0.cancel() }
    }

    /// Marks a handler as an authenticated protocol client. Returns false when
    /// the client cap is reached — the caller then refuses the connection.
    func markAuthed(_ handler: HookConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard authed.count < maxAuthed else { return false }
        authed[ObjectIdentifier(handler)] = handler
        return true
    }

    func hasAuthed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !authed.isEmpty
    }

    func authedHandlers() -> [HookConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(authed.values)
    }

    func remove(_ handler: HookConnection) {
        lock.lock()
        handlers.removeValue(forKey: ObjectIdentifier(handler))
        authed.removeValue(forKey: ObjectIdentifier(handler))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(handlers.values)
        handlers.removeAll()
        authed.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}

// MARK: - HookConnection

/// Handles one connection: parses an HTTP request, answers it, and closes —
/// or, when the request is a valid `GET /ws` upgrade, switches into WebSocket
/// mode and stays open serving the PowerUp protocol (docs/protocol.md).
///
/// All callbacks are delivered on the single serial queue the connection was
/// started on, so the mutable state below is never touched concurrently. The
/// exception is `sendRawFrame`, called from the main actor for broadcasts —
/// it touches only `NWConnection.send`, which is thread-safe.
private final class HookConnection: @unchecked Sendable {

    private enum Mode { case http, webSocket }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let onEvent: (RemoteHookEvent) -> Void
    private let onProtocolAuth: (HookConnection) -> Void
    private let onProtocolIntent: (Intent) -> Void
    private let onFinished: (HookConnection) -> Void

    private var buffer = Data()
    private var head: RequestHead?
    private var bodyStart = 0
    private var expectedBodyLength = 0
    private var awaitingEOFBody = false
    private var continueSent = false
    private var didRespond = false
    private var didFinish = false

    private var mode: Mode = .http
    private var wsBuffer = Data()
    private var wsAuthed = false

    private let maxHeaderBytes = 16 * 1024
    private let maxBodyBytes = 4 * 1024 * 1024
    private let maxWebSocketPayload = 1024 * 1024
    private let maxWebSocketBuffer = 2 * 1024 * 1024
    private let deadline: TimeInterval = 15

    init(connection: NWConnection,
         queue: DispatchQueue,
         token: String,
         onEvent: @escaping (RemoteHookEvent) -> Void,
         onProtocolAuth: @escaping (HookConnection) -> Void,
         onProtocolIntent: @escaping (Intent) -> Void,
         onFinished: @escaping (HookConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.onEvent = onEvent
        self.onProtocolAuth = onProtocolAuth
        self.onProtocolIntent = onProtocolIntent
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
            // resources forever — and a WebSocket that hasn't authenticated by
            // now never will. Authenticated protocol clients live on.
            guard let self, !(self.mode == .webSocket && self.wsAuthed) else { return }
            self.finish()
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
        guard !didFinish else { return }

        if mode == .webSocket {
            wsBuffer.append(data)
            if wsBuffer.count > maxWebSocketBuffer {
                closeWebSocket(code: 1009)      // message too big
                return
            }
            processWebSocketBuffer()
            return
        }

        guard !didRespond else { return }
        buffer.append(data)
        if buffer.count > maxHeaderBytes + maxBodyBytes {
            respond(status: 413, reason: "Payload Too Large")
            return
        }
        process()
    }

    private func handleEndOfStream() {
        if mode == .webSocket {
            finish()
            return
        }
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

        // The protocol endpoint: a valid upgrade flips this connection into
        // WebSocket mode; an invalid one is answered and closed.
        if let decision = PowerUpProtocol.upgradeDecision(method: head.method,
                                                          path: head.path,
                                                          header: { head.value(for: $0) }) {
            switch decision {
            case .reject(let status, let reason):
                respond(status: status, reason: reason)
            case .accept(let acceptKey):
                acceptWebSocket(acceptKey: acceptKey)
            }
            return
        }

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

    // MARK: WebSocket mode (the PowerUp protocol — docs/protocol.md)

    private func acceptWebSocket(acceptKey: String) {
        guard mode == .http, !didRespond, !didFinish else { return }
        mode = .webSocket

        // Bytes past the header block are the start of the WebSocket stream
        // (a fast client may pipeline its hello behind the handshake).
        if buffer.count > bodyStart {
            wsBuffer = buffer.subdata(in: (buffer.startIndex + bodyStart)..<buffer.endIndex)
        }
        buffer.removeAll(keepingCapacity: false)

        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        send(raw: Data(response.utf8), thenClose: false)

        processWebSocketBuffer()
    }

    private func processWebSocketBuffer() {
        guard mode == .webSocket, !didFinish else { return }

        let frames: [WebSocketFraming.Frame]
        do {
            frames = try WebSocketFraming.decodeFrames(from: &wsBuffer, maxPayload: maxWebSocketPayload)
        } catch {
            closeWebSocket(code: 1002)          // protocol error
            return
        }

        for frame in frames {
            guard !didFinish else { return }
            switch frame.opcode {
            case .text:
                handleProtocolText(frame.payload)
            case .ping:
                sendRawFrame(WebSocketFraming.encodeFrame(opcode: .pong, payload: frame.payload))
            case .pong:
                break
            case .close:
                send(raw: WebSocketFraming.encodeClose(code: 1000), thenClose: true)
            case .binary, .continuation:
                closeWebSocket(code: 1003)      // unsupported data
            }
        }
    }

    private func handleProtocolText(_ payload: Data) {
        switch PowerUpProtocol.parseClientMessage(payload) {
        case .failure(let failure):
            sendProtocolMessage(PowerUpProtocol.error(code: failure.code, message: failure.message))
            switch failure {
            case .malformed, .badHello, .unsupportedProtocol:
                closeWebSocket(code: 1002)
            case .unknownType, .unknownIntent:
                break                            // answered; the session survives
            }

        case .success(.hello(let presented)):
            guard !wsAuthed else { return }      // a second hello is a no-op
            guard presented == token else {
                sendProtocolMessage(PowerUpProtocol.error(
                    code: "auth_failed",
                    message: "The token doesn't match — copy it from Settings → Remote → Read-back."))
                closeWebSocket(code: 4001)
                return
            }
            wsAuthed = true
            onProtocolAuth(self)

        case .success(.intent(let intent)):
            guard wsAuthed else {
                sendProtocolMessage(PowerUpProtocol.error(
                    code: "not_authenticated",
                    message: "Send hello with the token before anything else."))
                closeWebSocket(code: 4003)
                return
            }
            onProtocolIntent(intent)

        case .success(.ping):
            sendProtocolMessage(PowerUpProtocol.pong())
        }
    }

    /// Refusal used when the authenticated-client cap is already reached.
    func refuseForCapacity() {
        sendProtocolMessage(PowerUpProtocol.error(
            code: "server_busy",
            message: "Too many protocol clients are connected."))
        send(raw: WebSocketFraming.encodeClose(code: 1013), thenClose: true)
    }

    private func closeWebSocket(code: UInt16) {
        send(raw: WebSocketFraming.encodeClose(code: code), thenClose: true)
    }

    /// Sends one already-encoded WebSocket frame. Safe from any thread: it
    /// touches only `NWConnection.send`.
    func sendRawFrame(_ frame: Data) {
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Encodes and sends one protocol message. Safe from any thread.
    func sendProtocolMessage(_ message: [String: Any]) {
        guard let payload = PowerUpProtocol.encode(message) else { return }
        sendRawFrame(WebSocketFraming.encodeText(payload))
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
        case "SessionEnd":
            kind = .sessionEnd
            textKey = "reason"
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
