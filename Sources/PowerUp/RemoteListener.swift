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
/// - `PostToolUse` → `session_id`, `cwd`, `tool_name` — fires per tool call;
///   used purely as a liveness heartbeat for the working indicator.
///
/// The core reads the body (`protocol::listener::hook_post`, HK-248); this is
/// what it hands the app.
struct RemoteHookEvent: Equatable {
    enum Kind { case stop, userPromptSubmit, notification, sessionEnd, postToolUse }

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
/// What to do with the bind, each connection, each read, each close and each
/// timer is the Rust core's connection policy (slice 2.6, DESIGN v2.15,
/// `CoreBridge.ListenerPolicy`): the HTTP parsing, the upgrade, the frames,
/// the hello gate, the caps, the idle deadline and the bind retry. This class
/// keeps the sockets — `NWListener` and `NWConnection` on one serial queue —
/// and the timers, reports to the policy what happened and carries out its
/// effects in order. Everything else (garbage bytes, truncated bodies,
/// oversized uploads, port clashes) is something to survive rather than
/// something to report loudly.
@MainActor
final class RemoteListener: ObservableObject {

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    /// Always invoked on the main actor.
    var onEvent: ((RemoteHookEvent) -> Void)?

    /// Intents sent by authenticated protocol clients. Always on the main
    /// actor. Voice-capture intents can never arrive (the protocol vocabulary
    /// omits them — see the core's name table, `CoreBridge.protocolIntent`).
    var onIntent: ((Intent) -> Void)?

    /// Messages sent to a client right after its `welcome` — the current
    /// status/session snapshot. Called on the main actor.
    var welcomeSnapshot: (() -> [CoreBridge.ServerMessage])?

    private let sockets = ListenerSockets()

    /// The newest `publish` already applied: a publish that reaches the main
    /// actor late (from the queue) never overwrites a newer one.
    private var appliedPublish: UInt64 = 0

    init() {
        sockets.toMain = { [weak self] effects in
            let owner = self
            DispatchQueue.main.async { [weak owner] in
                owner?.apply(effects)
            }
        }
    }

    /// Port of the current bind; nil when stopped.
    var activePort: UInt16? {
        sockets.perform { $0.listeningPort }
    }

    // MARK: - Lifecycle

    /// Binds to `127.0.0.1:port`. Calling it again with the same port and token
    /// while running is a no-op; any other call restarts cleanly. An unusable
    /// port or an empty token sets `lastError` and binds nothing (HK-245).
    func start(port: UInt16, token: String) {
        apply(sockets.perform { $0.run($0.policy.start(port: port, token: token)) })
    }

    /// Tears everything down. Safe to call when already stopped.
    func stop() {
        apply(sockets.perform { $0.run($0.policy.stop()) })
    }

    // MARK: - Protocol broadcast

    /// Sends one protocol message to every authenticated client. Cheap when
    /// nobody is connected; encoding happens once per broadcast (HK-262).
    func broadcast(_ message: CoreBridge.ServerMessage) {
        apply(sockets.perform { $0.run($0.policy.broadcast(message)) })
    }

    // MARK: - The policy's app effects

    /// Carries out the effects that belong to the main actor, in order.
    private func apply(_ effects: [ListenerSockets.AppEffect]) {
        for effect in effects {
            switch effect {
            case .publish(let status, let sequence):
                guard sequence > appliedPublish else { continue }
                appliedPublish = sequence
                if isRunning != status.isRunning { isRunning = status.isRunning }
                if lastError != status.lastError { lastError = status.lastError }
            case .deliverHook(let generation, let event):
                // The 204 has already gone out (HK-247); a hook of a torn-down
                // listener is dropped (HK-291).
                guard generation == currentGeneration else { continue }
                onEvent?(event)
            case .deliverIntent(let generation, let intent):
                guard generation == currentGeneration else { continue }
                onIntent?(intent)
            case .welcome(let connection):
                // The policy sends nothing to a connection that is gone or
                // closing meanwhile, so a stale welcome needs no check here.
                let snapshot = welcomeSnapshot?() ?? []
                let version = RemoteListener.appVersion
                apply(sockets.perform {
                    $0.run($0.policy.welcome(connection: connection, appVersion: version, snapshot: snapshot))
                })
            }
        }
    }

    private var currentGeneration: UInt64 {
        sockets.perform { $0.policy.generation }
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

// MARK: - ListenerSockets

/// The socket layer under the policy. Everything here — the policy object,
/// the listener, the connections, the timers' fires — is touched only on
/// `queue`: Network.framework calls back on it, the main actor reaches it
/// with `perform` (a `queue.sync`; nothing on the queue ever waits for the
/// main actor, so it cannot deadlock), and each call into the policy has its
/// effects carried out before the next call (the executor contract, HK-400).
/// The effects that belong to the app go to the main actor in order: at once
/// for a call the main actor made, through `toMain` otherwise.
///
/// A failed core call fails closed (`CoreBridge.ListenerPolicy`, logged
/// under category `core`): a socket just accepted is refused, a connection
/// the call was about is cancelled, a stop still stops listening, and no
/// byte a failed call saw is ever answered or delivered.
private final class ListenerSockets: @unchecked Sendable {

    /// What the main actor carries out.
    enum AppEffect {
        /// `sequence` orders publishes across the two ways to the main actor.
        case publish(CoreBridge.ListenerStatus, sequence: UInt64)
        case deliverHook(generation: UInt64, RemoteHookEvent)
        case deliverIntent(generation: UInt64, Intent)
        case welcome(connection: UInt64)
    }

    /// One admitted connection.
    private final class Socket {
        let connection: NWConnection
        /// Sends not yet written.
        var pendingSends = 0
        /// The policy asked for `closed` once the pending sends are written;
        /// nothing more is read.
        var closing = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    let queue = DispatchQueue(label: "com.powerup.remote-listener")
    let policy = CoreBridge.ListenerPolicy()
    /// Hands app effects from a queue-side call to the main actor.
    var toMain: (@Sendable ([AppEffect]) -> Void)?

    private(set) var listeningPort: UInt16?
    private var listener: NWListener?
    private var connections: [UInt64: Socket] = [:]
    /// The socket an `accepted` call is about, until it is admitted or refused.
    private var arriving: NWConnection?
    private var publishSequence: UInt64 = 0
    private let receiveChunk = max(1, CoreBridge.listenerLimits.receiveChunkBytes)

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.connection.cancel() }
    }

    /// Runs `body` on the queue and waits for it. For the main actor only.
    func perform<T>(_ body: (ListenerSockets) -> T) -> T {
        queue.sync { body(self) }
    }

    /// A queue-side input: the policy's answer is carried out here, its app
    /// effects on the main actor.
    private func input(_ call: (CoreBridge.ListenerPolicy) -> [CoreBridge.ListenerEffect]) {
        let effects = run(call(policy))
        if !effects.isEmpty { toMain?(effects) }
    }

    // MARK: The executor

    /// Carries out the socket effects in order and returns the app's. A call
    /// an effect makes back into the policy (a refused listener, a close
    /// with nothing left to write) runs its effects before the rest.
    func run(_ effects: [CoreBridge.ListenerEffect]) -> [AppEffect] {
        var app: [AppEffect] = []
        for effect in effects {
            switch effect {
            case .publish(let status):
                publishSequence &+= 1
                app.append(.publish(status, sequence: publishSequence))
            case .listen(let generation, let port):
                app += listen(generation: generation, port: port)
            case .stopListening:
                stopListening()
            case .scheduleBindRetry(let generation, let seconds):
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.input { $0.retryFired(generation: generation) }
                }
            case .admit(let id):
                admit(id)
            case .refuse:
                arriving?.cancel()
                arriving = nil
            case .armIdleDeadline(let id, let seconds):
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.input { $0.deadlineFired(connection: id) }
                }
            case .send(let id, let bytes):
                send(bytes, to: id)
            case .broadcast(let ids, let bytes):
                ids.forEach { send(bytes, to: $0) }
            case .close(let id):
                guard let socket = connections[id] else { continue }
                socket.closing = true
                if socket.pendingSends == 0 {
                    app += run(policy.closed(connection: id))
                }
            case .cancel(let id):
                guard let socket = connections.removeValue(forKey: id) else { continue }
                socket.connection.stateUpdateHandler = nil
                socket.connection.cancel()
            case .deliverHook(let generation, let event):
                app.append(.deliverHook(generation: generation, event))
            case .deliverIntent(let generation, let intent):
                app.append(.deliverIntent(generation: generation, intent))
            case .welcome(let id):
                app.append(.welcome(connection: id))
            }
        }
        return app
    }

    // MARK: The bind

    private func listen(generation: UInt64, port: UInt16) -> [AppEffect] {
        stopListening()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return run(policy.listenRefused(generation: generation, detail: "port \(port) can't be used"))
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
            return run(policy.listenRefused(generation: generation, detail: error.localizedDescription))
        }

        // Both handlers fire on `queue`.
        created.stateUpdateHandler = { [weak self] state in
            self?.bindChanged(to: state, generation: generation)
        }
        created.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.arriving = connection
            self.input { $0.accepted(generation: generation) }
            // Neither admitted nor refused (it cannot happen): never keep it.
            self.arriving?.cancel()
            self.arriving = nil
        }
        listener = created
        listeningPort = port
        created.start(queue: queue)
        return []
    }

    private func stopListening() {
        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listener = nil
        listeningPort = nil
    }

    private func bindChanged(to state: NWListener.State, generation: UInt64) {
        switch state {
        case .ready:
            input { $0.bindReady(generation: generation) }
        case .waiting(let error):
            // Most often EADDRINUSE. Network.framework keeps retrying, so the
            // listener stays alive and may recover on its own.
            input { $0.bindWaiting(generation: generation, error: ListenerSockets.bindError(error)) }
        case .failed(let error):
            // Port contention arrives as .failed (verified), not .waiting; the
            // policy stops and schedules its spaced retries (HK-292).
            input { $0.bindFailed(generation: generation, error: ListenerSockets.bindError(error)) }
        case .cancelled:
            input { $0.bindCancelled(generation: generation) }
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private static func bindError(_ error: NWError) -> CoreBridge.BindError {
        if case .posix(let code) = error, code == .EADDRINUSE { return .addressInUse }
        return .other(error.localizedDescription)
    }

    // MARK: Connections

    private func admit(_ id: UInt64) {
        guard let connection = arriving else { return }
        arriving = nil
        connections[id] = Socket(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.input { $0.closed(connection: id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UInt64) {
        guard let socket = connections[id] else { return }
        socket.connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunk) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.input { $0.received(connection: id, bytes: data) }
            }
            if error != nil {
                self.input { $0.closed(connection: id) }
                return
            }
            if isComplete {
                self.input { $0.endOfStream(connection: id) }
                return
            }
            // A connection the policy is closing reads nothing more.
            if let socket = self.connections[id], !socket.closing {
                self.receive(id)
            }
        }
    }

    /// Network.framework writes sends in order and calls their completions
    /// on `queue`, so `closed` follows the last byte the policy sent.
    private func send(_ bytes: Data, to id: UInt64) {
        guard let socket = connections[id] else { return }
        socket.pendingSends += 1
        socket.connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            self?.written(id)
        })
    }

    private func written(_ id: UInt64) {
        guard let socket = connections[id] else { return }
        socket.pendingSends -= 1
        if socket.closing, socket.pendingSends == 0 {
            input { $0.closed(connection: id) }
        }
    }
}
