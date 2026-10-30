import Foundation
import PowerUpCore

// MARK: - The listener's connection policy (slice 2.6)
//
// What the loopback listener does with its bind, each connection, each
// read, each close and each timer runs in the Rust core (DESIGN v2.15): the
// hook posts, the upgrade, the hello gate, the caps, the idle deadline and
// the bind retry. RemoteListener keeps the sockets (NWListener and
// NWConnection), the queue and the timers, reports what happened and
// carries out the effects in order.

extension CoreBridge {

    /// The listener's published state: RemoteListener's `isRunning` and
    /// `lastError`, the text Settings shows.
    struct ListenerStatus: Equatable {
        var isRunning: Bool
        var lastError: String?

        static let stopped = ListenerStatus(isRunning: false, lastError: nil)
    }

    /// Why a bind went wrong, as Network.framework reported it.
    enum BindError: Equatable {
        /// EADDRINUSE.
        case addressInUse
        /// Anything else, with its `localizedDescription`.
        case other(String)
    }

    /// What the listener asks RemoteListener to do. Run them in order, each
    /// before the next, and before the next call into the same policy.
    enum ListenerEffect: Equatable {
        /// Assign `isRunning` and `lastError`.
        case publish(ListenerStatus)
        /// Bind 127.0.0.1:`port`; report the bind's states with this
        /// generation (or `listenRefused` at once when no listener can be
        /// created) and accept its connections with it.
        case listen(generation: UInt64, port: UInt16)
        /// Cancel the listener; its connections are cancelled by their own
        /// effects.
        case stopListening
        /// One-shot: after `seconds`, call `retryFired(generation:)`.
        case scheduleBindRetry(generation: UInt64, seconds: TimeInterval)
        /// The socket just accepted is this connection: keep it, start it,
        /// read from it, and report it by this number.
        case admit(connection: UInt64)
        /// The socket just accepted belongs to no current listener: cancel
        /// it.
        case refuse
        /// One-shot: after `seconds`, call `deadlineFired(connection:)`.
        case armIdleDeadline(connection: UInt64, seconds: TimeInterval)
        /// Write these bytes on the connection.
        case send(connection: UInt64, bytes: Data)
        /// Write the same bytes on each connection, in this order (HK-262).
        case broadcast(connections: [UInt64], bytes: Data)
        /// Once the bytes sent before it are written, call
        /// `closed(connection:)`.
        case close(connection: UInt64)
        /// Cancel the connection now; the policy has forgotten it.
        case cancel(connection: UInt64)
        /// Hand a hook to the app; its 204 has already been sent (HK-247).
        /// Carried out later than in order, drop it once the generation has
        /// moved on.
        case deliverHook(generation: UInt64, RemoteHookEvent)
        /// Hand an authenticated client's intent to the app, with the same
        /// generation rule.
        case deliverIntent(generation: UInt64, Intent)
        /// The connection is authenticated: answer with
        /// `welcome(connection:appVersion:snapshot:)` (HK-234).
        case welcome(connection: UInt64)
    }

    /// The connection policy (DESIGN v2.15). One per RemoteListener, alive
    /// across starts; the generation and the connections live inside. Call
    /// it from one queue at a time: its effects must run in the order the
    /// calls were made. A core failure is logged and gives the inert
    /// answer: no effects, except that a socket just accepted is refused, a
    /// connection the failed call was about is cancelled, and a stop still
    /// stops listening. A failed constructor answers every call that way,
    /// so nothing ever listens.
    final class ListenerPolicy {
        private let core: CoreListener?

        init() {
            core = CoreBridge.call("CoreListener.init", fallback: nil) { try CoreListener() }
        }

        /// The current generation; 0 when the core fails.
        var generation: UInt64 {
            guard let core else { return 0 }
            return CoreBridge.call("CoreListener.generation", fallback: 0) { try core.generation() }
        }

        /// The published state as it is now; stopped when the core fails.
        var status: ListenerStatus {
            guard let core else { return .stopped }
            return CoreBridge.call("CoreListener.status", fallback: .stopped) {
                ListenerStatus(try core.status())
            }
        }

        /// Connections held, closing ones included; 0 when the core fails.
        var connectionCount: Int {
            guard let core else { return 0 }
            return CoreBridge.call("CoreListener.connectionCount", fallback: 0) {
                Int(clamping: try core.connectionCount())
            }
        }

        /// Authenticated protocol clients held; 0 when the core fails.
        var authenticatedCount: Int {
            guard let core else { return 0 }
            return CoreBridge.call("CoreListener.authenticatedCount", fallback: 0) {
                Int(clamping: try core.authenticatedCount())
            }
        }

        private func run(_ name: String, fallback: [ListenerEffect] = [],
                         _ body: (CoreListener) throws -> [CoreListenerEffect]) -> [ListenerEffect] {
            guard let core else { return fallback }
            return CoreBridge.call("CoreListener.\(name)", fallback: fallback) {
                try body(core).map(ListenerEffect.init)
            }
        }

        // MARK: The bind

        /// Listens on 127.0.0.1:`port` with `token`; a no-op while ready on
        /// the same port and token (HK-289).
        func start(port: UInt16, token: String) -> [ListenerEffect] {
            run("start") { try $0.start(port: port, token: token) }
        }

        func stop() -> [ListenerEffect] {
            run("stop", fallback: [.stopListening]) { try $0.stop() }
        }

        func bindReady(generation: UInt64) -> [ListenerEffect] {
            run("bindReady") { try $0.bindReady(generation: generation) }
        }

        func bindWaiting(generation: UInt64, error: BindError) -> [ListenerEffect] {
            run("bindWaiting") { try $0.bindWaiting(generation: generation, error: error.core) }
        }

        func bindFailed(generation: UInt64, error: BindError) -> [ListenerEffect] {
            run("bindFailed") { try $0.bindFailed(generation: generation, error: error.core) }
        }

        func bindCancelled(generation: UInt64) -> [ListenerEffect] {
            run("bindCancelled") { try $0.bindCancelled(generation: generation) }
        }

        /// The listener a `listen` asked for could not be created.
        func listenRefused(generation: UInt64, detail: String) -> [ListenerEffect] {
            run("listenRefused") { try $0.listenRefused(generation: generation, detail: detail) }
        }

        func retryFired(generation: UInt64) -> [ListenerEffect] {
            run("retryFired") { try $0.retryFired(generation: generation) }
        }

        // MARK: Connections

        /// The listener of `generation` accepted a socket: an `admit` names
        /// it, a `refuse` (also the answer when the core fails) drops it.
        func accepted(generation: UInt64) -> [ListenerEffect] {
            run("accepted", fallback: [.refuse]) { try $0.accepted(generation: generation) }
        }

        /// One read's bytes from a connection.
        func received(connection: UInt64, bytes: Data) -> [ListenerEffect] {
            run("received", fallback: [.cancel(connection: connection)]) {
                try $0.received(connection: connection, bytes: bytes)
            }
        }

        /// The peer ended its stream.
        func endOfStream(connection: UInt64) -> [ListenerEffect] {
            run("endOfStream", fallback: [.cancel(connection: connection)]) {
                try $0.endOfStream(connection: connection)
            }
        }

        /// The connection is gone: a `close` was carried out, a read failed
        /// or the socket failed or was cancelled.
        func closed(connection: UInt64) -> [ListenerEffect] {
            run("closed", fallback: [.cancel(connection: connection)]) { try $0.closed(connection: connection) }
        }

        func deadlineFired(connection: UInt64) -> [ListenerEffect] {
            run("deadlineFired", fallback: [.cancel(connection: connection)]) {
                try $0.deadlineFired(connection: connection)
            }
        }

        // MARK: The app

        /// One message to every authenticated client, encoded once (HK-262).
        func broadcast(_ message: ServerMessage) -> [ListenerEffect] {
            run("broadcast") { try $0.broadcast(message: message.core) }
        }

        /// The answer to a `welcome` effect: the welcome, then each snapshot
        /// message in order (HK-234).
        func welcome(connection: UInt64, appVersion: String, snapshot: [ServerMessage]) -> [ListenerEffect] {
            run("welcome") {
                try $0.welcome(connection: connection, appVersion: appVersion, snapshot: snapshot.map(\.core))
            }
        }
    }

    /// The listener's spec constants (docs/protocol.md).
    struct ListenerLimits: Equatable {
        let maxConnections: Int
        let maxAuthenticated: Int
        let idleDeadline: TimeInterval
        let maxHeaderBytes: Int
        let maxBodyBytes: Int
        let maxPayloadBytes: Int
        let maxWebSocketBufferBytes: Int
        /// The most bytes RemoteListener reads from a connection at a time.
        let receiveChunkBytes: Int
        let maxBindRetries: Int
        let bindRetryStep: TimeInterval
        let minPort: UInt16

        /// Only the fallback for a failed core call, pinned equal to the
        /// core's by a test.
        static let fallback = ListenerLimits(
            maxConnections: 32, maxAuthenticated: 16, idleDeadline: 15, maxHeaderBytes: 16 * 1024,
            maxBodyBytes: 4 * 1024 * 1024, maxPayloadBytes: 1024 * 1024, maxWebSocketBufferBytes: 2 * 1024 * 1024,
            receiveChunkBytes: 32 * 1024, maxBindRetries: 3, bindRetryStep: 2, minPort: 1024)
    }

    /// The listener's constants; the fallback when the core fails.
    static var listenerLimits: ListenerLimits {
        call("listenerLimits", fallback: .fallback) {
            ListenerLimits(try PowerUpCore.listenerLimits())
        }
    }
}

// MARK: - Conversions
//
// Exhaustive switches with no `default:`, as in CoreBridge.swift.

extension CoreBridge.ListenerStatus {
    fileprivate init(_ core: CoreListenerStatus) {
        self.init(isRunning: core.running, lastError: core.problem)
    }
}

extension CoreBridge.BindError {
    fileprivate var core: CoreBindError {
        switch self {
        case .addressInUse: return .addressInUse
        case .other(let description): return .other(description: description)
        }
    }
}

extension RemoteHookEvent.Kind {
    fileprivate init(_ core: CoreHookKind) {
        switch core {
        case .userPromptSubmit: self = .userPromptSubmit
        case .postToolUse: self = .postToolUse
        case .notification: self = .notification
        case .stop: self = .stop
        case .sessionEnd: self = .sessionEnd
        }
    }
}

extension CoreBridge.ListenerEffect {
    fileprivate init(_ core: CoreListenerEffect) {
        switch core {
        case .publish(let status): self = .publish(CoreBridge.ListenerStatus(status))
        case .listen(let generation, let port): self = .listen(generation: generation, port: port)
        case .stopListening: self = .stopListening
        case .scheduleBindRetry(let generation, let seconds):
            self = .scheduleBindRetry(generation: generation, seconds: seconds)
        case .admit(let connection): self = .admit(connection: connection)
        case .refuse: self = .refuse
        case .armIdleDeadline(let connection, let seconds):
            self = .armIdleDeadline(connection: connection, seconds: seconds)
        case .send(let connection, let bytes): self = .send(connection: connection, bytes: bytes)
        case .broadcast(let connections, let bytes): self = .broadcast(connections: connections, bytes: bytes)
        case .close(let connection): self = .close(connection: connection)
        case .cancel(let connection): self = .cancel(connection: connection)
        case .deliverHook(let generation, let hook):
            self = .deliverHook(generation: generation,
                                RemoteHookEvent(kind: RemoteHookEvent.Kind(hook.kind), text: hook.text,
                                                sessionID: hook.sessionId, cwd: hook.cwd))
        case .deliverIntent(let generation, let intent): self = .deliverIntent(generation: generation, Intent(intent))
        case .welcome(let connection): self = .welcome(connection: connection)
        }
    }
}

extension CoreBridge.ListenerLimits {
    fileprivate init(_ core: CoreListenerLimits) {
        self.init(maxConnections: Int(core.maxConnections), maxAuthenticated: Int(core.maxAuthenticated),
                  idleDeadline: core.idleDeadlineSeconds, maxHeaderBytes: Int(core.maxHeaderBytes),
                  maxBodyBytes: Int(core.maxBodyBytes), maxPayloadBytes: Int(core.maxPayloadBytes),
                  maxWebSocketBufferBytes: Int(core.maxWebsocketBufferBytes),
                  receiveChunkBytes: Int(core.receiveChunkBytes), maxBindRetries: Int(core.maxBindRetries),
                  bindRetryStep: core.bindRetryStepSeconds, minPort: core.minPort)
    }
}
